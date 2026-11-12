-- =============================================================================================
-- 177_verify_active_attribution_present.sql: verifies addition 0009n, Customers → Active's attribution as Sales → First
-- orders and the tiles' present from the take by a setting
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod, on the data the database holds. One throwaway tenant
-- (G: the setting's refusals; rolled back) and every active tenant with a subscription whose sources are set up, each
-- inside a step that is always rolled back: the tenant's take, its settings and its rows are left as they were. It
-- keeps 172's cma.active_base_of verbatim as a pg_temp function (133's pattern). Run as your own IAM login, after 176.
-- Output: tenant slugs, counts and milliseconds only.
-- While it runs: a tenant's step computes the take twice and holds, until it rolls back, the take's row (a settings
-- save that marks the take stale waits), the active.present_source setting's row, the tenant's refresh lock (the job
-- answers running) and the analyze's lock on the take's tables. Run it outside the busy hours.
-- Rows written during a step: A2 compares the take with First orders' rows read a moment later. An order deal, a call
-- or a store order arriving in between reads A2 FAIL: run again (the inputs' markers do not hold the CRM's deals).
--
-- Checks
--   S1  the addition is recorded after 0009m; the setting active.present_source (live; live or take); the base keeps
--       JIT off; cma.active_now is the application's alone
--   G1  the setting takes live and take and refuses anything else (CMA04)
--   A1  per tenant: the base of 176 equals 172's base read from the first order deal's date on, row for row and both
--       ways (the same rows and reasons as 172 gives once its start lies at the first order deal: only the start moved)
--   A2  per tenant, on the tenant's own data: the acquisition channel, its level and the first order's moment of every
--       customer of the take equal Sales → First orders' attribution of that customer's first order (cma.first_orders_of
--       over every order deal: the earliest first order whose store order is the customer's; call_center indirect,
--       self_service direct), row for row and both ways; an info row gives the counts
--   A3  per tenant: the note's date is unchanged: the take's attribution_start is cma.first_orders_history_start_of's
--   T1  per tenant: the present as the take holds it equals the live present at the take's moment (the four tiles of
--       cma.active_now_of, stored against live), and its Active customers equal Flash's (decision D2: the customers of
--       cma.flash_customer_figures_of with a holding subscription)
--   T2  per tenant, as a reader of the page (skip without one): with the setting at take cma.active_now answers source
--       take and the take's moment; at live, source live and the read's moment
--   E1  per tenant, timed: the forced refresh with the attribution over every order deal within verify.max_refresh_ms
--       (15,000)
--   E2  per tenant, timed: the tiles' present from the take within verify.max_top_ms (400), the best of three after six
--       calls; the detail gives the live path beside it
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id:
-- that check alone compares with a deliberate difference.
-- Collation: every ordering that feeds a compared text says collate "C".
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'A2'
select set_config('verify.max_refresh_ms', '15000', false);          -- the refresh, everything written again (173's E4)
select set_config('verify.max_top_ms', '400', false);                -- the tiles' present (decision D15, 173's E5)

drop table if exists pg_temp.verify_0009n;
create temporary table verify_0009n (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009n to cma_app;

create or replace function pg_temp.v0009n_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0009n_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009n_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009n values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 600)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 2400) end);
end
$$;

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0009n_code(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception
  when others then return sqlstate;
end
$$;

-- 172's definition of the base 176 re-creates, verbatim (133's pattern)
create or replace function pg_temp.v0009n_base_172(p_tenant_id uuid, p_now timestamptz, p_with_channel boolean, p_attribution_start date,
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
    cross join lateral cma.first_orders_of(p_tenant_id, (s.attribution_start::timestamp at time zone s.zone), p_now) o
    where p_with_channel and s.attribution_start is not null
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
              when (select s.attribution_start from s) is not null
                   and (cu.customer_start at time zone (select s.zone from s))::date < (select s.attribution_start from s) then 'before_history'
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


-- ---------------------------------------------------------------------------------------------
-- S. The addition, the setting, the functions
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_txt text;
begin
  select format('versions %s | setting %s | base %s | now %s',
    (select string_agg(m.version, ',' order by m.version collate "C") from cma.schema_migration m where m.version in ('0009m', '0009n')),
    (select format('%s %s %s', s.value_type, array_to_string(s.allowed_values, '/'), s.default_value) from cma.setting s where s.key = 'active.present_source'),
    (select coalesce(array_to_string(p.proconfig, ';'), 'none') from pg_proc p where p.oid = 'cma.active_base_of(uuid,timestamptz,boolean,date,boolean)'::regprocedure),
    (select format('%s/%s', has_function_privilege('cma_app', p.oid, 'execute'), has_function_privilege('public', p.oid, 'execute'))
     from pg_proc p where p.oid = 'cma.active_now(text,text,text)'::regprocedure))
  into v_txt;
  perform pg_temp.v0009n_row(1, 'S1', 'the addition is recorded; the setting, JIT off on the base and the grant of the present''s read are in place', v_txt,
    'versions 0009m,0009n | setting text live/take live | base jit=off | now t/f');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- G. The setting's values, on a throwaway tenant; always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_t uuid;
  v_g text; v_err text;
begin
  begin
    v_t := cma.create_tenant('verify-0009n-one', 'Verify 0009n one', 'Europe/Amsterdam');
    select string_agg(format('%s %s', x.value, pg_temp.v0009n_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, %L, %L) '
                                                                          || 'on conflict (tenant_id, key) do update set value = excluded.value',
                                                                          v_t, 'active.present_source', x.value))), ', ' order by x.ord)
    into v_g
    from (values (1, 'take'), (2, 'live'), (3, 'stored'), (4, 'Take'), (5, '')) x(ord, value);
    v_g := v_g || format(' | kept as %s', (select s.value from cma.tenant_setting s where s.tenant_id = v_t and s.key = 'active.present_source'));
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
  end;
  if v_err is not null then
    insert into pg_temp.verify_0009n values (10, 'G1: the check ran to its end', 'FAIL', v_err);
  else
    perform pg_temp.v0009n_row(10, 'G1', 'the setting takes live and take and refuses anything else (CMA04)', v_g,
      'take ok, live ok, stored CMA04, Take CMA04,  CMA04 | kept as live');
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- A, T, E. Per tenant, inside a step that is always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t record;
  v_now timestamptz := now();
  v_zone text;
  v_any boolean := false;
  v_err text;
  v_first date;
  v_user uuid;
  v_a1 text; v_a2 text; v_a2i text; v_a3 text; v_t1 text; v_t2 text;
  j jsonb; j_take jsonb; j_live jsonb;
  v_t0 timestamptz; v_ms numeric; v_refresh numeric; v_take_ms numeric; v_live_ms numeric;
begin
  for t in select x.id, x.slug from cma.tenant x
           where x.status = 'active' and exists (select 1 from cma.subscription s where s.tenant_id = x.id) order by x.slug collate "C" loop
    if not (coalesce(cma.flash_source_set_up_of(t.id, 'commerce'), false) and coalesce(cma.flash_source_set_up_of(t.id, 'subscriptions'), false)) then
      continue;
    end if;
    v_any := true;
    v_err := null; v_a1 := null; v_a2 := null; v_a2i := null; v_a3 := null; v_t1 := null; v_t2 := null; v_refresh := null; v_take_ms := null; v_live_ms := null;
    v_zone := (select x.timezone from cma.tenant x where x.id = t.id);
    begin
      perform set_config('app.tenant_id', t.id::text, true);
      -- a reader of the page, for T2 (as 131 finds its acting person)
      select u.id into v_user
      from cma.app_user u
      where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person'
        and exists (select 1 from cma.user_role ur where ur.tenant_id = u.tenant_id and ur.user_id = u.id)
        and (cma.has_permission(u.id, 'reports.view') or cma.has_permission(u.id, 'performance.team'))
      order by u.created_at, u.id limit 1;
      perform set_config('role', 'cma_app', true);

      -- A1. the base of 176 against 172's, read from the first order deal's date on: the same rows, both ways
      v_first := (select (min(o.created_at) at time zone v_zone)::date from cma.first_orders_of(t.id, '-infinity'::timestamptz, v_now) o);
      select format('rows differing %s; rows %s',
               (select count(*) from ((select * from cma.active_base_of(t.id, v_now, true, null, true)
                                       except all select * from pg_temp.v0009n_base_172(t.id, v_now, true, v_first, true))
                                      union all
                                      (select * from pg_temp.v0009n_base_172(t.id, v_now, true, v_first, true)
                                       except all select * from cma.active_base_of(t.id, v_now, true, null, true))) q)
               + case when pg_temp.v0009n_p('A1') then 1 else 0 end,
               case when exists (select 1 from cma.active_base_of(t.id, v_now, true, null, true)) then 'some' else 'none' end)
      into v_a1;

      -- the take as 176 writes it; the checks after it read this take
      v_t0 := clock_timestamp();
      j := cma.active_refresh_of(t.id, true, v_now);
      v_refresh := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
      perform set_config('role', 'cma_owner', true);

      -- A2. every customer's channel, level and first order's moment against First orders' own rows: the earliest
      --     first order whose store order is the customer's
      with fo as materialized (
        select o.created_at, o.order_id, o.level, o.attribution
        from cma.first_orders_of(t.id, '-infinity'::timestamptz, v_now) o
        where o.kind = 'first' and o.order_id is not null
      ), want as materialized (
        select distinct on (cu.id) cu.id as customer_id,
               case fo.attribution when 'call_center' then 'indirect' when 'self_service' then 'direct' else 'unknown' end as channel,
               fo.level, fo.created_at as first_order_at
        from fo
        join cma.commerce_order co on co.tenant_id = t.id and co.id = fo.order_id
        join cma.commerce_customer cu on cu.tenant_id = t.id and cu.connection_id = co.connection_id and cu.source_id = co.customer_source_id
                                      and cu.source_deleted_at is null
        join cma.active_customer k on k.tenant_id = t.id and k.customer_id = cu.id
        order by cu.id, fo.created_at, fo.order_id
      ), have as materialized (
        select k.customer_id, k.channel, k.level, k.first_order_at
        from cma.active_customer k where k.tenant_id = t.id and (k.channel <> 'unknown' or k.first_order_at is not null)
      )
      select format('customers whose channel, level or first order differs from First orders'': %s',
                    (select count(*) from ((select * from have except select * from want) union all (select * from want except select * from have)) d)
                    + case when pg_temp.v0009n_p('A2') then 1 else 0 end),
             format('first orders linked to a store order %s; customers of the take with a first order %s: indirect %s, direct %s; customers of the take %s, of them unknown %s',
                    (select count(*) from fo), (select count(*) from want),
                    (select count(*) from want w where w.channel = 'indirect'), (select count(*) from want w where w.channel = 'direct'),
                    (select count(*) from cma.active_customer k where k.tenant_id = t.id),
                    (select count(*) from cma.active_customer k where k.tenant_id = t.id and k.channel = 'unknown'))
      into v_a2, v_a2i;

      -- A3. the note's date: the take's attribution start is the history start of First orders, as before
      v_a3 := format('the note''s date is First orders'' history start: %s',
                     ((select k.attribution_start from cma.active_take k where k.tenant_id = t.id)
                      is not distinct from (select h.history_start from cma.first_orders_history_start_of(t.id) h))::text);

      -- T1. the present as the take holds it against the live present at the take's moment, and against Flash's
      perform set_config('role', 'cma_app', true);
      j_take := cma.active_now_of(t.id, null, null, null, v_now, true);
      j_live := cma.active_now_of(t.id, null, null, null, v_now, false);
      v_t1 := format('the four tiles from the take equal the live ones at the take''s moment: %s; Active customers equal Flash''s: %s',
                     ((j_take -> 'tiles') = (j_live -> 'tiles'))::text,
                     ((j_take #>> '{tiles,active_customers,value}')::bigint
                      = (select count(*) from cma.flash_customer_figures_of(t.id) f where coalesce(f.holding_subscriptions, 0) > 0))::text);

      -- T2. a reader, the setting at take and at live
      if v_user is not null then
        perform set_config('role', 'cma_owner', true);
        insert into cma.tenant_setting (tenant_id, key, value) values (t.id, 'active.present_source', 'take')
        on conflict (tenant_id, key) do update set value = excluded.value;
        perform set_config('role', 'cma_app', true);
        perform set_config('app.user_id', v_user::text, true);
        j := cma.active_now();
        v_t2 := format('at take: source %s, of the take''s moment %s, tiles %s', j ->> 'source', ((j ->> 'computed_at')::timestamptz = v_now)::text,
                       case when jsonb_typeof(j -> 'tiles') = 'object' then 'yes' else 'no' end);
        perform set_config('role', 'cma_owner', true);
        update cma.tenant_setting s set value = 'live' where s.tenant_id = t.id and s.key = 'active.present_source';
        perform set_config('role', 'cma_app', true);
        j := cma.active_now();
        v_t2 := v_t2 || format(' | at live: source %s, tiles %s', j ->> 'source', case when jsonb_typeof(j -> 'tiles') = 'object' then 'yes' else 'no' end);
        perform set_config('app.user_id', '', true);
      end if;

      -- E2. the tiles' present, both paths: the best of three after six calls
      for i in 1 .. 9 loop
        v_t0 := clock_timestamp();
        j := cma.active_now_of(t.id, null, null, null, v_now, true);
        v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
        if i > 6 then v_take_ms := least(coalesce(v_take_ms, v_ms), v_ms); end if;
      end loop;
      for i in 1 .. 9 loop
        v_t0 := clock_timestamp();
        j := cma.active_now_of(t.id, null, null, null, now(), false);
        v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
        if i > 6 then v_live_ms := least(coalesce(v_live_ms, v_ms), v_ms); end if;
      end loop;
      raise exception using errcode = 'CMAOK', message = 'rollback';
    exception
      when sqlstate 'CMAOK' then null;
      when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
    end;
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.user_id', '', true);
    if v_err is not null then
      insert into pg_temp.verify_0009n values (100, 'A1 to E2 ' || t.slug || ': the checks ran to their end', 'FAIL', v_err);
      continue;
    end if;
    perform pg_temp.v0009n_row(20, 'A1', t.slug || ': the base of 176 equals 172''s base read from the first order deal on, row for row', v_a1,
      format('rows differing 0; rows %s', case when exists (select 1 from cma.subscription s where s.tenant_id = t.id and s.source_deleted_at is null) then 'some' else 'none' end));
    perform pg_temp.v0009n_row(21, 'A2', t.slug || ': every customer''s acquisition channel is Sales → First orders'' attribution of its first order, row for row', v_a2,
      'customers whose channel, level or first order differs from First orders'': 0');
    insert into pg_temp.verify_0009n values (22, 'A2 counts ' || t.slug, case when current_setting('verify.provoke') = 'true' then 'FAIL' else 'info' end, v_a2i);
    perform pg_temp.v0009n_row(23, 'A3', t.slug || ': the note''s date stays First orders'' history start', v_a3, 'the note''s date is First orders'' history start: true');
    perform pg_temp.v0009n_row(30, 'T1', t.slug || ': the present from the take equals the live present at the take''s moment, and Flash''s Active customers (D2)', v_t1,
      'the four tiles from the take equal the live ones at the take''s moment: true; Active customers equal Flash''s: true');
    if v_user is null then
      insert into pg_temp.verify_0009n values (31, 'T2 ' || t.slug || ': a reader and the setting', case when pg_temp.v0009n_p('T2') then 'FAIL' else 'skip' end,
        'no active person holds reports.view or performance.team');
    else
      perform pg_temp.v0009n_row(31, 'T2', t.slug || ': for a reader the setting chooses the path and the answer says which, with its moment', v_t2,
        'at take: source take, of the take''s moment true, tiles yes | at live: source live, tiles yes');
    end if;
    insert into pg_temp.verify_0009n values (40, 'E1 ' || t.slug || ': the forced refresh, the attribution over every order deal, within its budget',
      case when v_refresh <= case when pg_temp.v0009n_p('E1') then 0 else current_setting('verify.max_refresh_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms against %s ms', v_refresh, case when pg_temp.v0009n_p('E1') then '0' else current_setting('verify.max_refresh_ms') end));
    insert into pg_temp.verify_0009n values (41, 'E2 ' || t.slug || ': the tiles'' present from the take within the above-the-fold budget',
      case when v_take_ms <= case when pg_temp.v0009n_p('E2') then 0 else current_setting('verify.max_top_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('from the take %s ms, live %s ms (each the best of 3, after six calls) against %s ms', v_take_ms, v_live_ms,
             case when pg_temp.v0009n_p('E2') then '0' else current_setting('verify.max_top_ms') end));
  end loop;
  if not v_any then
    insert into pg_temp.verify_0009n values (20, 'A1 to E2 the attribution and the present per tenant',
      case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end, 'no active tenant with a subscription has its sources set up');
  end if;
end
$$;

drop function if exists pg_temp.v0009n_base_172(uuid, timestamptz, boolean, date, boolean);
drop function if exists pg_temp.v0009n_code(text);
drop function if exists pg_temp.v0009n_row(integer, text, text, text, text);
drop function if exists pg_temp.v0009n_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009n
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009n where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009n where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('177_verify_active_attribution_present: %s PASS, %s FAIL, %s info, %s skip', (select count(*) from pg_temp.verify_0009n where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009n where result = 'FAIL'), (select count(*) from pg_temp.verify_0009n where result = 'info'),
                    (select count(*) from pg_temp.verify_0009n where result = 'skip'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0009n;
reset role;
