-- =============================================================================================
-- 176_active_attribution_present.sql: addition 0009n, Customers → Active: the acquisition channel attributed as Sales →
-- First orders attributes, and the tiles' present live or from the stored take by a tenant setting
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 174_active_refresh_quiet.sql (0009m). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your
-- own IAM login: dev first, then 177_verify_active_attribution_present.sql there (normal, then provoked), then the
-- verifies that read what this script re-creates:
--   cma.active_base_of (through the refresh, cma.active_customers_of and the fresh month ends and cohorts):
--     173_verify_active_customers.sql (edited by this change: where 0009n is recorded it expects the channels this
--     script gives its fixture) and 175_verify_active_refresh_quiet.sql (not edited: both refreshes it compares read
--     the same base);
--   cma.active_now: 173 and 131_time_all.sql part b (its Active rows; not edited).
-- Prod: this script and 177 before the merge of #267; the web of main does not read these functions yet.
--
-- Why (Martin, 12 November 2026, after prod's first runs; Decision log, 12 Nov 2026, "Customers → Active attributes as
-- Sales → First orders ..." and "The tiles' present of Customers → Active can be read from the take ..."):
--   1. Direct / Indirect read 100 % Unknown in prod: 0009l attributed only from the attribution's history start
--      (intake.start_date + attribution.window_days, cma.first_orders_history_start_of), which lay 48 days ahead.
--      Sales → First orders attributes every order deal of its period and names that start as a note. Active now does
--      the same, with the same function (cma.first_orders_of over every order deal the CRM holds): a customer's
--      channel is its first order's attribution, whenever that order was. The start stays what it was, as the note's
--      date (cma.active_take.attribution_start): before it the attribution sees no touches older than the intake
--      start, so some orders count as Direct that may have been Indirect.
--      A customer whose Customer start lies before the first order deal the CRM holds keeps the reason before_history.
--   2. The live present of the tiles took 717 ms at prod's busy hour against 400 ms. 0009m made the live read slimmer;
--      whether that is enough is measured at that hour (tools/perf/active-present-breakdown.sql). The other path is
--      built here beside it: the tenant setting active.present_source, live (the default) or take. With take the four
--      tiles are read from the stored take (cma.active_present_stored_of, a key lookup) and are of the take's moment:
--      the read says source take and the take's computed_at, and the page writes "As of". The choice is Martin's,
--      after the measurement; this script changes no default.
--
-- What it adds
--   setting    active.present_source (live; live or take)
-- What it re-creates (each from its latest definition, 172, with its -- based on: line)
--   cma.active_base_of(tenant, now, channel, start, payment)   first orders read over every order deal; the start
--                                                              argument no longer bounds the read (kept: its callers
--                                                              pass the note's date); before_history against the first
--                                                              order deal; JIT off repeated
--   cma.active_now(market, segment, channel)                    the present by the setting; its answer gains source
-- What it does once: every stored take is marked stale, so the job's next run attributes it again whatever its inputs'
-- markers say (0009m's quiet run would otherwise keep the earlier channels until a marker moves or the date turns).
-- No table, view or column is added or changed.
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
  if not exists (select 1 from cma.schema_migration where version = '0009m') then
    raise exception 'addition 0009m (174_active_refresh_quiet.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The setting
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('active.present_source', 'text', array['live', 'take'], 'live',
     'Where Customers → Active reads the present of its four tiles from: live (the subscriptions as they are, at every view) or take (the stored take, as of the take''s moment: the page says "As of")')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 2. The base: first orders over every order deal, as Sales → First orders reads them
-- ---------------------------------------------------------------------------------------------
-- As 172's, but for the channel: cma.first_orders_of is read over every order deal the CRM holds (from -infinity to
-- p_now), not from p_attribution_start on. p_attribution_start is kept in the signature and no longer bounds the read:
-- its callers go on passing the attribution's history start, which the take stores as the note's date. The reason
-- before_history is now of a customer whose Customer start (the tenant's date) lies before the first order deal's
-- based on: 172_active_customers.sql
create or replace function cma.active_base_of(p_tenant_id uuid, p_now timestamptz, p_with_channel boolean, p_attribution_start date,
                                              p_with_payment boolean)
returns table (subscription_id uuid, connection_id uuid, source_id text, store text, market text, status text, is_holding boolean,
               is_paying boolean, payment_state text, currency text, monthly_amount numeric, billing text, devices_in_field integer,
               started_at timestamptz, ended_at timestamptz, in_history boolean, left_out text,
               customer_id uuid, customer_connection_id uuid, customer_source_id text, segment text, crm_connection_id uuid,
               contact_source_id text, customer_start timestamptz, customer_holding integer, customer_devices integer, clv numeric,
               clv_currency text, channel text, level text, unknown_reason text, first_order_at timestamptz, device_models jsonb)
language sql stable
rows 10000   -- a tenant's subscriptions (CLAUDE.md, Performance: a set-returning function says its rows)
as $$
  with s as materialized (
    select cma.flash_holding_statuses_of(p_tenant_id) as holding, cma.flash_active_statuses_of(p_tenant_id) as paying,
           cma.flash_ended_statuses_of(p_tenant_id) as ended,
           (select t.timezone from cma.tenant t where t.id = p_tenant_id) as zone,
           case when p_with_channel then p_attribution_start end as attribution_start
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  ), ps as materialized (
    select p.subscription_id, p.payment_state from cma.subscription_payment_state_of(p_tenant_id) p where p_with_payment
  ), dev as (
    -- a subscription's devices in the field, and how many of each model (the subscription mix's models)
    select q.subscription_ref, q.market, sum(q.n_field)::integer as n_field,
           jsonb_object_agg(q.model_key, q.n_field) filter (where q.n_field > 0) as models
    from (select d.subscription_ref, d.market, coalesce(d.model_key, 'unknown') as model_key,
                 count(*) filter (where coalesce(ds.is_in_field, false))::integer as n_field
          from cma.device d
          left join cma.device_status ds on ds.tenant_id = d.tenant_id and ds.key = d.device_status_key
          where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.subscription_ref is not null
          group by 1, 2, 3) q
    group by 1, 2
  ), s0 as materialized (
    select x.id, x.connection_id, x.source_id, x.customer_source_id, x.status, x.currency, x.amount_per_cycle, x.billing_interval,
           x.billing_interval_count, x.source_created_at, x.paused_at, x.canceled_at,
           x.status = any ((select s.holding from s)::text[]) as is_holding, x.status = any ((select s.paying from s)::text[]) as is_paying,
           x.status = any ((select s.ended from s)::text[]) as is_ended
    from cma.subscription x
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null
      and (x.status not in ('merged', 'never-subscribed') or x.status = any ((select s.holding from s)::text[]))
  ), ev as (
    -- the event that ended the holding, read only for the subscriptions whose own times do not say it (through
    -- subscription_event_subscription_idx, one range per subscription)
    select n.id, e.at
    from s0 n
    cross join lateral (
      select max(e.occurred_at) as at
      from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = n.connection_id and e.subscription_source_id = n.source_id
        and case when n.status = 'paused' then e.event_type = 'paused' or (e.event_type = 'status_changed' and e.status_to = 'paused')
                 when n.is_ended
                 then (e.event_type = 'canceled' and 'canceled' = any ((select s.ended from s)::text[]))
                   or (e.event_type = 'status_changed' and e.status_to = any ((select s.ended from s)::text[]))
                 else e.event_type = 'status_changed' and e.status_to = n.status end
    ) e
    where not n.is_holding
      and not (n.status = 'paused' and n.paused_at is not null)
      and not (n.status <> 'paused' and n.is_ended and n.canceled_at is not null)
  ), sb as materialized (
    select x.id, x.connection_id, x.source_id, sm.store_connection_id, coalesce(sm.handle, 'unknown') as store,
           coalesce(sm.market, 'unknown') as market, x.customer_source_id, x.status, x.is_holding, x.is_paying,
           x.currency, x.amount_per_cycle * cma.active_month_factor_of(x.billing_interval, x.billing_interval_count) as monthly_amount,
           cma.active_billing_of(x.billing_interval, x.billing_interval_count) as billing, x.source_created_at as started_at,
           case when x.is_holding then null
                when x.status = 'paused' then coalesce(x.paused_at, ev.at)
                when x.is_ended then coalesce(x.canceled_at, ev.at)
                else ev.at end as ended_at,
           coalesce(dev.n_field, 0) as devices_in_field, dev.models as device_models
    from s0 x
    left join sm on sm.connection_id = x.connection_id
    left join ev on ev.id = x.id
    left join dev on dev.subscription_ref = x.source_id and dev.market = coalesce(sm.market, 'unknown')
  ), cu as materialized (
    -- the store customers of these subscriptions, with the earliest creation of their subscriptions here
    select c.id, c.connection_id, c.source_id, least(c.source_created_at, k.first_started) as customer_start
    from (select sb.store_connection_id, sb.customer_source_id, min(sb.started_at) as first_started
          from sb where sb.store_connection_id is not null and sb.customer_source_id is not null group by 1, 2) k
    join cma.commerce_customer c
      on c.tenant_id = p_tenant_id and c.connection_id = k.store_connection_id and c.source_id = k.customer_source_id
     and c.source_deleted_at is null
  ), fig as materialized (
    -- Flash's own figures of these customers (D2): the function read through the customers' primary key
    select f.customer_id, f.segment, f.crm_connection_id, f.contact_source_id, f.holding_subscriptions, f.devices, f.total_spent, f.currency
    from cma.flash_customer_figures_of(p_tenant_id) f
    where f.customer_id = any (array(select cu.id from cu))
  ), fo as materialized (
    -- First orders' rows over the attribution's history, read once (never a second rule)
    select o.connection_id, o.contact_source_id, o.created_at, o.kind, o.order_id, o.level, o.attribution
    from s
    cross join lateral cma.first_orders_of(p_tenant_id, '-infinity'::timestamptz, p_now) o
    where p_with_channel
  ), oc as materialized (
    -- the store customer of each order deal's linked store order
    select cu.id as customer_id, o.kind, o.created_at, o.order_id, o.level, o.attribution
    from fo o
    join cma.commerce_order co on co.tenant_id = p_tenant_id and co.id = o.order_id
    join cu on cu.connection_id = co.connection_id and cu.source_id = co.customer_source_id
    where o.order_id is not null
  ), att as materialized (
    select distinct on (oc.customer_id) oc.customer_id, oc.attribution, oc.level, oc.created_at
    from oc where oc.kind = 'first'
    order by oc.customer_id, oc.created_at, oc.order_id
  ), oth as materialized (
    select distinct oc.customer_id from oc
  ), unm as materialized (
    select distinct o.connection_id, o.contact_source_id from fo o
    where o.kind = 'first' and o.order_id is null and o.contact_source_id is not null
  )
  select sb.id, sb.connection_id, sb.source_id, sb.store, sb.market, sb.status, sb.is_holding, sb.is_paying,
         ps.payment_state, sb.currency, sb.monthly_amount, sb.billing, sb.devices_in_field,
         sb.started_at, sb.ended_at,
         sb.started_at is not null and (sb.is_holding or sb.ended_at is not null),
         case when sb.started_at is null then 'no_created_time' when not sb.is_holding and sb.ended_at is null then 'no_ended_time' end,
         cu.id, cu.connection_id, cu.source_id, coalesce(f.segment, 'unknown'), f.crm_connection_id, f.contact_source_id, cu.customer_start,
         f.holding_subscriptions, f.devices, f.total_spent, f.currency,
         case a.attribution when 'call_center' then 'indirect' when 'self_service' then 'direct' else 'unknown' end,
         a.level,
         case when cu.id is null or a.customer_id is not null or not p_with_channel then null
              when f.contact_source_id is null then 'no_contact'
              when (cu.customer_start at time zone (select s.zone from s))::date
                   < (select (min(o.created_at) at time zone (select s.zone from s))::date from fo o) then 'before_history'
              when oth.customer_id is not null then 'no_first_order'
              when unm.contact_source_id is not null then 'order_not_matched'
              else 'no_order_deal' end,
         a.created_at, sb.device_models
  from sb
  left join ps on ps.subscription_id = sb.id
  left join cu on cu.connection_id = sb.store_connection_id and cu.source_id = sb.customer_source_id
  left join fig f on f.customer_id = cu.id
  left join att a on a.customer_id = cu.id
  left join oth on oth.customer_id = cu.id
  left join unm on unm.connection_id = f.crm_connection_id and unm.contact_source_id = f.contact_source_id
$$;

-- JIT off, as 172 set it (a create or replace drops the setting): the joins are small, and the setting keeps the function
-- out of its callers' plans
alter function cma.active_base_of(uuid, timestamptz, boolean, date, boolean) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 3. The present of the tiles: live, or as the take holds it
-- ---------------------------------------------------------------------------------------------
-- As 172's; the tenant's setting active.present_source chooses the path. D2's equality with Flash holds for the live
-- path at every read and for the take's path at the take's moment (177 checks both)
-- based on: 172_active_customers.sql
create or replace function cma.active_now(p_market text default null, p_segment text default null, p_channel text default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_at     timestamptz := now();
  v_doc    jsonb;
  v_set_up boolean;
  v_taken  timestamptz;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_active_filter(p_market, p_segment, p_channel);
  -- a statement, not an expression (as the reads' heads): its plan is made again when the role changes
  select coalesce(cma.flash_source_set_up_of(v_tenant, 'commerce'), false) and coalesce(cma.flash_source_set_up_of(v_tenant, 'subscriptions'), false)
  into v_set_up;
  if not v_set_up then
    return jsonb_build_object('figures', false, 'computed_at', v_at);
  end if;
  -- the tenant's choice (active.present_source): the present read live, or as the stored take holds it. From the take
  -- the answer is of the take's moment and says so (source take, computed_at the take's); without a take yet it is live
  if cma.setting_of(v_tenant, 'active.present_source') = 'take' then
    select t.computed_at into v_taken from cma.active_take t where t.tenant_id = v_tenant;
  end if;
  if v_taken is not null then
    v_doc := cma.active_now_of(v_tenant, p_market, p_segment, p_channel, v_taken, true);
    return jsonb_build_object('figures', true, 'source', 'take', 'computed_at', v_taken, 'tiles', v_doc -> 'tiles', 'now', v_doc -> 'now');
  end if;
  v_doc := cma.active_now_of(v_tenant, p_market, p_segment, p_channel, v_at, false);
  return jsonb_build_object('figures', true, 'source', 'live', 'computed_at', v_at, 'tiles', v_doc -> 'tiles', 'now', v_doc -> 'now');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Every stored take attributed again at the job's next run
-- ---------------------------------------------------------------------------------------------
-- As a settings save marks it (cma.active_take_mark_stale): the mark and its count. Once: a rerun marks nothing
update cma.active_take t
set stale = true, stale_since = coalesce(t.stale_since, now()), stale_marks = t.stale_marks + 1
where not exists (select 1 from cma.schema_migration m where m.version = '0009n');

-- ---------------------------------------------------------------------------------------------
-- 5. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009n', 'Customers → Active: the acquisition channel attributed as Sales → First orders attributes (cma.first_orders_of over every order deal; the attribution''s history start stays as the note''s date), and the tenant setting active.present_source (live, or take: the four tiles'' present read from the stored take, as of its moment); every stored take is computed again once')
on conflict (version) do nothing;

commit;
reset role;
