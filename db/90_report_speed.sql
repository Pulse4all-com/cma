-- =============================================================================================
-- 90_report_speed.sql: addition 0008x, the report functions answer a month in under a second
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 88_callbacks_kept.sql (0008w). Rerunnable, forward-only, in one transaction. Run as your own IAM login,
-- dev first, then prod; then 91_verify_report_speed.sql (dev), then 83_verify_email_reports.sql and
-- 85_verify_first_orders.sql (dev) again (unchanged).
--
-- Report speed brief (19 October 2026; README Decision log): measured in prod as cma_app in October,
-- first_orders_report took 26.8 s, first_orders_amounts 20.1 s and first_orders_list 21.1 s (each above the
-- web's 15 s statement timeout, so Reports, First orders always failed), email_report 7.0 s and Email per
-- agent 18 to 20 s. docs/perf-2026-10-19/diagnose.sql measured why, in prod (prod-output.txt beside it):
--   first orders   the touches of the first orders were planned as a nested loop that ran the whole touch
--                  lateral once per first order per first order (166 x 166 = 27,556 runs, 20.7 of 20.7 s),
--                  with cma.crm_call_connected_of called per call in it (26,228 calls, 2.6 s)
--   email          under row-level security the market chain's contact key (a COALESCE holding the
--                  association subquery) kept the unique index out: a Seq Scan on crm_contact per email
--                  (4,870 x 1.9 ms) and on form_submission (2,033 x 0.4 ms); as the owner the same read
--                  took 1.1 s
--   statistics     cma.market, cma.market_alias and cma.app_user_external_id were never analyzed
-- No figure changes meaning: every definition below gives the rows the 0008t and 0008u definitions give
-- (91 checks it on a tenant at prod's volume of 19 October 2026, and times every read as cma_app). The
-- existing indexes serve the new plans: no index is added.
--
-- What it changes
--   first orders   cma.first_orders_of reads the touches once per first order and joins them to the first
--                  orders by id; the CRM calls a first order can count are read once each, with their
--                  effective time and whether they are a conversation as cma.crm_call_connected_of defines
--                  it; a deal's market as cma.record_market_of gives it, cma.market_code_of once per distinct
--                  value. No join between two of its steps is left to the planner's row estimates
--   one pass       cma.first_order, the row type of cma.first_orders_of, and cma.first_orders_rows_of(): the
--                  order deals of a span of business dates in one pass. The figures, the amounts and the list
--                  are computed from those rows (cma.first_orders_figures_from(), first_orders_amounts_from(),
--                  first_orders_list_from(), first_orders_report_from()); cma.first_orders_report_of reads the
--                  period and its previous span in one pass instead of two. cma.first_orders_page()
--                  (reports.view or performance.team): the First orders page in one read and one pass, the
--                  report, the amounts and the list as the three reads give them, each row tagged with its part
--   email          cma.email_of and cma.email_threads_counted_of resolve the contact first, as a plain column,
--                  then the market chain of cma.email_market_of: the contact's and the inbox's steps by joins,
--                  cma.market_code_of once per distinct value, the form and record steps only where the steps
--                  before them found nothing (as before), the zone and the connections' origin lists once.
--                  cma.email_openings_of computes the business seconds of the reply and of the close as
--                  cma.business_seconds_of defines them in the query, not by two calls per opening
--   email pass     cma.email_fact and cma.email_facts_of(): the emails, openings and closes of a span in one
--                  pass. The figures, the report, per dimension and per person are computed from them
--                  (cma.email_figures_from(), email_report_from(), email_by_dimension_from(),
--                  email_per_person_from()); cma.email_report_of and email_overview_of read the period and its
--                  previous span in one pass instead of two. cma.email_report_page() (reports.view or
--                  performance.team): the Email page in one read and one pass, the report and, with a filter
--                  set, the figures without the filters for the filter lists (period 'unfiltered');
--                  cma.email_per_person_page() (as cma.email_per_person): Email per agent in one read and one
--                  pass, per person and the figures without the filters, each row tagged with its part
--   statistics     analyze cma.market, cma.market_alias and cma.app_user_external_id
--
-- The earlier reads keep their names, arguments, columns and checks; the web reads the three page reads.
-- Everything stays SECURITY INVOKER and executable by the application only (as 0008t and 0008u).
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

begin;
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008w') then
    raise exception 'addition 0008w (88_callbacks_kept.sql) must run before 0008x';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. First orders: the definition, once per first order
-- ---------------------------------------------------------------------------------------------
-- As 0008u (every rule in 84's header, README Data model: first orders), computed differently: the
-- first orders' touches are read once per first order (x) and joined back to the first orders by id (f, l),
-- the CRM calls once each with whether they are a conversation (cl, as cma.crm_call_connected_of), the
-- market set-based (d, mv, as cma.record_market_of)
create or replace function cma.first_orders_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  deal_id                uuid,
  connection_id          uuid,
  source_system          text,
  deal_source_id         text,
  pipeline_id            text,
  pipeline_label         text,
  contact_source_id      text,
  created_at             timestamptz,
  market                 text,
  zone                   text,
  business_date          date,
  week_start             date,
  local_time             time,
  kind                   text,
  order_id               uuid,
  order_source_id        text,
  store_order_kind       text,
  currency               text,
  amount                 numeric,
  phone_hashed           boolean,
  lead_deal              boolean,
  conversation           boolean,
  email                  boolean,
  phone_match            boolean,
  attempt                boolean,
  known_contact          boolean,
  level                  text,
  attribution            text,
  first_touch_at         timestamptz,
  days_from_first_touch  numeric,
  credited_system        text,
  credited_owner_ref     text,
  credited_user_id       uuid
)
language sql stable
set jit = off
as $$
  with s as (
    select t.timezone as tenant_zone,
           make_interval(days => cma.setting_of(t.id, 'attribution.window_days')::integer) as win,
           string_to_array(cma.setting_of(t.id, 'attribution.level_order'), ',') as level_order,
           coalesce(string_to_array(nullif(cma.setting_of(t.id, 'attribution.assisted_levels'), ''), ','), '{}'::text[]) as assisted,
           make_interval(mins => cma.setting_of(t.id, 'attribution.known_contact_minutes')::integer) as known,
           make_interval(mins => cma.setting_of(t.id, 'attribution.order_match_minutes')::integer) as match,
           greatest(0, cma.setting_of(t.id, 'telephony.connected_min_seconds')::integer) as connected_min
    from cma.tenant t where t.id = p_tenant_id
  ),
  -- the won deals of the order pipelines created in the period, with their contact and its country
  d0 as materialized (
    select r.id, r.connection_id, r.source_system, r.source_id, r.pipeline_id, coalesce(p.label, r.pipeline_id) as pipeline_label,
           r.source_created_at as t, r.market as own_market, r.amount as deal_amount, r.currency as deal_currency,
           coalesce(r.contact_source_id,
                    (select a.to_id from cma.crm_association a
                     where a.tenant_id = r.tenant_id and a.connection_id = r.connection_id and a.from_type = 'deal'
                       and a.from_id = r.source_id and a.to_type = 'contact' and a.removed_at is null
                     order by a.first_seen_at, a.to_id limit 1)) as contact
    from cma.crm_record r
    join cma.connection_pipeline p
      on p.tenant_id = r.tenant_id and p.connection_id = r.connection_id and p.record_type = r.record_type
     and p.source_pipeline_id = r.pipeline_id and p.is_order and p.is_counted
    join cma.connection_stage st
      on st.tenant_id = r.tenant_id and st.connection_id = r.connection_id and st.record_type = r.record_type
     and st.source_pipeline_id = r.pipeline_id and st.source_stage_id = r.stage_id and st.outcome = 'won'
    where r.tenant_id = p_tenant_id and r.record_type = 'deal' and r.source_deleted_at is null
      and r.source_created_at >= p_from and r.source_created_at < p_to
  ),
  d as materialized (
    select d0.*, cc.country
    from d0
    left join cma.crm_contact cc on cc.tenant_id = p_tenant_id and cc.connection_id = d0.connection_id and cc.source_id = d0.contact
  ),
  -- the catalog market of every value a deal's market reads (its own, its contact's country), once per value,
  -- as one map
  mv as materialized (
    select coalesce(jsonb_object_agg(v.value, cma.market_code_of(p_tenant_id, v.value)), '{}'::jsonb) as code_of
    from (select d.own_market as value from d union select d.country from d) v
    where v.value is not null
  ),
  -- the market, the linked order and the kind
  k as materialized (
    select d.*, coalesce(mv.code_of ->> d.own_market, mv.code_of ->> d.country, 'unknown') as market, coalesce(mk.time_zone, s.tenant_zone) as zone,
           o.order_id, o.order_source_id, o.order_kind as store_order_kind, o.currency as order_currency, o.amount as order_amount,
           o.hashes,
           case when d.contact is null then 'no_contact'
                when o.order_kind = 'renewal' then 'renewal'
                when exists (select 1
                             from cma.crm_record r2
                             join cma.connection_pipeline p2
                               on p2.tenant_id = r2.tenant_id and p2.connection_id = r2.connection_id and p2.record_type = r2.record_type
                              and p2.source_pipeline_id = r2.pipeline_id and p2.is_order and p2.is_counted
                             join cma.connection_stage st2
                               on st2.tenant_id = r2.tenant_id and st2.connection_id = r2.connection_id and st2.record_type = r2.record_type
                              and st2.source_pipeline_id = r2.pipeline_id and st2.source_stage_id = r2.stage_id and st2.outcome = 'won'
                             where r2.tenant_id = p_tenant_id and r2.connection_id = d.connection_id and r2.record_type = 'deal'
                               and r2.contact_source_id = d.contact and r2.source_deleted_at is null
                               and (r2.source_created_at < d.t or (r2.source_created_at = d.t and r2.id < d.id)))
                  or exists (select 1
                             from cma.crm_association a2
                             join cma.crm_record r2
                               on r2.tenant_id = a2.tenant_id and r2.connection_id = a2.connection_id and r2.record_type = 'deal'
                              and r2.source_id = a2.from_id and r2.source_deleted_at is null
                             join cma.connection_pipeline p2
                               on p2.tenant_id = r2.tenant_id and p2.connection_id = r2.connection_id and p2.record_type = r2.record_type
                              and p2.source_pipeline_id = r2.pipeline_id and p2.is_order and p2.is_counted
                             join cma.connection_stage st2
                               on st2.tenant_id = r2.tenant_id and st2.connection_id = r2.connection_id and st2.record_type = r2.record_type
                              and st2.source_pipeline_id = r2.pipeline_id and st2.source_stage_id = r2.stage_id and st2.outcome = 'won'
                             where a2.tenant_id = p_tenant_id and a2.connection_id = d.connection_id and a2.from_type = 'deal'
                               and a2.to_type = 'contact' and a2.to_id = d.contact and a2.removed_at is null
                               and (r2.source_created_at < d.t or (r2.source_created_at = d.t and r2.id < d.id)))
                  then 'repeat'
                when o.order_kind = 'repeat' then 'not_first'
                else 'first' end as kind
    from d
    cross join s
    cross join mv
    left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = coalesce(mv.code_of ->> d.own_market, mv.code_of ->> d.country, 'unknown')
    left join lateral (
      select co.id as order_id, co.source_id as order_source_id, co.order_kind, co.currency, co.total_amount as amount,
             array_remove(array[co.phone_hash, cu.phone_hash], null) as hashes
      from cma.commerce_customer cu
      join cma.commerce_order co
        on co.tenant_id = cu.tenant_id and co.connection_id = cu.connection_id and co.customer_source_id = cu.source_id
      where cu.tenant_id = p_tenant_id and cu.crm_connection_id = d.connection_id and cu.crm_contact_source_id = d.contact
        and not co.is_test and co.cancelled_at is null and co.source_deleted_at is null
        and co.source_created_at >= d.t - s.match and co.source_created_at <= d.t + s.match
      order by abs(extract(epoch from co.source_created_at - d.t)), co.source_created_at, co.id
      limit 1) o on true
  ),
  -- the first orders: only they are attributed
  fo as materialized (
    select k.*, array(select distinct h from unnest(k.hashes) h) as phones
    from k
    where k.kind = 'first'
  ),
  -- the CRM calls a first order can count, once each: those associated with its contact and those from its
  -- order's phone number (any contact); with the effective time and whether the call is a conversation, as
  -- cma.crm_call_connected_of gives them (0008j: the linked telephony call while the link is current, else
  -- the call's outcome)
  cl as materialized (
    select c.id, c.connection_id, c.source_id, c.source_system, c.owner_ref, c.counterpart_hash,
           coalesce(tc.started_at, c.occurred_at) as effective_at,
           case when tc.id is not null
                then (tc.direction = 'inbound' and tc.answered_at is not null)
                     or (tc.direction = 'outbound' and coalesce(tc.talk_seconds >= s.connected_min, false))
                else coalesce(o.is_connected, false) end as is_connected
    from (select a.connection_id, a.from_id as source_id
          from fo
          join cma.crm_association a
            on a.tenant_id = p_tenant_id and a.connection_id = fo.connection_id and a.from_type = 'crm_call' and a.to_type = 'contact'
           and a.to_id = fo.contact and a.removed_at is null
          union
          select c2.connection_id, c2.source_id
          from (select distinct h from fo cross join unnest(fo.phones) h) ph
          join cma.crm_call c2 on c2.tenant_id = p_tenant_id and c2.counterpart_hash = ph.h) ids
    join cma.crm_call c
      on c.tenant_id = p_tenant_id and c.connection_id = ids.connection_id and c.source_id = ids.source_id and c.source_deleted_at is null
    cross join s
    left join cma.call_link l on l.tenant_id = c.tenant_id and l.crm_call_id = c.id and l.unlinked_at is null
    left join cma.telephony_call tc on tc.tenant_id = l.tenant_id and tc.id = l.telephony_call_id and tc.source_deleted_at is null
    left join cma.connection_call_outcome o
      on o.tenant_id = c.tenant_id and o.connection_id = c.connection_id and o.outcome_ref = c.outcome_ref
  ),
  -- the touches of each first order in its window, once per first order
  x as materialized (
    -- lead deals of the contact: primary contact
    select fo.id, 'lead_deal'::text as touch, r3.source_created_at as at, r3.source_system || '_owner' as sys, r3.owner_ref
    from fo
    cross join s
    join cma.crm_record r3
      on r3.tenant_id = p_tenant_id and r3.connection_id = fo.connection_id and r3.record_type = 'deal' and r3.contact_source_id = fo.contact
    left join cma.connection_pipeline p3
      on p3.tenant_id = r3.tenant_id and p3.connection_id = r3.connection_id and p3.record_type = r3.record_type
     and p3.source_pipeline_id = r3.pipeline_id
    where r3.source_deleted_at is null and r3.id <> fo.id
      and coalesce(p3.is_counted, true) and coalesce(p3.is_lead, true) and not coalesce(p3.is_order, false)
      and r3.source_created_at >= fo.t - s.win and r3.source_created_at < fo.t
    union all
    -- lead deals of the contact: a current association
    select fo.id, 'lead_deal', r3.source_created_at, r3.source_system || '_owner', r3.owner_ref
    from fo
    cross join s
    join cma.crm_association a3
      on a3.tenant_id = p_tenant_id and a3.connection_id = fo.connection_id and a3.from_type = 'deal' and a3.to_type = 'contact'
     and a3.to_id = fo.contact and a3.removed_at is null
    join cma.crm_record r3
      on r3.tenant_id = a3.tenant_id and r3.connection_id = a3.connection_id and r3.record_type = 'deal' and r3.source_id = a3.from_id
    left join cma.connection_pipeline p3
      on p3.tenant_id = r3.tenant_id and p3.connection_id = r3.connection_id and p3.record_type = r3.record_type
     and p3.source_pipeline_id = r3.pipeline_id
    where r3.contact_source_id is distinct from fo.contact and r3.source_deleted_at is null and r3.id <> fo.id
      and coalesce(p3.is_counted, true) and coalesce(p3.is_lead, true) and not coalesce(p3.is_order, false)
      and r3.source_created_at >= fo.t - s.win and r3.source_created_at < fo.t
    union all
    -- calls with the contact: a conversation, else an attempt
    select fo.id, case when c.is_connected then 'conversation' else 'attempt' end, c.effective_at, c.source_system || '_owner', c.owner_ref
    from fo
    cross join s
    join cma.crm_association a4
      on a4.tenant_id = p_tenant_id and a4.connection_id = fo.connection_id and a4.from_type = 'crm_call' and a4.to_type = 'contact'
     and a4.to_id = fo.contact and a4.removed_at is null
    join cl c on c.connection_id = a4.connection_id and c.source_id = a4.from_id
    where c.effective_at >= fo.t - s.win and c.effective_at < fo.t
    union all
    -- agent emails to the contact: the message's own contact, its conversation's, or an engagement's association
    select fo.id, 'email', em.occurred_at, em.source_system || '_owner', em.owner_ref
    from fo
    cross join s
    cross join lateral (
      select em1.id from cma.email_message em1
      where em1.tenant_id = p_tenant_id and em1.connection_id = fo.connection_id and em1.contact_source_id = fo.contact
      union
      select em2.id from cma.email_thread th2
      join cma.email_message em2
        on em2.tenant_id = th2.tenant_id and em2.connection_id = th2.connection_id and em2.thread_source_id = th2.source_id
      where th2.tenant_id = p_tenant_id and th2.connection_id = fo.connection_id and th2.contact_source_id = fo.contact
      union
      select em3.id from cma.crm_association a5
      join cma.email_message em3
        on em3.tenant_id = a5.tenant_id and em3.connection_id = a5.connection_id and em3.source_kind = 'crm_email'
       and em3.source_id = a5.from_id
      where a5.tenant_id = p_tenant_id and a5.connection_id = fo.connection_id and a5.from_type = 'crm_email'
        and a5.to_type = 'contact' and a5.to_id = fo.contact and a5.removed_at is null) ids
    join cma.email_message em on em.tenant_id = p_tenant_id and em.id = ids.id
    join cma.integration_connection ic on ic.tenant_id = em.tenant_id and ic.id = em.connection_id
    left join cma.email_thread th
      on th.tenant_id = em.tenant_id and th.connection_id = em.connection_id and th.source_id = em.thread_source_id
    where em.direction = 'out' and em.status = 'sent' and em.source_deleted_at is null
      and em.occurred_at >= fo.t - s.win and em.occurred_at < fo.t
      and case when em.source_kind = 'inbox_message'
               then em.actor_kind not in ('bot', 'ai', 'system', 'integration') and not coalesce(th.is_spam, false)
               else not (lower(coalesce(em.origin, '')) = any (cma.setting_codes(ic.settings, 'email_inbox_copy_origins')))
                    and not (lower(coalesce(em.origin, '')) = any (cma.setting_codes(ic.settings, 'email_automated_origins'))) end
    union all
    -- a CRM call from the order's phone number, any contact
    select fo.id, 'phone_match', c.effective_at, c.source_system || '_owner', c.owner_ref
    from fo
    cross join s
    cross join unnest(fo.phones) ph(h)
    join cl c on c.counterpart_hash = ph.h
    where c.effective_at >= fo.t - s.win and c.effective_at < fo.t
    union all
    -- a telephony call from the order's phone number, any contact
    select fo.id, 'phone_match', tc.started_at, tc.source_system || '_user', tc.user_ref
    from fo
    cross join s
    cross join unnest(fo.phones) ph(h)
    join cma.telephony_call tc on tc.tenant_id = p_tenant_id and tc.counterpart_hash = ph.h
    where tc.source_deleted_at is null and tc.started_at >= fo.t - s.win and tc.started_at < fo.t
  ),
  f as materialized (
    select fo.id,
           coalesce(bool_or(x.touch = 'lead_deal'), false) as f_lead,
           coalesce(bool_or(x.touch = 'conversation'), false) as f_conv,
           coalesce(bool_or(x.touch = 'email'), false) as f_email,
           coalesce(bool_or(x.touch = 'phone_match'), false) as f_phone,
           coalesce(bool_or(x.touch = 'attempt'), false) as f_attempt,
           coalesce((select kc.source_created_at <= fo.t - s.known
                     from cma.crm_contact kc
                     where kc.tenant_id = p_tenant_id and kc.connection_id = fo.connection_id and kc.source_id = fo.contact), false) as f_known,
           min(x.at) as first_at,
           (array_agg(x.sys order by x.at desc, x.touch, x.owner_ref) filter (where x.touch = any (s.assisted)))[1] as c_sys,
           (array_agg(x.owner_ref order by x.at desc, x.touch, x.owner_ref) filter (where x.touch = any (s.assisted)))[1] as c_owner
    from fo
    cross join s
    left join x on x.id = fo.id
    group by fo.id, fo.t, fo.connection_id, fo.contact, s.known
  ),
  l as materialized (
    select f.*,
           coalesce((select u.lv
                     from unnest(s.level_order) with ordinality as u(lv, i)
                     where case u.lv when 'lead_deal' then f.f_lead when 'conversation' then f.f_conv when 'email' then f.f_email
                                     when 'phone_match' then f.f_phone when 'attempt' then f.f_attempt when 'known_contact' then f.f_known
                                     else false end
                     order by u.i limit 1), 'self_service') as lv,
           s.assisted
    from f cross join s
  )
  -- the order deals that are no first order carry their kind and order, nothing else; each first order its
  -- own evidence, level, attribution and credited person (a join of the first orders only, by id)
  select k.id, k.connection_id, k.source_system, k.source_id, k.pipeline_id, k.pipeline_label, k.contact, k.t, k.market, k.zone,
         (k.t at time zone k.zone)::date,
         date_trunc('week', (k.t at time zone k.zone)::date::timestamp)::date,
         (k.t at time zone k.zone)::time,
         k.kind, k.order_id, k.order_source_id, k.store_order_kind,
         case when k.order_id is not null then k.order_currency else k.deal_currency end,
         case when k.order_id is not null then k.order_amount else k.deal_amount end,
         cardinality(k.hashes) > 0,
         null::boolean, null::boolean, null::boolean, null::boolean, null::boolean, null::boolean, null::text, null::text,
         null::timestamptz, null::numeric, null::text, null::text, null::uuid
  from k
  where k.kind <> 'first'
  union all
  select fo.id, fo.connection_id, fo.source_system, fo.source_id, fo.pipeline_id, fo.pipeline_label, fo.contact, fo.t, fo.market, fo.zone,
         (fo.t at time zone fo.zone)::date,
         date_trunc('week', (fo.t at time zone fo.zone)::date::timestamp)::date,
         (fo.t at time zone fo.zone)::time,
         fo.kind, fo.order_id, fo.order_source_id, fo.store_order_kind,
         case when fo.order_id is not null then fo.order_currency else fo.deal_currency end,
         case when fo.order_id is not null then fo.order_amount else fo.deal_amount end,
         cardinality(fo.hashes) > 0,
         l.f_lead, l.f_conv, l.f_email, l.f_phone, l.f_attempt, l.f_known,
         l.lv,
         case when l.lv = any (l.assisted) then 'call_center' else 'self_service' end,
         l.first_at,
         case when l.first_at is not null then round((extract(epoch from fo.t - l.first_at) / 86400)::numeric, 2) end,
         l.c_sys, l.c_owner,
         (select xi.user_id from cma.app_user_external_id xi
          where xi.tenant_id = p_tenant_id and xi.system = l.c_sys and xi.external_id = l.c_owner)
  from fo
  join l on l.id = fo.id
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. First orders: one pass for the page
-- ---------------------------------------------------------------------------------------------
-- The row type of cma.first_orders_of, so a span read once can be handed to every read below
do $$
begin
  if to_regtype('cma.first_order') is null then
    create type cma.first_order as (
      deal_id                uuid,
      connection_id          uuid,
      source_system          text,
      deal_source_id         text,
      pipeline_id            text,
      pipeline_label         text,
      contact_source_id      text,
      created_at             timestamptz,
      market                 text,
      zone                   text,
      business_date          date,
      week_start             date,
      local_time             time,
      kind                   text,
      order_id               uuid,
      order_source_id        text,
      store_order_kind       text,
      currency               text,
      amount                 numeric,
      phone_hashed           boolean,
      lead_deal              boolean,
      conversation           boolean,
      email                  boolean,
      phone_match            boolean,
      attempt                boolean,
      known_contact          boolean,
      level                  text,
      attribution            text,
      first_touch_at         timestamptz,
      days_from_first_touch  numeric,
      credited_system        text,
      credited_owner_ref     text,
      credited_user_id       uuid
    );
  end if;
end
$$;
comment on type cma.first_order is
  'One order deal as cma.first_orders_of gives it (0008x): the reads hand a span read once to the figures, the amounts and the list';

-- The order deals of the business dates [p_from, p_to] in one pass of cma.first_orders_of: created from the
-- day before p_from to two days after p_to in the tenant's zone, as every read since 0008u (each deal's
-- business date is in its own market's zone); the reads below keep the dates they count
create or replace function cma.first_orders_rows_of(p_tenant_id uuid, p_from date, p_to date)
returns cma.first_order[]
language sql stable
as $$
  select coalesce(array_agg(row(x.*)::cma.first_order), '{}')
  from cma.tenant t
  cross join lateral cma.first_orders_of(t.id, (p_from - 1)::timestamp at time zone t.timezone, (p_to + 2)::timestamp at time zone t.timezone) x
  where t.id = p_tenant_id
$$;

-- The figures of business dates [p_from, p_to] (each deal's own market zone), cut on p_to at p_until's
-- time of day in each zone (the previous span, like for like), narrowed by market and level, per
-- dimension asked for (day, week, market, level) and the total, from order deals already read. A level
-- filter keeps first orders of that level only, so the kinds counted apart are 0 with it (0008u's
-- definition, unchanged)
create or replace function cma.first_orders_figures_from(p_rows cma.first_order[], p_from date, p_to date, p_market text, p_level text,
                                                         p_dimensions text[], p_until timestamptz default null)
returns table (
  dimension          text,
  group_key          text,
  first_orders       integer,
  call_center        integer,
  self_service       integer,
  repeats            integer,
  renewals           integer,
  not_first          integer,
  no_contact         integer,
  with_touch         integer,
  days_median        numeric
)
language sql stable
as $$
  with o as materialized (
    select x.* from unnest(p_rows) x
    where x.business_date between p_from and p_to
      and (p_until is null or x.business_date < p_to or x.local_time <= (p_until at time zone x.zone)::time)
      and (p_market is null or x.market = p_market)
      and (p_level is null or x.level = p_level)
  ),
  g as (
    select dd.dim, dd.k, o.*
    from o
    cross join lateral (
      values ('total', null::text),
             ('day', o.business_date::text),
             ('week', o.week_start::text),
             ('market', o.market),
             ('level', o.level)) as dd(dim, k)
    where dd.dim = 'total' or (dd.dim = any (p_dimensions) and (dd.dim <> 'level' or o.kind = 'first'))
  ),
  agg as (
    select g.dim, g.k,
           (count(*) filter (where g.kind = 'first'))::integer as first_orders,
           (count(*) filter (where g.attribution = 'call_center'))::integer as call_center,
           (count(*) filter (where g.attribution = 'self_service'))::integer as self_service,
           (count(*) filter (where g.kind = 'repeat'))::integer as repeats,
           (count(*) filter (where g.kind = 'renewal'))::integer as renewals,
           (count(*) filter (where g.kind = 'not_first'))::integer as not_first,
           (count(*) filter (where g.kind = 'no_contact'))::integer as no_contact,
           (count(*) filter (where g.kind = 'first' and g.first_touch_at is not null))::integer as with_touch,
           percentile_cont(0.5) within group (order by g.days_from_first_touch)
             filter (where g.kind = 'first' and g.days_from_first_touch is not null) as dm
    from g
    group by g.dim, g.k
  )
  select a.dim, a.k, a.first_orders, a.call_center, a.self_service, a.repeats, a.renewals, a.not_first, a.no_contact, a.with_touch,
         round(a.dm::numeric, 1)
  from agg a
  union all
  -- the total is there even for a period without anything
  select 'total', null, 0, 0, 0, 0, 0, 0, 0, 0, null
  where not exists (select 1 from agg where agg.dim = 'total')
  order by 1, 2
$$;

-- As 0008u, over one read of the dates
create or replace function cma.first_orders_figures_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_level text,
                                                       p_dimensions text[], p_until timestamptz default null)
returns table (
  dimension          text,
  group_key          text,
  first_orders       integer,
  call_center        integer,
  self_service       integer,
  repeats            integer,
  renewals           integer,
  not_first          integer,
  no_contact         integer,
  with_touch         integer,
  days_median        numeric
)
language sql stable
as $$
  with r as materialized (select cma.first_orders_rows_of(p_tenant_id, p_from, p_to) as rows)
  select f.* from r cross join lateral cma.first_orders_figures_from(r.rows, p_from, p_to, p_market, p_level, p_dimensions, p_until) f
$$;

-- The report from order deals already read (they hold the period and its previous span): the period per
-- p_group, per market and per level, and the total ('current'); then the previous period's total
-- ('previous'), like for like (cma.forms_previous_of)
create or replace function cma.first_orders_report_from(p_tenant_id uuid, p_rows cma.first_order[], p_from date, p_to date, p_group text,
                                                        p_market text, p_level text, p_now timestamptz)
returns table (
  period             text,
  dimension          text,
  group_key          text,
  first_orders       integer,
  call_center        integer,
  self_service       integer,
  repeats            integer,
  renewals           integer,
  not_first          integer,
  no_contact         integer,
  with_touch         integer,
  days_median        numeric
)
language sql stable
as $$
  select x.period, x.dimension, x.group_key, x.first_orders, x.call_center, x.self_service, x.repeats, x.renewals, x.not_first,
         x.no_contact, x.with_touch, x.days_median
  from (
    select 'current'::text as period, 1 as part, f.*
    from cma.first_orders_figures_from(p_rows, p_from, p_to, p_market, p_level, array[p_group, 'market', 'level']) f
    union all
    select 'previous', 2, f.*
    from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now) v
    cross join lateral cma.first_orders_figures_from(p_rows, v.prev_from, v.prev_to, p_market, p_level, '{}'::text[], v.until) f
  ) x
  order by x.part, x.dimension, x.group_key
$$;

-- As 0008u: the report page's figures, now in one pass over the previous span's first date to the period's last
create or replace function cma.first_orders_report_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_market text, p_level text,
                                                      p_now timestamptz default now())
returns table (
  period             text,
  dimension          text,
  group_key          text,
  first_orders       integer,
  call_center        integer,
  self_service       integer,
  repeats            integer,
  renewals           integer,
  not_first          integer,
  no_contact         integer,
  with_touch         integer,
  days_median        numeric
)
language sql stable
as $$
  with r as materialized (
    select cma.first_orders_rows_of(p_tenant_id, v.prev_from, p_to) as rows from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now) v
  )
  select x.* from r cross join lateral cma.first_orders_report_from(p_tenant_id, r.rows, p_from, p_to, p_group, p_market, p_level, p_now) x
$$;

-- The first orders' amounts per currency (never summed across currencies), in total and per market, with
-- the call-center and self-service parts, from order deals already read (0008u's definition, unchanged);
-- first orders without a currency come as currency 'none' without an amount
create or replace function cma.first_orders_amounts_from(p_rows cma.first_order[], p_from date, p_to date, p_market text, p_level text)
returns table (
  dimension              text,
  group_key              text,
  currency               text,
  orders                 integer,
  amount                 numeric,
  call_center_amount     numeric,
  self_service_amount    numeric
)
language sql stable
as $$
  with o as (
    select x.* from unnest(p_rows) x
    where x.business_date between p_from and p_to and x.kind = 'first'
      and (p_market is null or x.market = p_market)
      and (p_level is null or x.level = p_level)
  )
  select dd.dim, dd.k, coalesce(o.currency, 'none'), count(*)::integer, sum(o.amount),
         coalesce(sum(o.amount) filter (where o.attribution = 'call_center'), 0),
         coalesce(sum(o.amount) filter (where o.attribution = 'self_service'), 0)
  from o
  cross join lateral (values ('total', null::text), ('market', o.market)) as dd(dim, k)
  group by dd.dim, dd.k, coalesce(o.currency, 'none')
  order by 1, 2, 3
$$;

-- As 0008u, over one read of the dates
create or replace function cma.first_orders_amounts_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_level text)
returns table (
  dimension              text,
  group_key              text,
  currency               text,
  orders                 integer,
  amount                 numeric,
  call_center_amount     numeric,
  self_service_amount    numeric
)
language sql stable
as $$
  with r as materialized (select cma.first_orders_rows_of(p_tenant_id, p_from, p_to) as rows)
  select a.* from r cross join lateral cma.first_orders_amounts_from(r.rows, p_from, p_to, p_market, p_level) a
$$;

-- The first orders of the period, newest first: the first p_limit rows after the filters, each with the
-- filtered total and the deal's record link (the current tenant's connection settings), from order deals
-- already read (0008u's list, unchanged)
create or replace function cma.first_orders_list_from(p_rows cma.first_order[], p_from date, p_to date, p_market text, p_level text,
                                                      p_limit integer)
returns table (
  connection_id          uuid,
  deal_source_id         text,
  market                 text,
  created_at             timestamptz,
  business_date          date,
  level                  text,
  attribution            text,
  lead_deal              boolean,
  conversation           boolean,
  email                  boolean,
  phone_match            boolean,
  attempt                boolean,
  known_contact          boolean,
  phone_hashed           boolean,
  has_order              boolean,
  currency               text,
  amount                 numeric,
  days_from_first_touch  numeric,
  record_url             text,
  total_rows             integer
)
language sql stable
as $$
  with o as (
    select x.* from unnest(p_rows) x
    where x.business_date between p_from and p_to and x.kind = 'first'
      and (p_market is null or x.market = p_market)
      and (p_level is null or x.level = p_level)
  )
  select o.connection_id, o.deal_source_id, o.market, o.created_at, o.business_date, o.level, o.attribution, o.lead_deal, o.conversation,
         o.email, o.phone_match, o.attempt, o.known_contact, o.phone_hashed, o.order_id is not null, o.currency, o.amount,
         o.days_from_first_touch, cma.record_url(o.connection_id, 'deal', o.deal_source_id), (count(*) over ())::integer
  from o
  order by o.created_at desc, o.deal_source_id
  limit p_limit
$$;

-- As 0008u, over one read of the dates
create or replace function cma.first_orders_list(p_from date, p_to date, p_market text, p_level text, p_rows integer default null)
returns table (
  connection_id          uuid,
  deal_source_id         text,
  market                 text,
  created_at             timestamptz,
  business_date          date,
  level                  text,
  attribution            text,
  lead_deal              boolean,
  conversation           boolean,
  email                  boolean,
  phone_match            boolean,
  attempt                boolean,
  known_contact          boolean,
  phone_hashed           boolean,
  has_order              boolean,
  currency               text,
  amount                 numeric,
  days_from_first_touch  numeric,
  record_url             text,
  total_rows             integer
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_rows   integer;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.first_orders_filters_check(p_market, p_level);
  v_rows := least(500, greatest(1, coalesce(p_rows, cma.setting_of(v_tenant, 'follow_up.list_rows')::integer)));
  return query
    with r as materialized (select cma.first_orders_rows_of(v_tenant, p_from, p_to) as rows)
    select l.* from r cross join lateral cma.first_orders_list_from(r.rows, p_from, p_to, p_market, p_level, v_rows) l;
end
$$;

-- The First orders page in one read and one pass of cma.first_orders_of (reports.view or performance.team):
-- the report (part 'report', as cma.first_orders_report), the amounts (part 'amounts', as
-- cma.first_orders_amounts) and the list (part 'list', as cma.first_orders_list, follow_up.list_rows rows or
-- p_rows), in that order, each part in its read's order; the columns a part does not use are null. The
-- checks of the three reads, once
create or replace function cma.first_orders_page(p_from date, p_to date, p_group text, p_market text, p_level text, p_rows integer default null)
returns table (
  part                   text,
  period                 text,
  dimension              text,
  group_key              text,
  first_orders           integer,
  call_center            integer,
  self_service           integer,
  repeats                integer,
  renewals               integer,
  not_first              integer,
  no_contact             integer,
  with_touch             integer,
  days_median            numeric,
  currency               text,
  orders                 integer,
  amount                 numeric,
  call_center_amount     numeric,
  self_service_amount    numeric,
  connection_id          uuid,
  deal_source_id         text,
  market                 text,
  created_at             timestamptz,
  business_date          date,
  level                  text,
  attribution            text,
  lead_deal              boolean,
  conversation           boolean,
  email                  boolean,
  phone_match            boolean,
  attempt                boolean,
  known_contact          boolean,
  phone_hashed           boolean,
  has_order              boolean,
  days_from_first_touch  numeric,
  record_url             text,
  total_rows             integer
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_now    timestamptz := now();
  v_limit  integer;
  v_all    cma.first_order[];
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'week', 'market', 'level') then
    raise exception 'group by day, week, market or level, not %', p_group using errcode = 'CMA04';
  end if;
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.first_orders_filters_check(p_market, p_level);
  v_limit := least(500, greatest(1, coalesce(p_rows, cma.setting_of(v_tenant, 'follow_up.list_rows')::integer)));
  -- the one pass: the previous span's first date to the period's last
  select cma.first_orders_rows_of(v_tenant, v.prev_from, p_to) into v_all
  from cma.forms_previous_of(v_tenant, p_from, p_to, v_now) v;
  return query
    select 'report'::text, r.period, r.dimension, r.group_key, r.first_orders, r.call_center, r.self_service, r.repeats, r.renewals,
           r.not_first, r.no_contact, r.with_touch, r.days_median,
           null::text, null::integer, null::numeric, null::numeric, null::numeric,
           null::uuid, null::text, null::text, null::timestamptz, null::date, null::text, null::text,
           null::boolean, null::boolean, null::boolean, null::boolean, null::boolean, null::boolean, null::boolean, null::boolean,
           null::numeric, null::text, null::integer
    from cma.first_orders_report_from(v_tenant, v_all, p_from, p_to, p_group, p_market, p_level, v_now) r;
  return query
    select 'amounts'::text, null::text, a.dimension, a.group_key, null::integer, null::integer, null::integer, null::integer, null::integer,
           null::integer, null::integer, null::integer, null::numeric,
           a.currency, a.orders, a.amount, a.call_center_amount, a.self_service_amount,
           null::uuid, null::text, null::text, null::timestamptz, null::date, null::text, null::text,
           null::boolean, null::boolean, null::boolean, null::boolean, null::boolean, null::boolean, null::boolean, null::boolean,
           null::numeric, null::text, null::integer
    from cma.first_orders_amounts_from(v_all, p_from, p_to, p_market, p_level) a;
  return query
    select 'list'::text, null::text, null::text, null::text, null::integer, null::integer, null::integer, null::integer, null::integer,
           null::integer, null::integer, null::integer, null::numeric,
           l.currency, null::integer, l.amount, null::numeric, null::numeric,
           l.connection_id, l.deal_source_id, l.market, l.created_at, l.business_date, l.level, l.attribution,
           l.lead_deal, l.conversation, l.email, l.phone_match, l.attempt, l.known_contact, l.phone_hashed, l.has_order,
           l.days_from_first_touch, l.record_url, l.total_rows
    from cma.first_orders_list_from(v_all, p_from, p_to, p_market, p_level, v_limit) l;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Email: the market chain on plain keys
-- ---------------------------------------------------------------------------------------------
-- As 0008t (every rule in 82's header and the comment of 0008t's cma.email_of), computed differently: the
-- contact is resolved first as a plain column (the message's, its conversation's, else an engagement's
-- earliest current association), so every lookup keyed on it can use its index under row-level
-- security; the contact's and the inbox's steps of cma.email_market_of are joins, cma.market_code_of runs
-- once per distinct value (one map), and the form and record steps run only for the emails whose earlier
-- steps found nothing, as before; the zones (one map) and the connections' origin lists are read once
create or replace function cma.email_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  connection_id     uuid,
  source_system     text,
  source_kind       text,
  thread_source_id  text,
  inbox_key         text,
  inbox_name        text,
  account_key       text,
  account_name      text,
  category          text,
  direction         text,
  status            text,
  occurred_at       timestamptz,
  actor_kind        text,
  owner_ref         text,
  market            text,
  zone              text,
  business_date     date,
  week_start        date,
  local_time        time,
  local_hour        integer,
  is_received       boolean,
  is_logged_reply   boolean,
  is_agent_send     boolean,
  is_automated      boolean,
  is_bounced_failed boolean
)
language sql stable
-- the planner adds up the cost of every step of the market chain although at most one runs per row:
-- without this, that estimate starts a JIT compilation that costs more than the read
set jit = off
as $$
  with s as materialized (
    select t.timezone as tenant_zone, string_to_array(cma.setting_of(t.id, 'email.market_order'), ',') as ord,
           (select coalesce(jsonb_object_agg(m.code, m.time_zone), '{}'::jsonb) from cma.market m where m.tenant_id = t.id) as zone_of
    from cma.tenant t where t.id = p_tenant_id
  ),
  -- the connections' origin lists, once per connection
  c as materialized (
    select ic.id, cma.setting_codes(ic.settings, 'email_automated_origins') as automated_origins,
           cma.setting_codes(ic.settings, 'email_inbox_copy_origins') as inbox_copy_origins
    from cma.integration_connection ic
    where ic.tenant_id = p_tenant_id
  ),
  e0 as materialized (
    select em.connection_id, em.source_system, em.source_kind, em.source_id, em.thread_source_id, em.inbox_source_id,
           em.account_ref, em.category, em.direction, em.status, em.occurred_at, em.actor_kind, em.owner_ref,
           ib.name as ib_name, coalesce(ac.label, ac.name) as ac_name, ac.market as ac_market,
           lower(coalesce(em.origin, '')) = any (c.automated_origins) as automated_origin,
           coalesce(em.contact_source_id, th.contact_source_id) as own_contact, th.ticket_source_id as ticket,
           coalesce(em.account_ref, th.account_ref) as m_account, coalesce(em.inbox_source_id, th.inbox_source_id) as m_inbox
    from cma.email_message em
    join c on c.id = em.connection_id
    left join cma.email_thread th
      on em.source_kind = 'inbox_message' and th.tenant_id = em.tenant_id and th.connection_id = em.connection_id
     and th.source_id = em.thread_source_id
    left join cma.connection_inbox ib
      on ib.tenant_id = em.tenant_id and ib.connection_id = em.connection_id and ib.source_inbox_id = em.inbox_source_id
    -- a message without a mailbox of its own counts under its conversation's (one stored before 0008t has none)
    left join cma.connection_inbox_account ac
      on ac.tenant_id = em.tenant_id and ac.connection_id = em.connection_id
     and ac.source_account_id = coalesce(em.account_ref, th.account_ref)
    left join cma.connection_inbox_channel ch
      on ch.tenant_id = em.tenant_id and ch.connection_id = em.connection_id and ch.source_channel_id = em.channel_source_id
    where em.tenant_id = p_tenant_id
      and em.occurred_at >= p_from and em.occurred_at < p_to
      and em.source_deleted_at is null
      and case when em.source_kind = 'inbox_message'
               then coalesce(ib.is_counted, true) and coalesce(ac.is_counted, true) and coalesce(ch.is_counted, true)
                    and not coalesce(th.is_spam, false)
               else not (lower(coalesce(em.origin, '')) = any (c.inbox_copy_origins)) end
  ),
  -- the contact as a plain column, then what the contact's and the inbox's steps read
  e as materialized (
    select e0.*, x.contact, cc.country as contact_country, b.market as inbox_market
    from e0
    cross join lateral (
      select coalesce(e0.own_contact,
                      case when e0.source_kind = 'crm_email'
                           then (select a.to_id from cma.crm_association a
                                 where a.tenant_id = p_tenant_id and a.connection_id = e0.connection_id and a.from_type = 'crm_email'
                                   and a.from_id = e0.source_id and a.to_type = 'contact' and a.removed_at is null
                                 order by a.first_seen_at, a.to_id
                                 limit 1) end) as contact
      offset 0) x
    left join cma.crm_contact cc on cc.tenant_id = p_tenant_id and cc.connection_id = e0.connection_id and cc.source_id = x.contact
    left join cma.connection_inbox b on b.tenant_id = p_tenant_id and b.connection_id = e0.connection_id and b.source_inbox_id = e0.m_inbox
  ),
  -- the catalog market of every value those steps read, once per value, as one map
  mv as materialized (
    select coalesce(jsonb_object_agg(v.value, cma.market_code_of(p_tenant_id, v.value)), '{}'::jsonb) as code_of
    from (select e.contact_country as value from e union select e.ac_market from e union select e.inbox_market from e) v
    where v.value is not null
  )
  select e.connection_id, e.source_system, e.source_kind, e.thread_source_id,
         case when e.inbox_source_id is not null then e.connection_id::text || ':' || e.inbox_source_id end,
         coalesce(e.ib_name, e.inbox_source_id),
         case when e.m_account is not null then e.connection_id::text || ':' || e.m_account end,
         coalesce(e.ac_name, e.m_account),
         e.category, e.direction, e.status, e.occurred_at, e.actor_kind, e.owner_ref,
         mk.code, z.zone,
         (e.occurred_at at time zone z.zone)::date,
         date_trunc('week', (e.occurred_at at time zone z.zone)::date::timestamp)::date,
         (e.occurred_at at time zone z.zone)::time,
         extract(hour from (e.occurred_at at time zone z.zone))::integer,
         e.source_kind = 'inbox_message' and e.direction in ('in', 'forwarded'),
         e.source_kind = 'crm_email' and e.direction in ('in', 'forwarded'),
         e.direction = 'out' and e.status = 'sent' and not k.automated,
         e.direction = 'out' and e.status = 'sent' and k.automated,
         e.direction = 'out' and e.status in ('bounced', 'failed')
  from e
  cross join s
  cross join mv
  cross join lateral (
    select case when e.source_kind = 'crm_email' then e.automated_origin
                else e.actor_kind in ('bot', 'ai', 'system', 'integration') end as automated) k
  -- the market chain of cma.email_market_of: the steps in email.market_order, each read only when the steps
  -- before it found nothing (offset 0 keeps the chain from being copied into the zone's join); 91 checks the
  -- rows equal 0008t's
  cross join lateral (
    select
      coalesce(
      case s.ord[1]
        when 'contact' then mv.code_of ->> e.contact_country
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = e.connection_id and fs.contact_source_id = e.contact
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= e.occurred_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then case when e.source_kind = 'crm_email'
                                then (select cma.market_code_of(p_tenant_id, cr.market)
                                      from cma.crm_association a
                                      join cma.crm_record cr
                                        on cr.tenant_id = a.tenant_id and cr.connection_id = a.connection_id and cr.record_type = a.to_type
                                       and cr.source_id = a.to_id
                                      where a.tenant_id = p_tenant_id and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                        and a.from_id = e.source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null
                                        and cr.source_deleted_at is null and cma.market_code_of(p_tenant_id, cr.market) is not null
                                      order by (a.to_type = 'ticket') desc, cr.source_created_at desc, cr.source_id
                                      limit 1)
                                else (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                                      where cr.tenant_id = p_tenant_id and cr.connection_id = e.connection_id and cr.record_type = 'ticket'
                                        and cr.source_id = e.ticket and cr.source_deleted_at is null) end
        when 'inbox' then coalesce(mv.code_of ->> e.ac_market, mv.code_of ->> e.inbox_market)
      end,
      case s.ord[2]
        when 'contact' then mv.code_of ->> e.contact_country
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = e.connection_id and fs.contact_source_id = e.contact
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= e.occurred_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then case when e.source_kind = 'crm_email'
                                then (select cma.market_code_of(p_tenant_id, cr.market)
                                      from cma.crm_association a
                                      join cma.crm_record cr
                                        on cr.tenant_id = a.tenant_id and cr.connection_id = a.connection_id and cr.record_type = a.to_type
                                       and cr.source_id = a.to_id
                                      where a.tenant_id = p_tenant_id and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                        and a.from_id = e.source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null
                                        and cr.source_deleted_at is null and cma.market_code_of(p_tenant_id, cr.market) is not null
                                      order by (a.to_type = 'ticket') desc, cr.source_created_at desc, cr.source_id
                                      limit 1)
                                else (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                                      where cr.tenant_id = p_tenant_id and cr.connection_id = e.connection_id and cr.record_type = 'ticket'
                                        and cr.source_id = e.ticket and cr.source_deleted_at is null) end
        when 'inbox' then coalesce(mv.code_of ->> e.ac_market, mv.code_of ->> e.inbox_market)
      end,
      case s.ord[3]
        when 'contact' then mv.code_of ->> e.contact_country
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = e.connection_id and fs.contact_source_id = e.contact
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= e.occurred_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then case when e.source_kind = 'crm_email'
                                then (select cma.market_code_of(p_tenant_id, cr.market)
                                      from cma.crm_association a
                                      join cma.crm_record cr
                                        on cr.tenant_id = a.tenant_id and cr.connection_id = a.connection_id and cr.record_type = a.to_type
                                       and cr.source_id = a.to_id
                                      where a.tenant_id = p_tenant_id and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                        and a.from_id = e.source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null
                                        and cr.source_deleted_at is null and cma.market_code_of(p_tenant_id, cr.market) is not null
                                      order by (a.to_type = 'ticket') desc, cr.source_created_at desc, cr.source_id
                                      limit 1)
                                else (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                                      where cr.tenant_id = p_tenant_id and cr.connection_id = e.connection_id and cr.record_type = 'ticket'
                                        and cr.source_id = e.ticket and cr.source_deleted_at is null) end
        when 'inbox' then coalesce(mv.code_of ->> e.ac_market, mv.code_of ->> e.inbox_market)
      end,
      case s.ord[4]
        when 'contact' then mv.code_of ->> e.contact_country
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = e.connection_id and fs.contact_source_id = e.contact
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= e.occurred_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then case when e.source_kind = 'crm_email'
                                then (select cma.market_code_of(p_tenant_id, cr.market)
                                      from cma.crm_association a
                                      join cma.crm_record cr
                                        on cr.tenant_id = a.tenant_id and cr.connection_id = a.connection_id and cr.record_type = a.to_type
                                       and cr.source_id = a.to_id
                                      where a.tenant_id = p_tenant_id and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                        and a.from_id = e.source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null
                                        and cr.source_deleted_at is null and cma.market_code_of(p_tenant_id, cr.market) is not null
                                      order by (a.to_type = 'ticket') desc, cr.source_created_at desc, cr.source_id
                                      limit 1)
                                else (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                                      where cr.tenant_id = p_tenant_id and cr.connection_id = e.connection_id and cr.record_type = 'ticket'
                                        and cr.source_id = e.ticket and cr.source_deleted_at is null) end
        when 'inbox' then coalesce(mv.code_of ->> e.ac_market, mv.code_of ->> e.inbox_market)
      end,
      'unknown') as code
    offset 0) mk
  cross join lateral (select coalesce(s.zone_of ->> mk.code, s.tenant_zone) as zone offset 0) z
$$;

-- As 0008t: the counted conversations of a tenant (counted inbox, mailbox and channel, one the catalog has
-- not brought yet counts; not spam) with the labels and the market as cma.email_market_of gives it, and its
-- zone; the contact's and the inbox's steps by joins and one map, as cma.email_of above
create or replace function cma.email_threads_counted_of(p_tenant_id uuid, p_thread_ids uuid[])
returns table (
  id                uuid,
  connection_id     uuid,
  source_system     text,
  source_id         text,
  inbox_key         text,
  inbox_name        text,
  account_key       text,
  account_name      text,
  category          text,
  status            text,
  market            text,
  zone              text
)
language sql stable
-- the planner adds up the cost of every step of the market chain although at most one runs per row:
-- without this, that estimate starts a JIT compilation that costs more than the read
set jit = off
as $$
  with s as materialized (
    select t.timezone as tenant_zone, string_to_array(cma.setting_of(t.id, 'email.market_order'), ',') as ord,
           (select coalesce(jsonb_object_agg(m.code, m.time_zone), '{}'::jsonb) from cma.market m where m.tenant_id = t.id) as zone_of
    from cma.tenant t where t.id = p_tenant_id
  ),
  t as materialized (
    select th.id, th.connection_id, th.source_system, th.source_id, th.inbox_source_id, th.account_ref, th.category, th.status,
           th.contact_source_id, th.ticket_source_id, th.source_created_at,
           ib.name as ib_name, ib.market as ib_market, coalesce(ac.label, ac.name) as ac_name, ac.market as ac_market,
           cc.country as contact_country
    from cma.email_thread th
    left join cma.connection_inbox ib
      on ib.tenant_id = th.tenant_id and ib.connection_id = th.connection_id and ib.source_inbox_id = th.inbox_source_id
    left join cma.connection_inbox_account ac
      on ac.tenant_id = th.tenant_id and ac.connection_id = th.connection_id and ac.source_account_id = th.account_ref
    left join cma.connection_inbox_channel ch
      on ch.tenant_id = th.tenant_id and ch.connection_id = th.connection_id and ch.source_channel_id = th.channel_source_id
    left join cma.crm_contact cc
      on cc.tenant_id = th.tenant_id and cc.connection_id = th.connection_id and cc.source_id = th.contact_source_id
    where th.tenant_id = p_tenant_id and th.id = any (p_thread_ids)
      and not th.is_spam
      and coalesce(ib.is_counted, true) and coalesce(ac.is_counted, true) and coalesce(ch.is_counted, true)
  ),
  -- the catalog market of every value those steps read, once per value, as one map
  mv as materialized (
    select coalesce(jsonb_object_agg(v.value, cma.market_code_of(p_tenant_id, v.value)), '{}'::jsonb) as code_of
    from (select t.contact_country as value from t union select t.ac_market from t union select t.ib_market from t) v
    where v.value is not null
  )
  select t.id, t.connection_id, t.source_system, t.source_id,
         case when t.inbox_source_id is not null then t.connection_id::text || ':' || t.inbox_source_id end,
         coalesce(t.ib_name, t.inbox_source_id),
         case when t.account_ref is not null then t.connection_id::text || ':' || t.account_ref end,
         coalesce(t.ac_name, t.account_ref),
         t.category, t.status, mk.code, coalesce(s.zone_of ->> mk.code, s.tenant_zone)
  from t
  cross join s
  cross join mv
  -- the market chain of cma.email_market_of for a conversation (as cma.email_of)
  cross join lateral (
    select
      coalesce(
      case s.ord[1]
        when 'contact' then mv.code_of ->> t.contact_country
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = t.connection_id and fs.contact_source_id = t.contact_source_id
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= t.source_created_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                            where cr.tenant_id = p_tenant_id and cr.connection_id = t.connection_id and cr.record_type = 'ticket'
                              and cr.source_id = t.ticket_source_id and cr.source_deleted_at is null)
        when 'inbox' then coalesce(mv.code_of ->> t.ac_market, mv.code_of ->> t.ib_market)
      end,
      case s.ord[2]
        when 'contact' then mv.code_of ->> t.contact_country
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = t.connection_id and fs.contact_source_id = t.contact_source_id
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= t.source_created_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                            where cr.tenant_id = p_tenant_id and cr.connection_id = t.connection_id and cr.record_type = 'ticket'
                              and cr.source_id = t.ticket_source_id and cr.source_deleted_at is null)
        when 'inbox' then coalesce(mv.code_of ->> t.ac_market, mv.code_of ->> t.ib_market)
      end,
      case s.ord[3]
        when 'contact' then mv.code_of ->> t.contact_country
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = t.connection_id and fs.contact_source_id = t.contact_source_id
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= t.source_created_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                            where cr.tenant_id = p_tenant_id and cr.connection_id = t.connection_id and cr.record_type = 'ticket'
                              and cr.source_id = t.ticket_source_id and cr.source_deleted_at is null)
        when 'inbox' then coalesce(mv.code_of ->> t.ac_market, mv.code_of ->> t.ib_market)
      end,
      case s.ord[4]
        when 'contact' then mv.code_of ->> t.contact_country
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = t.connection_id and fs.contact_source_id = t.contact_source_id
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= t.source_created_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                            where cr.tenant_id = p_tenant_id and cr.connection_id = t.connection_id and cr.record_type = 'ticket'
                              and cr.source_id = t.ticket_source_id and cr.source_deleted_at is null)
        when 'inbox' then coalesce(mv.code_of ->> t.ac_market, mv.code_of ->> t.ib_market)
      end,
      'unknown') as code
    offset 0) mk
$$;

-- As 0008t (every rule in the comment of 0008t's cma.email_openings_of), computed differently: the business
-- seconds of the reply and of the close as cma.business_seconds_of defines them, in the query itself instead
-- of two calls per opening
create or replace function cma.email_openings_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  connection_id           uuid,
  source_system           text,
  thread_source_id        text,
  inbox_key               text,
  inbox_name              text,
  account_key             text,
  account_name            text,
  category                text,
  opening_kind            text,
  opened_at               timestamptz,
  market                  text,
  zone                    text,
  business_date           date,
  week_start              date,
  local_hour              integer,
  first_in_at             timestamptz,
  first_reply_at          timestamptz,
  reply_owner_ref         text,
  reply_seconds           integer,
  reply_business_seconds  integer,
  reply_within_target     boolean,
  closed_at               timestamptz,
  close_actor_kind        text,
  close_owner_ref         text,
  close_seconds           integer,
  close_business_seconds  integer
)
language sql stable
as $$
  with s as (
    select greatest(1, cma.setting_of(t.id, 'email.reply_target_minutes')::integer) * 60 as target
    from cma.tenant t where t.id = p_tenant_id
  ),
  o as (
    select th.id as thread_id, 'created'::text as kind, th.source_created_at as open_at, '-infinity'::timestamptz as span_from
    from cma.email_thread th
    where th.tenant_id = p_tenant_id and th.source_created_at >= p_from and th.source_created_at < p_to
    union all
    select th.id, 'reopened', ev.occurred_at, pc.at
    from cma.email_thread_event ev
    join cma.email_thread th
      on th.tenant_id = ev.tenant_id and th.connection_id = ev.connection_id and th.source_id = ev.thread_source_id
    cross join lateral (
      select max(c.occurred_at) filter (where c.kind = 'closed') as at,
             max(c.occurred_at) filter (where c.kind = 'reopened') as reopened_at
      from cma.email_thread_event c
      where c.tenant_id = ev.tenant_id and c.connection_id = ev.connection_id and c.thread_source_id = ev.thread_source_id
        and c.kind in ('closed', 'reopened') and c.occurred_at < ev.occurred_at) pc
    where ev.tenant_id = p_tenant_id and ev.kind = 'reopened'
      and ev.occurred_at >= p_from and ev.occurred_at < p_to
      and pc.at is not null and pc.at >= coalesce(pc.reopened_at, '-infinity'::timestamptz)
  ),
  t as (
    select x.* from cma.email_threads_counted_of(p_tenant_id, (select coalesce(array_agg(distinct o.thread_id), '{}') from o)) x
  ),
  -- each market's zone and office-hours schedule (its own hours, else '*'), as cma.business_seconds_of reads them
  ms as materialized (
    select m.code as market, m.time_zone,
           case when exists (select 1 from cma.business_hours h where h.tenant_id = p_tenant_id and h.market = m.code) then m.code else '*' end
             as sched
    from cma.market m
    where m.tenant_id = p_tenant_id
  )
  select t.connection_id, t.source_system, t.source_id, t.inbox_key, t.inbox_name, t.account_key, t.account_name, t.category,
         o.kind, o.open_at, t.market, t.zone,
         (o.open_at at time zone t.zone)::date,
         date_trunc('week', (o.open_at at time zone t.zone)::date::timestamp)::date,
         extract(hour from (o.open_at at time zone t.zone))::integer,
         fi.at, fr.at, fr.owner_ref,
         extract(epoch from fr.at - fi.at)::integer,
         rb.seconds,
         rb.seconds <= s.target,
         cl.at, cl.actor_kind, cl.owner_ref,
         extract(epoch from cl.at - o.open_at)::integer,
         cb.seconds
  from o
  join t on t.id = o.thread_id
  cross join s
  left join ms on ms.market = t.market
  left join lateral (
    select c.occurred_at as at, c.actor_kind, c.owner_ref
    from cma.email_thread_event c
    where c.tenant_id = p_tenant_id and c.connection_id = t.connection_id and c.thread_source_id = t.source_id
      and c.kind = 'closed' and c.occurred_at >= o.open_at
    order by c.occurred_at, c.source_id
    limit 1) cl on true
  left join lateral (
    select min(m.occurred_at) as at
    from cma.email_message m
    where m.tenant_id = p_tenant_id and m.connection_id = t.connection_id and m.thread_source_id = t.source_id
      and m.source_kind = 'inbox_message' and m.direction in ('in', 'forwarded') and m.source_deleted_at is null
      and m.occurred_at > o.span_from and (cl.at is null or m.occurred_at <= cl.at)) fi on true
  left join lateral (
    select m.occurred_at as at, m.owner_ref
    from cma.email_message m
    where fi.at is not null
      and m.tenant_id = p_tenant_id and m.connection_id = t.connection_id and m.thread_source_id = t.source_id
      and m.source_kind = 'inbox_message' and m.direction = 'out' and m.actor_kind = 'agent' and m.status <> 'failed'
      and m.source_deleted_at is null
      and m.occurred_at > fi.at and (cl.at is null or m.occurred_at <= cl.at)
    order by m.occurred_at, m.source_id
    limit 1) fr on true
  -- the business seconds of the reply and of the close as cma.business_seconds_of gives them, set-based: the
  -- office hours of each local date the span touches (the market's schedule that weekday), holidays of the
  -- market and of '*' left out; none for a market outside the catalog, 0 for an empty span
  cross join lateral (
    select case when fr.at is null or ms.market is null then null
                when fr.at <= fi.at then 0
                else (select coalesce(sum(greatest(0, extract(epoch from least((g.ts::date + h.closes_at) at time zone ms.time_zone, fr.at)
                                                                - greatest((g.ts::date + h.opens_at) at time zone ms.time_zone, fi.at)))), 0)::integer
                  from generate_series((fi.at at time zone ms.time_zone)::date, (fr.at at time zone ms.time_zone)::date, interval '1 day') g(ts)
                  join cma.business_hours h
                    on h.tenant_id = p_tenant_id and h.market = ms.sched and h.weekday = extract(isodow from g.ts::date)
                  where not exists (select 1 from cma.business_holiday b
                                    where b.tenant_id = p_tenant_id and b.market in (t.market, '*') and b.day = g.ts::date)) end as seconds) rb
  cross join lateral (
    select case when cl.at is null or ms.market is null then null
                when cl.at <= o.open_at then 0
                else (select coalesce(sum(greatest(0, extract(epoch from least((g.ts::date + h.closes_at) at time zone ms.time_zone, cl.at)
                                                                - greatest((g.ts::date + h.opens_at) at time zone ms.time_zone, o.open_at)))), 0)::integer
                  from generate_series((o.open_at at time zone ms.time_zone)::date, (cl.at at time zone ms.time_zone)::date, interval '1 day') g(ts)
                  join cma.business_hours h
                    on h.tenant_id = p_tenant_id and h.market = ms.sched and h.weekday = extract(isodow from g.ts::date)
                  where not exists (select 1 from cma.business_holiday b
                                    where b.tenant_id = p_tenant_id and b.market in (t.market, '*') and b.day = g.ts::date)) end as seconds) cb
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Email: one read of a span for the figures, the report and the per-person page
-- ---------------------------------------------------------------------------------------------
-- What the email figures count, one row per email, opening or close (cma.email_of, email_openings_of,
-- email_closes_of): its date, week, hour and time of day in its zone, the groups, the flags, the reply and
-- the close; the actor and owner id of an email (the sender) and of a close (the closer), and the replying
-- agent's owner id of an opening
do $$
begin
  if to_regtype('cma.email_fact') is null then
    create type cma.email_fact as (
      what                     text,
      source_system            text,
      business_date            date,
      week_start               date,
      local_hour               integer,
      local_time               time,
      zone                     text,
      market                   text,
      inbox_key                text,
      inbox_name               text,
      account_key              text,
      account_name             text,
      category                 text,
      is_received              boolean,
      is_logged_reply          boolean,
      is_agent_send            boolean,
      is_automated             boolean,
      is_bounced_failed        boolean,
      actor_kind               text,
      owner_ref                text,
      first_reply_at           timestamptz,
      reply_owner_ref          text,
      reply_seconds            integer,
      reply_business_seconds   integer,
      reply_within_target      boolean,
      closed_at                timestamptz,
      close_seconds            integer,
      close_business_seconds   integer
    );
  end if;
end
$$;
comment on type cma.email_fact is
  'One email, conversation opening or close as the email figures count it (0008x): the reads hand a span read once to the figures, the report and per person';

-- The emails, openings and closes of the business dates [p_from, p_to] in one pass: from the day before
-- p_from to two days after p_to in the tenant's zone, as 0008t's figures read them (each row's business
-- date is in its own market's zone); the reads below keep the dates they count
create or replace function cma.email_facts_of(p_tenant_id uuid, p_from date, p_to date)
returns cma.email_fact[]
language sql stable
as $$
  with b as (
    select (p_from - 1)::timestamp at time zone t.timezone as from_at, (p_to + 2)::timestamp at time zone t.timezone as to_at
    from cma.tenant t where t.id = p_tenant_id
  )
  select coalesce(array_agg(u.f), '{}')
  from (
    select row('email', x.source_system, x.business_date, x.week_start, x.local_hour, x.local_time, x.zone, x.market, x.inbox_key,
               x.inbox_name, x.account_key, x.account_name, x.category, x.is_received, x.is_logged_reply, x.is_agent_send, x.is_automated,
               x.is_bounced_failed, x.actor_kind, x.owner_ref, null, null, null, null, null, null, null, null)::cma.email_fact as f
    from b cross join lateral cma.email_of(p_tenant_id, b.from_at, b.to_at) x
    union all
    select row('opening', x.source_system, x.business_date, x.week_start, x.local_hour, (x.opened_at at time zone x.zone)::time, x.zone,
               x.market, x.inbox_key, x.inbox_name, x.account_key, x.account_name, x.category, false, false, false, false, false, null, null,
               x.first_reply_at, x.reply_owner_ref, x.reply_seconds, x.reply_business_seconds, x.reply_within_target, x.closed_at,
               x.close_seconds, x.close_business_seconds)::cma.email_fact
    from b cross join lateral cma.email_openings_of(p_tenant_id, b.from_at, b.to_at) x
    union all
    select row('close', x.source_system, x.business_date, x.week_start, x.local_hour, (x.closed_at at time zone x.zone)::time, x.zone,
               x.market, x.inbox_key, x.inbox_name, x.account_key, x.account_name, x.category, false, false, false, false, false,
               x.actor_kind, x.owner_ref, null, null, null, null, null, null, null, null)::cma.email_fact
    from b cross join lateral cma.email_closes_of(p_tenant_id, b.from_at, b.to_at) x
  ) u
$$;

-- The figures of business dates [p_from, p_to] from facts already read (0008t's cma.email_figures_of,
-- unchanged: each row's own zone; narrowed by the filters before anything is counted; per group of each
-- dimension asked for and in total; with p_until the last date counts only up to p_until's time of day in
-- each row's zone). Only the columns the counts read go into the sort
create or replace function cma.email_figures_from(p_facts cma.email_fact[], p_from date, p_to date, p_market text, p_inbox text,
                                                  p_account text, p_dimensions text[], p_until timestamptz default null)
returns table (
  dimension                      text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language sql stable
as $$
  with facts as materialized (
    select f.*, f.business_date::text as day_key, f.week_start::text as week_key from unnest(p_facts) f
    where f.business_date between p_from and p_to
      and (p_until is null or f.business_date < p_to or f.local_time <= (p_until at time zone f.zone)::time)
      and (p_market is null or f.market = p_market)
      and (p_inbox is null or f.inbox_key = p_inbox)
      and (p_account is null or f.account_key = p_account)
  ),
  -- the total and every dimension asked for, each once: the groups of 0008t
  dims as (
    select distinct d.dim
    from unnest(array['total'] || p_dimensions) d(dim)
    where d.dim in ('total', 'day', 'week', 'market', 'inbox', 'account', 'category', 'day_inbox', 'week_inbox', 'day_account', 'week_account')
  ),
  g as materialized (
    select d.dim,
           case d.dim when 'total' then null
                      when 'day' then f.day_key
                      when 'week' then f.week_key
                      when 'market' then f.market
                      when 'inbox' then coalesce(f.inbox_key, 'none')
                      when 'account' then coalesce(f.account_key, 'none')
                      when 'category' then coalesce(f.category, 'none')
                      when 'day_inbox' then f.day_key || '|' || coalesce(f.inbox_key, 'none')
                      when 'week_inbox' then f.week_key || '|' || coalesce(f.inbox_key, 'none')
                      when 'day_account' then f.day_key || '|' || coalesce(f.account_key, 'none')
                      when 'week_account' then f.week_key || '|' || coalesce(f.account_key, 'none') end as k,
           case d.dim when 'total' then null
                      when 'day' then f.day_key
                      when 'week' then f.week_key
                      when 'market' then f.market
                      when 'inbox' then f.inbox_name
                      when 'account' then f.account_name
                      when 'category' then f.category
                      when 'day_inbox' then f.inbox_name
                      when 'week_inbox' then f.inbox_name
                      when 'day_account' then f.account_name
                      when 'week_account' then f.account_name end as l,
           f.what, f.is_received, f.is_logged_reply, f.is_agent_send, f.is_automated, f.is_bounced_failed, f.first_reply_at,
           f.reply_seconds, f.reply_business_seconds, f.reply_within_target, f.closed_at, f.close_seconds, f.close_business_seconds
    from facts f
    cross join dims d
  ),
  -- the counts need no order (hashable); the medians need the openings only, sorted per group
  counts as (
    select g.dim, g.k, max(g.l) as l,
           (count(*) filter (where g.what = 'email' and g.is_received))::integer as received,
           (count(*) filter (where g.what = 'email' and g.is_logged_reply))::integer as logged_replies,
           (count(*) filter (where g.what = 'email' and g.is_agent_send))::integer as sent_agent,
           (count(*) filter (where g.what = 'email' and g.is_automated))::integer as sent_automated,
           (count(*) filter (where g.what = 'email' and g.is_bounced_failed))::integer as bounced_failed,
           (count(*) filter (where g.what = 'opening'))::integer as threads_opened,
           (count(*) filter (where g.what = 'close'))::integer as threads_closed,
           (count(*) filter (where g.what = 'opening' and g.first_reply_at is not null))::integer as replied,
           (count(*) filter (where g.what = 'opening' and g.reply_within_target))::integer as within_target,
           (count(*) filter (where g.what = 'opening' and g.reply_business_seconds is not null))::integer as target_known,
           (count(*) filter (where g.what = 'opening' and g.first_reply_at is not null and g.reply_business_seconds is null))::integer as no_hours
    from g
    group by g.dim, g.k
  ),
  medians as (
    select g.dim, g.k,
           percentile_cont(0.5) within group (order by g.reply_seconds) filter (where g.first_reply_at is not null) as rm,
           percentile_cont(0.5) within group (order by g.reply_business_seconds) filter (where g.reply_business_seconds is not null) as rbm,
           percentile_cont(0.5) within group (order by g.close_seconds) filter (where g.closed_at is not null) as cm,
           percentile_cont(0.5) within group (order by g.close_business_seconds) filter (where g.close_business_seconds is not null) as cbm
    from g
    where g.what = 'opening'
    group by g.dim, g.k
  ),
  agg as materialized (
    select c.*, m.rm, m.rbm, m.cm, m.cbm
    from counts c
    left join medians m on m.dim = c.dim and m.k is not distinct from c.k
  )
  select a.dim, a.k, a.l, a.received, a.logged_replies, a.sent_agent, a.sent_automated, a.bounced_failed, a.threads_opened,
         a.threads_closed, a.replied, round(a.rm::numeric, 1), round(a.rbm::numeric, 1), a.within_target, a.target_known, a.no_hours,
         round(a.cm::numeric, 1), round(a.cbm::numeric, 1)
  from agg a
  union all
  -- the total is there even for a period without anything
  select 'total', null, null, 0, 0, 0, 0, 0, 0, 0, 0, null, null, 0, 0, 0, null, null
  where not exists (select 1 from agg where agg.dim = 'total')
  order by 1, 2
$$;

-- As 0008t, over one read of the dates
create or replace function cma.email_figures_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_inbox text, p_account text,
                                                p_dimensions text[], p_until timestamptz default null)
returns table (
  dimension                      text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language sql stable
as $$
  with r as materialized (select cma.email_facts_of(p_tenant_id, p_from, p_to) as facts)
  select f.* from r cross join lateral cma.email_figures_from(r.facts, p_from, p_to, p_market, p_inbox, p_account, p_dimensions, p_until) f
$$;

-- As 0008t: the overview, now in one pass over the previous span's first date to the period's last
create or replace function cma.email_overview_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_market text, p_inbox text,
                                                 p_account text, p_now timestamptz default now())
returns table (
  period                         text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language sql stable
as $$
  with v as (select * from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now)),
  r as materialized (select cma.email_facts_of(p_tenant_id, v.prev_from, p_to) as facts from v)
  select x.period, x.group_key, x.group_label, x.received, x.logged_replies, x.sent_agent, x.sent_automated, x.bounced_failed,
         x.threads_opened, x.threads_closed, x.replied, x.reply_median_seconds, x.reply_median_business_seconds, x.within_target,
         x.target_known, x.no_hours, x.close_median_seconds, x.close_median_business_seconds
  from (
    select 'current'::text as period, 1 as part, f.dimension = 'total' as is_total, f.*
    from r cross join lateral cma.email_figures_from(r.facts, p_from, p_to, p_market, p_inbox, p_account, array[p_group]) f
    union all
    select 'previous', 2, true, f.*
    from r cross join v
    cross join lateral cma.email_figures_from(r.facts, v.prev_from, v.prev_to, p_market, p_inbox, p_account, '{}'::text[], v.until) f
  ) x
  order by x.part, x.is_total, case when p_group in ('day', 'week') then x.group_key end, x.group_label, x.group_key
$$;

-- The period's figures per inbox, mailbox, category and market from facts already read, for the report's
-- tables and its filter lists (0008t's cma.email_by_dimension_of, unchanged)
create or replace function cma.email_by_dimension_from(p_facts cma.email_fact[], p_from date, p_to date, p_market text, p_inbox text,
                                                       p_account text)
returns table (
  dimension                      text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language sql stable
as $$
  select f.* from cma.email_figures_from(p_facts, p_from, p_to, p_market, p_inbox, p_account, array['inbox', 'account', 'category', 'market']) f
  where f.dimension <> 'total'
  order by array_position(array['inbox', 'account', 'category', 'market'], f.dimension), f.group_key = 'none', f.group_label, f.group_key
$$;

-- As 0008t, over one read of the dates
create or replace function cma.email_by_dimension_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_inbox text,
                                                     p_account text)
returns table (
  dimension                      text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language sql stable
as $$
  with r as materialized (select cma.email_facts_of(p_tenant_id, p_from, p_to) as facts)
  select f.* from r cross join lateral cma.email_by_dimension_from(r.facts, p_from, p_to, p_market, p_inbox, p_account) f
$$;

-- The report from facts already read (they hold the period and its previous span): the period's figures
-- per p_group (day or week), market, inbox, mailbox and category, the received messages per date and inbox
-- and per date and mailbox, and the total ('current'); then the previous period's total ('previous'), like
-- for like (0008t's cma.email_report_of, unchanged)
create or replace function cma.email_report_from(p_tenant_id uuid, p_facts cma.email_fact[], p_from date, p_to date, p_group text,
                                                 p_market text, p_inbox text, p_account text, p_now timestamptz)
returns table (
  period                         text,
  dimension                      text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language sql stable
as $$
  select x.period, x.dimension, x.group_key, x.group_label, x.received, x.logged_replies, x.sent_agent, x.sent_automated,
         x.bounced_failed, x.threads_opened, x.threads_closed, x.replied, x.reply_median_seconds, x.reply_median_business_seconds,
         x.within_target, x.target_known, x.no_hours, x.close_median_seconds, x.close_median_business_seconds
  from (
    select 'current'::text as period, 1 as part, f.*
    from cma.email_figures_from(p_facts, p_from, p_to, p_market, p_inbox, p_account,
                                array[p_group, 'market', 'inbox', 'account', 'category', p_group || '_inbox', p_group || '_account']) f
    union all
    select 'previous', 2, f.*
    from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now) v
    cross join lateral cma.email_figures_from(p_facts, v.prev_from, v.prev_to, p_market, p_inbox, p_account, '{}'::text[], v.until) f
  ) x
  order by x.part, x.dimension, x.group_key
$$;

-- As 0008t: the report page's figures, now in one pass over the previous span's first date to the period's last
create or replace function cma.email_report_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_market text, p_inbox text,
                                               p_account text, p_now timestamptz default now())
returns table (
  period                         text,
  dimension                      text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language sql stable
as $$
  with r as materialized (
    select cma.email_facts_of(p_tenant_id, v.prev_from, p_to) as facts from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now) v
  )
  select x.* from r cross join lateral cma.email_report_from(p_tenant_id, r.facts, p_from, p_to, p_group, p_market, p_inbox, p_account, p_now) x
$$;

-- Per person from facts already read (0008t's cma.email_per_person_of, unchanged): the agent sends, the
-- first replies and the closes by an agent, each matched to the person holding '<adapter>_owner' with that
-- id; an owner id without a person, or a send without an owner, not linked (with the count of such owner
-- ids, never which); then the total; sends per hour of day in each email's own zone
create or replace function cma.email_per_person_from(p_tenant_id uuid, p_facts cma.email_fact[], p_from date, p_to date, p_market text,
                                                     p_inbox text, p_account text)
returns table (
  row_kind                       text,
  user_id                        uuid,
  display_name                   text,
  unlinked_owners                integer,
  sent                           integer,
  replies                        integer,
  threads_closed                 integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  sent_by_hour                   integer[]
)
language sql stable
as $$
  with f as materialized (
    select x.* from unnest(p_facts) x
    where x.business_date between p_from and p_to
      and (p_market is null or x.market = p_market) and (p_inbox is null or x.inbox_key = p_inbox)
      and (p_account is null or x.account_key = p_account)
  ),
  acts as (
    select 'send'::text as what, f.source_system, f.owner_ref, f.local_hour, null::integer as rs, null::integer as rbs, null::boolean as wt
    from f where f.what = 'email' and f.is_agent_send
    union all
    select 'reply', f.source_system, f.reply_owner_ref, null, f.reply_seconds, f.reply_business_seconds, f.reply_within_target
    from f where f.what = 'opening' and f.first_reply_at is not null
    union all
    select 'close', f.source_system, f.owner_ref, null, null, null, null
    from f where f.what = 'close' and f.actor_kind = 'agent'
  ),
  p as (
    select case when u.id is null then 'not_linked' else 'person' end as row_kind, u.id as user_id, u.display_name, a.*
    from acts a
    left join cma.app_user_external_id xi
      on xi.tenant_id = p_tenant_id and xi.system = a.source_system || '_owner' and xi.external_id = a.owner_ref
    left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = xi.user_id
  )
  select coalesce(p.row_kind, 'total'), p.user_id, p.display_name,
         case when p.row_kind = 'not_linked' then (count(distinct p.owner_ref))::integer end,
         (count(*) filter (where p.what = 'send'))::integer,
         (count(*) filter (where p.what = 'reply'))::integer,
         (count(*) filter (where p.what = 'close'))::integer,
         round((percentile_cont(0.5) within group (order by p.rs) filter (where p.what = 'reply'))::numeric, 1),
         round((percentile_cont(0.5) within group (order by p.rbs) filter (where p.what = 'reply' and p.rbs is not null))::numeric, 1),
         (count(*) filter (where p.what = 'reply' and p.wt))::integer,
         (count(*) filter (where p.what = 'reply' and p.rbs is not null))::integer,
         array(select (select count(*) from unnest(array_agg(p.local_hour) filter (where p.what = 'send')) x where x = h)::integer
               from generate_series(0, 23) h)
  from p
  group by grouping sets ((p.row_kind, p.user_id, p.display_name), ())
  order by grouping(p.row_kind), p.row_kind = 'not_linked', p.display_name, p.user_id
$$;

-- As 0008t, over one read of the dates
create or replace function cma.email_per_person_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_inbox text, p_account text)
returns table (
  row_kind                       text,
  user_id                        uuid,
  display_name                   text,
  unlinked_owners                integer,
  sent                           integer,
  replies                        integer,
  threads_closed                 integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  sent_by_hour                   integer[]
)
language sql stable
as $$
  with r as materialized (select cma.email_facts_of(p_tenant_id, p_from, p_to) as facts)
  select p.* from r cross join lateral cma.email_per_person_from(p_tenant_id, r.facts, p_from, p_to, p_market, p_inbox, p_account) p
$$;

-- The Email report page in one read and one pass (reports.view or performance.team): the rows of
-- cma.email_report, then, when a filter is set, the period's figures per inbox, mailbox, category and
-- market without the filters (period 'unfiltered', as cma.email_by_dimension), for the filter lists. The
-- checks of cma.email_report, once
create or replace function cma.email_report_page(p_from date, p_to date, p_group text, p_market text, p_inbox text, p_account text)
returns table (
  period                         text,
  dimension                      text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_now    timestamptz := now();
  v_facts  cma.email_fact[];
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'week') then
    raise exception 'group by day or week, not %', p_group using errcode = 'CMA04';
  end if;
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.email_filters_check(p_market, p_inbox, p_account);
  -- the one pass: the previous span's first date to the period's last
  select cma.email_facts_of(v_tenant, v.prev_from, p_to) into v_facts from cma.forms_previous_of(v_tenant, p_from, p_to, v_now) v;
  return query select * from cma.email_report_from(v_tenant, v_facts, p_from, p_to, p_group, p_market, p_inbox, p_account, v_now);
  if p_market is not null or p_inbox is not null or p_account is not null then
    return query select 'unfiltered'::text, f.* from cma.email_by_dimension_from(v_facts, p_from, p_to, null, null, null) f;
  end if;
end
$$;

-- The Email per agent page in one read and one pass (performance.team and reports.per_person holding
-- email, as cma.email_per_person): the rows of cma.email_per_person (part 'person'), then the period's
-- figures per inbox, mailbox, category and market without the filters (part 'dimension', as
-- cma.email_by_dimension), for the filter lists; the columns a part does not use are null
create or replace function cma.email_per_person_page(p_from date, p_to date, p_market text, p_inbox text, p_account text)
returns table (
  part                           text,
  row_kind                       text,
  user_id                        uuid,
  display_name                   text,
  unlinked_owners                integer,
  sent                           integer,
  replies                        integer,
  sent_by_hour                   integer[],
  dimension                      text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_facts  cma.email_fact[];
begin
  perform cma.assert_per_person('email');
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.email_filters_check(p_market, p_inbox, p_account);
  v_facts := cma.email_facts_of(v_tenant, p_from, p_to);
  return query
    select 'person'::text, p.row_kind, p.user_id, p.display_name, p.unlinked_owners, p.sent, p.replies, p.sent_by_hour,
           null::text, null::text, null::text, null::integer, null::integer, null::integer, null::integer, null::integer, null::integer,
           p.threads_closed, null::integer, p.reply_median_seconds, p.reply_median_business_seconds, p.within_target, p.target_known,
           null::integer, null::numeric, null::numeric
    from cma.email_per_person_from(v_tenant, v_facts, p_from, p_to, p_market, p_inbox, p_account) p;
  return query
    select 'dimension'::text, null::text, null::uuid, null::text, null::integer, null::integer, null::integer, null::integer[],
           f.dimension, f.group_key, f.group_label, f.received, f.logged_replies, f.sent_agent, f.sent_automated, f.bounced_failed,
           f.threads_opened, f.threads_closed, f.replied, f.reply_median_seconds, f.reply_median_business_seconds, f.within_target,
           f.target_known, f.no_hours, f.close_median_seconds, f.close_median_business_seconds
    from cma.email_by_dimension_from(v_facts, p_from, p_to, null, null, null) f;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.first_orders_of(uuid,timestamptz,timestamptz)',
    'cma.first_orders_rows_of(uuid,date,date)',
    'cma.first_orders_figures_from(cma.first_order[],date,date,text,text,text[],timestamptz)',
    'cma.first_orders_figures_of(uuid,date,date,text,text,text[],timestamptz)',
    'cma.first_orders_report_from(uuid,cma.first_order[],date,date,text,text,text,timestamptz)',
    'cma.first_orders_report_of(uuid,date,date,text,text,text,timestamptz)',
    'cma.first_orders_amounts_from(cma.first_order[],date,date,text,text)',
    'cma.first_orders_amounts_of(uuid,date,date,text,text)',
    'cma.first_orders_list_from(cma.first_order[],date,date,text,text,integer)',
    'cma.first_orders_list(date,date,text,text,integer)',
    'cma.first_orders_page(date,date,text,text,text,integer)',
    'cma.email_of(uuid,timestamptz,timestamptz)',
    'cma.email_threads_counted_of(uuid,uuid[])',
    'cma.email_openings_of(uuid,timestamptz,timestamptz)',
    'cma.email_facts_of(uuid,date,date)',
    'cma.email_figures_from(cma.email_fact[],date,date,text,text,text,text[],timestamptz)',
    'cma.email_figures_of(uuid,date,date,text,text,text,text[],timestamptz)',
    'cma.email_overview_of(uuid,date,date,text,text,text,text,timestamptz)',
    'cma.email_by_dimension_from(cma.email_fact[],date,date,text,text,text)',
    'cma.email_by_dimension_of(uuid,date,date,text,text,text)',
    'cma.email_report_from(uuid,cma.email_fact[],date,date,text,text,text,text,timestamptz)',
    'cma.email_report_of(uuid,date,date,text,text,text,text,timestamptz)',
    'cma.email_per_person_from(uuid,cma.email_fact[],date,date,text,text,text)',
    'cma.email_per_person_of(uuid,date,date,text,text,text)',
    'cma.email_report_page(date,date,text,text,text,text)',
    'cma.email_per_person_page(date,date,text,text,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Statistics: the three catalogs autovacuum never analyzed (too few changes), so the planner had no
--    row counts for them (prod, 19 October 2026)
-- ---------------------------------------------------------------------------------------------
analyze cma.market;
analyze cma.market_alias;
analyze cma.app_user_external_id;

-- ---------------------------------------------------------------------------------------------
-- 7. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008x', 'Report speed: cma.first_orders_of with the touches once per first order and the calls set-based, one pass per First orders page (cma.first_order, the *_from reads, cma.first_orders_page), cma.email_of and email_threads_counted_of with the contact as a plain column and the market steps set-based; the catalogs analyzed')
on conflict (version) do nothing;

commit;
reset role;
