-- =============================================================================================
-- 175_verify_active_refresh_quiet.sql: verifies addition 0009m, Customers → Active's refresh after its first prod runs
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. It works on the tenants the database holds (every active
-- tenant with a subscription whose sources are set up), each inside a step that is always rolled back: the tenant's
-- take, its settings and its rows are left as they were. It keeps 172's two definitions that 174 re-creates
-- (cma.active_refresh_of and cma.active_present_of, verbatim, as pg_temp functions) and compares them with 174's on the
-- same rows at the same moment, as 133 compares a rewritten read with its previous definition. Run as your own IAM
-- login, after 174. Output: tenant slugs, counts and milliseconds only.
-- While it runs: a tenant's step computes the take about twelve times (in prod about a minute) and holds, until it
-- rolls back, the take's row (a settings save that marks the take stale waits), one subscription's row and one store
-- customer's row (an ingest write of that subscription or that customer waits), the intake.start_date setting's row,
-- the tenant's refresh lock (the job answers running) and the analyze's lock on the take's six tables (another
-- analyze or a vacuum of them waits; no reader or writer does). Run it outside the busy hours.
-- Rows written by an ingest while a step runs: the two refreshes R1 compares, and the quiet runs of Q1 and E2, each
-- read the tables as they are at their own moment. The step reads the inputs' markers at its start and after the last
-- run that must be quiet; where they moved, R1, Q1 and E2 read skip ("the inputs moved during the check: run again").
-- What the markers do not hold (a CRM deal, call or association arriving between two compared refreshes) can still
-- read R1 or Q1 FAIL: run again.
-- A take is due after the tenant's customers.refresh_minutes; the step ages the take by that plus a minute. Where the
-- later moment of Q1 falls on the next business date (the last minutes before the tenant's midnight) that part is not
-- compared and an info row says so.
--
-- Checks
--   S1  the addition is recorded after 0009l; cma.active_take.inputs_key exists; the two new functions are the
--       application's alone, cma.active_take_analyze SECURITY DEFINER, owned by cma_owner, search path pinned, and
--       refused without a tenant (CMA04); the two re-created functions keep JIT off
--   P1  per tenant: the live present of 174 equals 172's row for row (both ways), and holds at least one row where
--       the tenant holds a subscription in a device-holding status
--   R1  per tenant: a forced refresh of 174 writes the same take as 172's forced refresh at the same moment: the six
--       take tables row for row and the take's own row (but its duration and inputs_key), each refresh in a step of its
--       own, rolled back
--   Q1  per tenant: the quiet run: a take older than the refresh's interval with nothing changed answers unchanged with every count 0,
--       moves the take's moment and writes no other row; past the refresh's interval by the clock, a quiet run leaves
--       the six tables and the take's row as 172's own due run writes them at that moment (in a step of its own; not
--       172's forced refresh, which also writes the history again: the cohorts' ages move with the clock, and within
--       a business date neither 172's due run nor the quiet run writes them again); a
--       subscription written since, a customer whose row or whose link to a contact changed, a setting saved since
--       (the take marked stale), a new business date and a take of 0009l (no inputs_key) each compute again; a
--       customer delivered again unchanged (only its write time moves) stays quiet
--   A1  per tenant: after a refresh the planner's row counts of the take's six tables are within the bound
--       cma.active_take_analyze keeps (a fifth of the planner's count, or 50 rows), no table with rows is without
--       statistics, and a second call analyzes nothing
--   W1  per tenant: the attribution's window opened inside the step (intake.start_date moved back so the history
--       starts in the past): customers get a known acquisition channel. skip where the tenant has no order deal whose
--       store order belongs to a customer of the take (nothing to attribute); the detail says, for the tenant as it is
--       configured, when its history starts and how many days that lies ahead
--   E1  per tenant, timed: the forced refresh within verify.max_refresh_ms (15,000), run after 174's refresh computed
--       at least eight times on this connection, six of them with the history, so every statement of it is at its
--       seventh execution or later: the generic plan a pooled connection keeps is the one timed (CLAUDE.md,
--       Performance). With one tenant these plans were made for the same sizes; the small-then-large case is 173's E4
--   E2  per tenant, timed: the quiet run within verify.max_quiet_ms (1,000), the best of three
--   E3  per tenant, timed: the live present of the tiles (cma.active_now_of) within verify.max_top_ms (400), the best
--       of three after six calls
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id
-- (S1, P1, R1, Q1, A1, W1, E1, E2, E3): that check alone compares with a deliberate difference.
-- Since addition 0009n (176_active_attribution_present.sql; edited by that change): Active attributes every order deal,
-- so W1 no longer shows that opening the window is what gives customers a channel (177's A2 proves the channels against
-- First orders' rows); W1 still passes, and its detail says so where 0009n is recorded.
-- Since addition 0009r (184_active_device_bands.sql; edited by that change): where 0009r is recorded, the comparisons
-- with 172's refresh (R1, and Q1's later moment) leave out the customers' devices and the stored documents: the page's
-- Devices are another term from then on, which 185_verify_active_device_bands.sql compares with 174's refresh.
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
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'R1'
select set_config('verify.max_refresh_ms', '15000', false);          -- the refresh, everything written again (173's E4, 131's row)
select set_config('verify.max_quiet_ms', '1000', false);             -- a due run with nothing changed
select set_config('verify.max_top_ms', '400', false);                -- the live present of the tiles (decision D15, 173's E5)

drop table if exists pg_temp.verify_0009m;
create temporary table verify_0009m (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009m to cma_app;

create or replace function pg_temp.v0009m_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0009m_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009m_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009m values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 400)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 1500) end);
end
$$;

-- A take table's rows of a tenant as one digest: each row as jsonb without the columns named, the rows' digests in "C" order
create or replace function pg_temp.v0009m_digest(p_table text, p_tenant uuid, p_without text[])
returns text
language plpgsql
as $$
declare
  v text;
begin
  execute format($q$select count(*)::text || ':' || md5(coalesce(string_agg(md5((to_jsonb(x) - %L::text[])::text), '' order by md5((to_jsonb(x) - %L::text[])::text) collate "C"), ''))
                    from cma.%I x where x.tenant_id = %L$q$, p_without, p_without, p_table, p_tenant)
  into v;
  return v;
end
$$;

-- 172's definitions of the two functions 174 re-creates, verbatim (133's pattern: the previous definition kept here)

create or replace function pg_temp.v0009m_present_172(p_tenant_id uuid)
returns table (subscription_id uuid, status text, is_paying boolean, currency text, monthly_amount numeric, customer_id uuid,
               is_active boolean, market text, segment text)
language sql stable
rows 10000
as $$
  with s as materialized (
    select cma.flash_holding_statuses_of(p_tenant_id) as holding, cma.flash_active_statuses_of(p_tenant_id) as paying
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  ), s0 as materialized (
    select x.id, x.connection_id, x.customer_source_id, x.status, x.currency,
           x.amount_per_cycle * cma.active_month_factor_of(x.billing_interval, x.billing_interval_count) as monthly_amount,
           x.status = any ((select s.paying from s)::text[]) as is_paying
    from cma.subscription x
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.status = any ((select s.holding from s)::text[])
  ), cust as materialized (
    -- the store customers of these subscriptions
    select distinct c.id
    from s0 x
    join sm on sm.connection_id = x.connection_id
    join cma.commerce_customer c
      on c.tenant_id = p_tenant_id and c.connection_id = sm.store_connection_id and c.source_id = x.customer_source_id
     and c.source_deleted_at is null
  ), fig as materialized (
    -- Flash's own figures of these customers (D2), read through the customers' primary key: the function is inlined and
    -- the ids reach its scan of the store's customers (as cma.active_base_of reads it)
    select f.customer_id, f.connection_id, f.source_id, f.segment, f.holding_subscriptions
    from cma.flash_customer_figures_of(p_tenant_id) f
    where f.customer_id = any (array(select cust.id from cust))
  )
  select x.id, x.status, x.is_paying, x.currency, x.monthly_amount, f.customer_id, coalesce(f.holding_subscriptions, 0) > 0,
         coalesce(sm.market, 'unknown'), coalesce(f.segment, 'unknown')
  from s0 x
  left join sm on sm.connection_id = x.connection_id
  left join fig f on f.connection_id = sm.store_connection_id and f.source_id = x.customer_source_id
$$;

create or replace function pg_temp.v0009m_refresh_172(p_tenant_id uuid, p_force boolean default false, p_now timestamptz default null)
returns jsonb
language plpgsql
as $$
declare
  v_now    timestamptz := coalesce(p_now, clock_timestamp());
  v_t0     timestamptz := clock_timestamp();
  v_zone   text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_today  date;
  v_month  date;
  v_prev   date;
  v_year   date;
  v_ages   integer[];
  v_segments text[];
  v_every  integer := cma.setting_of(p_tenant_id, 'customers.refresh_minutes')::integer;
  v_set_up boolean;
  v_attr   date;
  v_take   cma.active_take;
  v_found  boolean;
  v_all    boolean;
  v_key    text;
  n_base   integer := 0;
  n_gone   integer := 0;
  n_cust   integer := 0;
  n_hist   integer := 0;
  n_docs   integer := 0;
  v_churn  jsonb;
  n_subs   integer;
  n_active integer;
begin
  if p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a take is refreshed for the current tenant only' using errcode = 'CMA04';
  end if;
  select * into v_take from cma.active_take t where t.tenant_id = p_tenant_id;
  v_found := found;
  -- a statement, not an expression (as the reads' heads): its plan is made again when the role changes
  select coalesce(cma.flash_source_set_up_of(p_tenant_id, 'commerce'), false) and coalesce(cma.flash_source_set_up_of(p_tenant_id, 'subscriptions'), false)
  into v_set_up;
  if not v_set_up then
    -- nothing to take: a tenant whose sources are not set up holds no rows (the page says Not set up, never zeros).
    -- Under the refresh's lock, so a refresh running beside it cannot leave rows without a take
    if v_found then
      if not pg_try_advisory_xact_lock(cma.active_take_lock_key(p_tenant_id)) then
        return jsonb_build_object('refreshed', false, 'reason', 'running');
      end if;
      delete from cma.active_document x where x.tenant_id = p_tenant_id;
      delete from cma.active_cohort x where x.tenant_id = p_tenant_id;
      delete from cma.active_month x where x.tenant_id = p_tenant_id;
      delete from cma.active_spell x where x.tenant_id = p_tenant_id;
      delete from cma.active_customer x where x.tenant_id = p_tenant_id;
      delete from cma.active_base x where x.tenant_id = p_tenant_id;
      delete from cma.active_take x where x.tenant_id = p_tenant_id;
    end if;
    return jsonb_build_object('refreshed', false, 'reason', 'not_set_up');
  end if;
  if not p_force and v_found and not v_take.stale and v_now - v_take.computed_at < make_interval(mins => v_every) then
    return jsonb_build_object('refreshed', false, 'reason', 'fresh');
  end if;
  if not pg_try_advisory_xact_lock(cma.active_take_lock_key(p_tenant_id)) then
    return jsonb_build_object('refreshed', false, 'reason', 'running');
  end if;
  -- under the lock: the take as it is now (a refresh that committed meanwhile is seen), and after it the settings the
  -- stored rows follow, so every mark counted in this take's row is of a setting read below
  select * into v_take from cma.active_take t where t.tenant_id = p_tenant_id;
  v_found := found;
  v_ages := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'customers.cohort_ages_months'));
  v_segments := cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments'));
  v_today := (v_now at time zone v_zone)::date;
  v_month := date_trunc('month', v_today)::date;
  v_prev := (v_month - interval '1 month')::date;
  v_year := (v_month - interval '13 months')::date;
  v_attr := (select h.history_start from cma.first_orders_history_start_of(p_tenant_id) h);
  -- everything is written again when asked, on a first take, after a settings change and on a new business date
  v_all := p_force or not v_found or v_take.stale or v_take.business_date is distinct from v_today;

  -- 1. the base, row by row: a row that reads the same is not written again; a subscription no longer in it goes
  with n as materialized (
    select * from cma.active_base_of(p_tenant_id, v_now, true, v_attr, true)
  ), chg as materialized (
    -- only the rows that read differently from the stored ones reach the upsert: an upsert locks the row it meets
    -- before it compares, so a quiet refresh would lock and dirty every row it leaves as it is
    select n.subscription_id, n.connection_id, n.source_id, n.store, n.market, n.status, n.is_holding, n.is_paying,
           n.payment_state, n.currency, n.monthly_amount, n.billing, n.devices_in_field, n.started_at, n.ended_at,
           n.in_history, n.left_out, n.customer_id, n.customer_connection_id, n.customer_source_id, n.segment,
           n.crm_connection_id, n.contact_source_id, n.customer_start, n.customer_holding, n.customer_devices, n.clv,
           n.clv_currency, n.channel, n.level, n.unknown_reason, n.first_order_at, n.device_models
    from n
    except
    select a.subscription_id, a.connection_id, a.source_id, a.store, a.market, a.status, a.is_holding, a.is_paying,
           a.payment_state, a.currency, a.monthly_amount, a.billing, a.devices_in_field, a.started_at, a.ended_at,
           a.in_history, a.left_out, a.customer_id, a.customer_connection_id, a.customer_source_id, a.segment,
           a.crm_connection_id, a.contact_source_id, a.customer_start, a.customer_holding, a.customer_devices, a.clv,
           a.clv_currency, a.channel, a.level, a.unknown_reason, a.first_order_at, a.device_models
    from cma.active_base a where a.tenant_id = p_tenant_id
  ), up as (
    insert into cma.active_base as a (tenant_id, subscription_id, connection_id, source_id, store, market, status, is_holding, is_paying,
           payment_state, currency, monthly_amount, billing, devices_in_field, started_at, ended_at,
           in_history, left_out, customer_id, customer_connection_id, customer_source_id, segment,
           crm_connection_id, contact_source_id, customer_start, customer_holding, customer_devices, clv,
           clv_currency, channel, level, unknown_reason, first_order_at, device_models)
    select p_tenant_id, n.* from chg n
    on conflict (tenant_id, subscription_id) do update
      set (connection_id, source_id, store, market, status, is_holding, is_paying, payment_state, currency,
           monthly_amount, billing, devices_in_field, started_at, ended_at, in_history, left_out, customer_id,
           customer_connection_id, customer_source_id, segment, crm_connection_id, contact_source_id, customer_start,
           customer_holding, customer_devices, clv, clv_currency, channel, level, unknown_reason, first_order_at, device_models)
        = (excluded.connection_id, excluded.source_id, excluded.store, excluded.market, excluded.status,
           excluded.is_holding, excluded.is_paying, excluded.payment_state, excluded.currency, excluded.monthly_amount,
           excluded.billing, excluded.devices_in_field, excluded.started_at, excluded.ended_at, excluded.in_history,
           excluded.left_out, excluded.customer_id, excluded.customer_connection_id, excluded.customer_source_id,
           excluded.segment, excluded.crm_connection_id, excluded.contact_source_id, excluded.customer_start,
           excluded.customer_holding, excluded.customer_devices, excluded.clv, excluded.clv_currency, excluded.channel,
           excluded.level, excluded.unknown_reason, excluded.first_order_at, excluded.device_models)
      where (a.*) is distinct from (excluded.*)
    returning 1
  ), gone as (
    delete from cma.active_base a
    where a.tenant_id = p_tenant_id and not exists (select 1 from n where n.subscription_id = a.subscription_id)
    returning 1
  )
  select (select count(*) from up), (select count(*) from gone) into n_base, n_gone;

  -- 2. the customers, row by row, from the base just stored: one row per store customer with the list's columns (a
  --    customer's Monthly recurring amount in its largest currency, the others beside it)
  with b as materialized (
    select * from cma.active_base x where x.tenant_id = p_tenant_id and x.customer_id is not null
  ), amt as (
    select q.customer_id, q.currency, q.amount, row_number() over (partition by q.customer_id order by q.amount desc, q.currency) as rn
    from (select b.customer_id, b.currency, sum(b.monthly_amount) as amount
          from b where b.is_holding and b.is_paying and b.currency is not null and b.monthly_amount is not null group by 1, 2) q
  ), oth as (
    select o.customer_id, jsonb_object_agg(o.currency, round(o.amount, 2)) as j from amt o where o.rn > 1 group by 1
  ), n as materialized (
    select distinct on (b.customer_id) b.customer_id, b.customer_connection_id as connection_id, b.customer_source_id as source_id, b.store,
           b.market, b.segment, b.channel, b.level, b.unknown_reason, b.first_order_at, b.customer_start,
           cma.flash_age_months_of(b.customer_start, v_zone, v_today) as age_months,
           coalesce(b.customer_holding, 0) > 0 as is_active, coalesce(b.customer_holding, 0) as holding, coalesce(b.customer_devices, 0) as devices,
           b.clv, b.clv_currency, b.crm_connection_id, b.contact_source_id, a.currency, a.amount, coalesce(oth.j, '{}'::jsonb) as other_amounts
    from b
    left join amt a on a.customer_id = b.customer_id and a.rn = 1
    left join oth on oth.customer_id = b.customer_id
    order by b.customer_id
  ), chg as materialized (
    select n.customer_id, n.connection_id, n.source_id, n.store, n.market, n.segment, n.channel, n.level, n.unknown_reason,
           n.first_order_at, n.customer_start, n.age_months, n.is_active, n.holding, n.devices, n.clv, n.clv_currency,
           n.crm_connection_id, n.contact_source_id, n.currency, n.amount, n.other_amounts
    from n
    except
    select a.customer_id, a.connection_id, a.source_id, a.store, a.market, a.segment, a.channel, a.level, a.unknown_reason,
           a.first_order_at, a.customer_start, a.age_months, a.is_active, a.holding, a.devices, a.clv, a.clv_currency,
           a.crm_connection_id, a.contact_source_id, a.currency, a.amount, a.other_amounts
    from cma.active_customer a where a.tenant_id = p_tenant_id
  ), up as (
    insert into cma.active_customer as a (tenant_id, customer_id, connection_id, source_id, store, market, segment, channel, level, unknown_reason,
           first_order_at, customer_start, age_months, is_active, holding, devices, clv, clv_currency,
           crm_connection_id, contact_source_id, currency, amount, other_amounts)
    select p_tenant_id, n.* from chg n
    on conflict (tenant_id, customer_id) do update
      set (connection_id, source_id, store, market, segment, channel, level, unknown_reason, first_order_at,
           customer_start, age_months, is_active, holding, devices, clv, clv_currency, crm_connection_id,
           contact_source_id, currency, amount, other_amounts)
        = (excluded.connection_id, excluded.source_id, excluded.store, excluded.market, excluded.segment,
           excluded.channel, excluded.level, excluded.unknown_reason, excluded.first_order_at, excluded.customer_start,
           excluded.age_months, excluded.is_active, excluded.holding, excluded.devices, excluded.clv,
           excluded.clv_currency, excluded.crm_connection_id, excluded.contact_source_id, excluded.currency,
           excluded.amount, excluded.other_amounts)
      where (a.*) is distinct from (excluded.*)
    returning 1
  ), gone as (
    delete from cma.active_customer a
    where a.tenant_id = p_tenant_id and not exists (select 1 from n where n.customer_id = a.customer_id)
    returning 1
  )
  select (select count(*) from up) + (select count(*) from gone) into n_cust;

  -- 3. the history (the spells, the month ends, the cohorts): only when what it is computed from changed. Its key is a
  --    digest of the base's columns it reads, with the zone and the cohort ages
  select md5(coalesce(string_agg(md5(concat_ws('|', x.subscription_id, x.customer_id, x.market, x.segment, x.channel, x.started_at, x.ended_at,
                                           x.in_history, x.customer_start, x.currency, x.monthly_amount, x.is_holding, x.is_paying)),
                                 '' order by x.subscription_id), '') || '|' || v_zone || '|' || array_to_string(v_ages, ','))
  into v_key
  from cma.active_base x where x.tenant_id = p_tenant_id;
  if v_all or v_key is distinct from v_take.history_key then
    delete from cma.active_cohort x where x.tenant_id = p_tenant_id;
    delete from cma.active_month x where x.tenant_id = p_tenant_id;
    delete from cma.active_spell x where x.tenant_id = p_tenant_id;

    insert into cma.active_spell (tenant_id, customer_id, market, segment, channel, customer_start, customer_start_on, spell_start, spell_end, len, ended)
    select p_tenant_id, c.customer_id, c.market, c.segment, c.channel, c.customer_start, (c.customer_start at time zone v_zone)::date, x.spell_start, x.spell_end,
           greatest(0, cma.flash_age_months_of(x.spell_start, v_zone, coalesce((x.spell_end at time zone v_zone)::date, v_today))),
           x.spell_end is not null
    from (select array_agg(b.customer_id::text) as k, array_agg(b.started_at) as s, array_agg(b.ended_at) as e
          from cma.active_base b where b.tenant_id = p_tenant_id and b.customer_id is not null and b.in_history) a
    cross join lateral cma.active_spells_from(a.k, a.s, a.e) x
    join cma.active_customer c on c.tenant_id = p_tenant_id and c.customer_id = x.key::uuid;
    get diagnostics n_hist = row_count;

    -- the customers per month end (from the spells), the subscriptions and the amounts (from the base's intervals)
    insert into cma.active_month (tenant_id, kind, month, market, segment, channel, currency, inflow, outflow, at_end)
    select p_tenant_id, 'customers', x.month, x.d1, x.d2, x.d3, '', x.inflow, x.outflow, x.at_end
    from (select array_agg(sp.market) as a, array_agg(sp.segment) as b, array_agg(sp.channel) as c, array_agg(1::numeric) as w,
                 array_agg(sp.spell_start) as s, array_agg(sp.spell_end) as e
          from cma.active_spell sp where sp.tenant_id = p_tenant_id) a
    cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, v_zone, v_now) x
    union all
    select p_tenant_id, 'subscriptions', x.month, x.d1, x.d2, x.d3, '', x.inflow, x.outflow, x.at_end
    from (select array_agg(b.market) as a, array_agg(b.segment) as b, array_agg(b.channel) as c, array_agg(1::numeric) as w,
                 array_agg(b.started_at) as s, array_agg(b.ended_at) as e
          from cma.active_base b where b.tenant_id = p_tenant_id and b.in_history) a
    cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, v_zone, v_now) x
    union all
    -- the Monthly recurring amount: the subscriptions holding then at their amount today; one that holds today without
    -- paying is left out throughout. The currency rides with the channel through the cube's third dimension
    select p_tenant_id, 'amount', x.month, x.d1, x.d2, split_part(x.d3, '~', 1), split_part(x.d3, '~', 2), x.inflow, x.outflow, x.at_end
    from (select array_agg(b.market) as a, array_agg(b.segment) as b, array_agg(b.channel || '~' || b.currency) as c, array_agg(b.monthly_amount) as w,
                 array_agg(b.started_at) as s, array_agg(b.ended_at) as e
          from cma.active_base b
          where b.tenant_id = p_tenant_id and b.in_history and b.currency is not null and b.monthly_amount is not null
            and (not b.is_holding or b.is_paying)) a
    cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, v_zone, v_now) x
    union all
    -- the customers with a subscription in a currency at the two month ends a change line compares with
    select p_tenant_id, 'currency_customers', q.m, q.market, q.segment, q.channel, q.currency, 0, 0, count(*)
    from (select distinct x.m, b.market, b.segment, b.channel, b.currency, b.customer_id
          from cma.active_base b
          cross join (values (v_prev, v_month::timestamp at time zone v_zone),
                             (v_year, (v_year + interval '1 month')::timestamp at time zone v_zone)) x(m, at)
          where b.tenant_id = p_tenant_id and b.customer_id is not null and b.in_history and b.currency is not null
            and b.started_at < x.at and (b.ended_at is null or b.ended_at >= x.at)) q
    group by q.m, q.market, q.segment, q.channel, q.currency
    union all
    -- Flash's Churn (subscription) over the last 30 business dates (the unit economics' one figure, the markets' column):
    -- a churned subscription under its store's market and the base's segment and channel of it
    select p_tenant_id, 'churned_30d', v_month, x.market, coalesce(b.segment, 'unknown'), coalesce(b.channel, 'unknown'), '', 0, 0, count(*)
    from cma.flash_churn_of(p_tenant_id, v_today - 29, v_today) x
    left join cma.active_base b on b.tenant_id = p_tenant_id and b.subscription_id = x.subscription_id
    group by x.market, coalesce(b.segment, 'unknown'), coalesce(b.channel, 'unknown');

    insert into cma.active_cohort (tenant_id, period, cohort, market, segment, channel, age_months, started, still_active, mature)
    select p_tenant_id, g.period, x.cohort, x.d1, x.d2, x.d3, x.age_months, x.started, x.still_active, x.mature
    from (select array_agg(sp.customer_id::text) as k, array_agg(sp.market) as a, array_agg(sp.segment) as b, array_agg(sp.channel) as c,
                 array_agg(sp.customer_start) as cs, array_agg(sp.spell_start) as s, array_agg(sp.spell_end) as e
          from cma.active_spell sp where sp.tenant_id = p_tenant_id) a
    cross join (values ('month'), ('quarter')) g(period)
    cross join lateral cma.active_cohort_cube_from(a.k, a.a, a.b, a.c, a.cs, a.s, a.e, v_ages, g.period, v_zone, v_now) x;
  else
    -- the history stays as it was last written: its month ends and cohorts are of that moment (no row they are computed
    -- from changed since; a cohort's maturity is of that moment too, at most a business date old). Flash's churn count
    -- reads the subscriptions' events, which the key does not hold: it is written again at every refresh, where it
    -- reads differently
    select coalesce(jsonb_agg(jsonb_build_object('market', q.market, 'segment', q.segment, 'channel', q.channel, 'n', q.n)), '[]'::jsonb)
    into v_churn
    from (select x.market, coalesce(b.segment, 'unknown') as segment, coalesce(b.channel, 'unknown') as channel, count(*) as n
          from cma.flash_churn_of(p_tenant_id, v_today - 29, v_today) x
          left join cma.active_base b on b.tenant_id = p_tenant_id and b.subscription_id = x.subscription_id
          group by 1, 2, 3) q;
    delete from cma.active_month a
    where a.tenant_id = p_tenant_id and a.kind = 'churned_30d'
      and not exists (select 1 from jsonb_to_recordset(v_churn) n(market text, segment text, channel text, n numeric)
                      where a.month = v_month and n.market = a.market and n.segment = a.segment and n.channel = a.channel);
    insert into cma.active_month as a (tenant_id, kind, month, market, segment, channel, currency, inflow, outflow, at_end)
    select p_tenant_id, 'churned_30d', v_month, n.market, n.segment, n.channel, '', 0, 0, n.n
    from jsonb_to_recordset(v_churn) n(market text, segment text, channel text, n numeric)
    where not exists (select 1 from cma.active_month o
                      where o.tenant_id = p_tenant_id and o.kind = 'churned_30d' and o.month = v_month and o.market = n.market
                        and o.segment = n.segment and o.channel = n.channel and o.currency = '' and o.at_end = n.n)
    on conflict (tenant_id, kind, month, market, segment, channel, currency) do update set at_end = excluded.at_end;
  end if;

  select count(*) filter (where b.is_holding), count(distinct b.customer_id) filter (where coalesce(b.customer_holding, 0) > 0)
  into n_subs, n_active
  from cma.active_base b where b.tenant_id = p_tenant_id;
  -- a first take: its row is there before the documents are computed (they ask whether there is a take). An existing
  -- take's row is left alone until the documents are computed, so a settings save that marks the take stale does not
  -- wait for them
  insert into cma.active_take (tenant_id, computed_at, business_date, duration_ms, history_key, customers, subscriptions, attribution_start, stale, stale_since)
  values (p_tenant_id, v_now, v_today, 0, v_key, n_active, n_subs, v_attr, false, null)
  on conflict (tenant_id) do nothing;

  -- 4. the documents (decision D16), from the rows just stored and as of this take: above the fold and below it,
  --    without a filter and under each single market, segment and acquisition channel. Computed at
  --    every refresh (they also read catalogs and the clock's month), written only where one reads differently
  with f(m, s, c) as (
    select null::text, null::text, null::text
    union all
    select q.market, null, null
    from (select st.market from cma.commerce_store st where st.tenant_id = p_tenant_id
          union select x.market from cma.active_customer x where x.tenant_id = p_tenant_id
          union select x.market from cma.active_base x where x.tenant_id = p_tenant_id) q
    where q.market is not null and q.market <> ''
    union all
    select null, x.segment, null from (select distinct u as segment from unnest(v_segments || array['unknown']) u) x where x.segment <> ''
    union all
    select null, null, x.channel from unnest(array['indirect', 'direct', 'unknown']) x(channel)
  ), n as materialized (
    select 'top'::text as part, coalesce(f.m, '') as market, coalesce(f.s, '') as segment, coalesce(f.c, '') as channel,
           cma.active_top_body_of(p_tenant_id, f.m, f.s, f.c, v_now, true) as doc
    from f
    union all
    select 'rest', coalesce(f.m, ''), coalesce(f.s, ''), coalesce(f.c, ''), cma.active_rest_body_of(p_tenant_id, f.m, f.s, f.c, v_now)
    from f
  ), chg as materialized (
    -- only a document that reads differently is written (and its row locked)
    select n.part, n.market, n.segment, n.channel, n.doc from n
    where not exists (select 1 from cma.active_document a
                      where a.tenant_id = p_tenant_id and a.part = n.part and a.market = n.market and a.segment = n.segment and a.channel = n.channel
                        and a.doc = n.doc)
  ), up as (
    insert into cma.active_document as a (tenant_id, part, market, segment, channel, doc)
    select p_tenant_id, n.part, n.market, n.segment, n.channel, n.doc from chg n
    on conflict (tenant_id, part, market, segment, channel) do update set doc = excluded.doc
    returning 1
  ), gone as (
    delete from cma.active_document a
    where a.tenant_id = p_tenant_id
      and not exists (select 1 from n where n.part = a.part and n.market = a.market and n.segment = a.segment and n.channel = a.channel)
    returning 1
  )
  select (select count(*) from up) + (select count(*) from gone) into n_docs;
  -- the take's row, last: its moment, and the mark cleared only when no setting was saved since this refresh read the
  -- take (the row is the one committed now: a settings transaction still open is waited for)
  update cma.active_take t
  set computed_at = v_now, business_date = v_today, duration_ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer,
      history_key = v_key, customers = n_active, subscriptions = n_subs, attribution_start = v_attr,
      stale = t.stale_marks is distinct from coalesce(v_take.stale_marks, 0),
      stale_since = case when t.stale_marks is distinct from coalesce(v_take.stale_marks, 0) then t.stale_since end
  where t.tenant_id = p_tenant_id;

  return jsonb_build_object('refreshed', true, 'base_rows', n_base + n_gone, 'customer_rows', n_cust, 'history_rows', n_hist,
                            'document_rows', n_docs, 'rows', n_base + n_gone + n_cust + n_hist + n_docs,
                            'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- S. The addition, the column, the grants
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_txt text;
  v_null text := 'no error';
begin
  begin
    perform cma.active_take_analyze(null);
  exception
    when others then v_null := sqlstate;
  end;
  select format('versions %s | inputs_key %s | app only: %s | analyze: definer %s, owner %s, %s | jit off: %s',
    (select string_agg(m.version, ',' order by m.version collate "C") from cma.schema_migration m where m.version in ('0009l', '0009m')),
    (select format('%s %s', a.atttypid::regtype, case when a.attnotnull then 'not null' else 'nullable' end)
     from pg_attribute a where a.attrelid = 'cma.active_take'::regclass and a.attname = 'inputs_key' and not a.attisdropped),
    (select string_agg(format('%s %s/%s', p.proname, has_function_privilege('cma_app', p.oid, 'execute'), has_function_privilege('public', p.oid, 'execute')),
                       ', ' order by p.proname collate "C")
     from pg_proc p where p.pronamespace = 'cma'::regnamespace and p.proname in ('active_inputs_key_of', 'active_take_analyze')),
    (select p.prosecdef from pg_proc p where p.oid = 'cma.active_take_analyze(uuid)'::regprocedure),
    (select p.proowner::regrole from pg_proc p where p.oid = 'cma.active_take_analyze(uuid)'::regprocedure),
    (select array_to_string(p.proconfig, ';') from pg_proc p where p.oid = 'cma.active_take_analyze(uuid)'::regprocedure),
    (select string_agg(format('%s %s', p.proname, coalesce(array_to_string(p.proconfig, ';'), 'none')), ', ' order by p.proname collate "C")
     from pg_proc p where p.oid in ('cma.active_refresh_of(uuid,boolean,timestamptz)'::regprocedure, 'cma.active_present_of(uuid)'::regprocedure)))
  into v_txt;
  v_txt := v_txt || ' | analyze without a tenant: ' || v_null;
  perform pg_temp.v0009m_row(1, 'S1', 'the addition is recorded; the column, the grants, the definer''s frame and JIT off are in place', v_txt,
    'versions 0009l,0009m | inputs_key text nullable | app only: active_inputs_key_of t/f, active_take_analyze t/f'
    || ' | analyze: definer t, owner cma_owner, search_path=pg_catalog, cma, pg_temp | jit off: active_present_of jit=off, active_refresh_of jit=off'
    || ' | analyze without a tenant: CMA04');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- P, R, Q, A, W, E. Per tenant, inside a step that is always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t record;
  v_now timestamptz := now();
  v_today date; v_zone text;
  v_tables text[] := array['active_base', 'active_customer', 'active_spell', 'active_month', 'active_cohort', 'active_document'];
  v_any boolean := false;
  v_err text;
  n_new bigint; n_diff bigint;
  d_old text; d_new text; d_q text;
  j jsonb; j2 jsonb;
  v_t0 timestamptz; v_ms numeric;
  v_quiet numeric; v_forced numeric; v_live numeric;
  v_q text; v_a text; v_w text; v_wres text;
  v_attr date; v_win integer; v_known bigint; v_first bigint; v_calls integer;
  v_sub uuid; v_cust uuid; v_link uuid;
  v_k0 text; v_k1 text; v_moved boolean;
  v_comp integer; v_hist integer;
  d_later text; d_later_172 text;
  v_due interval; v_mid boolean;
  -- since addition 0009r (184): the customers' devices are another term than 172's refresh writes, so the comparisons
  -- with 172's refresh leave out that column and the documents that state it (185 compares those)
  v_0009r boolean := exists (select 1 from cma.schema_migration m where m.version = '0009r');
  v_wo text[] := case when v_0009r then array['devices'] else '{}'::text[] end;
  v_cmp text[] := case when v_0009r then array['active_base', 'active_customer', 'active_spell', 'active_month', 'active_cohort'] else v_tables end;
begin
  for t in select x.id, x.slug from cma.tenant x
           where x.status = 'active' and exists (select 1 from cma.subscription s where s.tenant_id = x.id) order by x.slug collate "C" loop
    if not (coalesce(cma.flash_source_set_up_of(t.id, 'commerce'), false) and coalesce(cma.flash_source_set_up_of(t.id, 'subscriptions'), false)) then
      continue;
    end if;
    v_any := true;
    v_err := null; n_new := null; n_diff := null; d_old := null; d_new := null; v_q := null; v_a := null; v_w := null; v_wres := null;
    v_quiet := null; v_forced := null; v_live := null; v_calls := 0; v_k0 := null; v_k1 := null; v_comp := 0; v_hist := 0;
    d_later := null; d_later_172 := null;
    v_zone := (select x.timezone from cma.tenant x where x.id = t.id);
    v_today := (v_now at time zone v_zone)::date;
    -- a take is due after customers.refresh_minutes (1 to 1440): aged here by that plus a minute
    v_due := make_interval(mins => coalesce(nullif(cma.setting_of(t.id, 'customers.refresh_minutes'), '')::integer, 5) + 1);
    v_mid := ((v_now + v_due) at time zone v_zone)::date is distinct from v_today;
    begin
      perform set_config('app.tenant_id', t.id::text, true);
      perform set_config('role', 'cma_app', true);

      v_k0 := cma.active_inputs_key_of(t.id);

      -- P1. the live present: 174's rows against 172's, both ways
      select (select count(*) from cma.active_present_of(t.id)),
             (select count(*) from ((select * from cma.active_present_of(t.id) except all select * from pg_temp.v0009m_present_172(t.id))
                                    union all
                                    (select * from pg_temp.v0009m_present_172(t.id) except all select * from cma.active_present_of(t.id))) q)
      into n_new, n_diff;

      -- R1. the take as 172's refresh writes it, in a step of its own
      begin
        perform pg_temp.v0009m_refresh_172(t.id, true, v_now);
        perform set_config('role', 'cma_owner', true);
        d_old := (select string_agg(x || ' ' || pg_temp.v0009m_digest(x, t.id, case when x = 'active_customer' then v_wo else '{}'::text[] end), ' | ' order by o) from unnest(v_cmp) with ordinality u(x, o))
                 || ' | take ' || pg_temp.v0009m_digest('active_take', t.id, array['duration_ms', 'inputs_key']);
        raise exception using errcode = 'CMAOK', message = 'rollback';
      exception
        when sqlstate 'CMAOK' then null;
      end;
      perform set_config('role', 'cma_app', true);
      -- and as 174's writes it, at the same moment; the checks after it read this take
      j := cma.active_refresh_of(t.id, true, v_now);
      v_calls := v_calls + 1; v_comp := v_comp + 1; v_hist := v_hist + 1;
      perform set_config('role', 'cma_owner', true);
      d_new := (select string_agg(x || ' ' || pg_temp.v0009m_digest(x, t.id, case when x = 'active_customer' then v_wo else '{}'::text[] end), ' | ' order by o) from unnest(v_cmp) with ordinality u(x, o))
               || ' | take ' || pg_temp.v0009m_digest('active_take', t.id, array['duration_ms', 'inputs_key']);

      -- A1. the planner's row counts follow the fill; a second call finds nothing to analyze
      select format('tables whose planner count is off by more than a fifth: %s; tables with rows and no statistics: %s',
                    count(*) filter (where abs(q.planner - q.n) > greatest(50, 0.2 * q.planner)),
                    count(*) filter (where q.n > 0 and (q.reltuples < 0 or not q.has_stats)))
      from (select greatest(c.reltuples, 0)::numeric as planner, c.reltuples,
                   (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from cma.%I', x), false, true, '')))[1]::text::numeric as n,
                   exists (select 1 from pg_stats st where st.schemaname = 'cma' and st.tablename = x) as has_stats
            from unnest(v_tables) x join pg_class c on c.oid = ('cma.' || x)::regclass) q
      into v_a;
      perform set_config('role', 'cma_app', true);
      v_a := v_a || format('; a second call analyzes %s; the first refresh reported tables_analyzed %s',
                           cma.active_take_analyze(t.id), case when (j ->> 'tables_analyzed') ~ '^[0-9]+$' then 'a number' else coalesce(j ->> 'tables_analyzed', 'nothing') end);

      -- Q1. the quiet run
      perform set_config('role', 'cma_owner', true);
      update cma.active_take k set computed_at = v_now - v_due where k.tenant_id = t.id;
      d_q := (select string_agg(pg_temp.v0009m_digest(x, t.id, '{}'), ' ' order by o) from unnest(v_tables) with ordinality u(x, o));
      perform set_config('role', 'cma_app', true);
      j2 := cma.active_refresh_of(t.id, false, v_now);
      v_calls := v_calls + 1;
      perform set_config('role', 'cma_owner', true);
      v_q := format('nothing changed: refreshed %s unchanged %s rows %s, the take''s moment moved %s, the six tables as they were %s',
                    j2 ->> 'refreshed', j2 ->> 'unchanged', j2 ->> 'rows',
                    ((select k.computed_at from cma.active_take k where k.tenant_id = t.id) = v_now)::text,
                    (d_q = (select string_agg(pg_temp.v0009m_digest(x, t.id, '{}'), ' ' order by o) from unnest(v_tables) with ordinality u(x, o)))::text);
      -- timed: the best of three quiet runs
      for i in 1 .. 3 loop
        update cma.active_take k set computed_at = v_now - v_due where k.tenant_id = t.id;
        perform set_config('role', 'cma_app', true);
        v_t0 := clock_timestamp();
        j2 := cma.active_refresh_of(t.id, false, v_now);
        v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
        v_calls := v_calls + 1;
        perform set_config('role', 'cma_owner', true);
        if coalesce((j2 ->> 'unchanged')::boolean, false) then v_quiet := least(coalesce(v_quiet, v_ms), v_ms); end if;
      end loop;
      -- past the refresh's interval by the clock: a quiet run, then what 172's own due run writes at that moment
      -- (rolled back); not on the next business date, where a refresh computes by its rule
      if not v_mid then
      perform set_config('role', 'cma_app', true);
      j2 := cma.active_refresh_of(t.id, false, v_now + v_due);
      v_calls := v_calls + 1;
      perform set_config('role', 'cma_owner', true);
      d_later := format('unchanged %s | ', j2 ->> 'unchanged')
                 || (select string_agg(x || ' ' || pg_temp.v0009m_digest(x, t.id, case when x = 'active_customer' then v_wo else '{}'::text[] end), ' | ' order by o) from unnest(v_cmp) with ordinality u(x, o))
                 || ' | take ' || pg_temp.v0009m_digest('active_take', t.id, array['duration_ms', 'inputs_key']);
      begin
        -- 172's own due run at that moment: the take aged again, not forced (a forced refresh also writes the history
        -- again, whose cohort ages move with the clock; neither 172's due run nor the quiet run does within a business date)
        update cma.active_take k set computed_at = v_now where k.tenant_id = t.id;
        perform set_config('role', 'cma_app', true);
        j2 := pg_temp.v0009m_refresh_172(t.id, false, v_now + v_due);
        perform set_config('role', 'cma_owner', true);
        d_later_172 := case when (j2 ->> 'refreshed')::boolean and j2 ->> 'reason' is null then 'unchanged true | ' else 'the run of 172 did not compute: ' || j2::text || ' | ' end
                 || (select string_agg(x || ' ' || pg_temp.v0009m_digest(x, t.id, case when x = 'active_customer' then v_wo else '{}'::text[] end), ' | ' order by o) from unnest(v_cmp) with ordinality u(x, o))
                 || ' | take ' || pg_temp.v0009m_digest('active_take', t.id, array['duration_ms', 'inputs_key']);
        raise exception using errcode = 'CMAOK', message = 'rollback';
      exception
        when sqlstate 'CMAOK' then null;
      end;
      perform set_config('role', 'cma_owner', true);
      end if;
      v_q := v_q || format(' | past the refresh''s interval, a quiet run leaves what 172''s due run writes then: %s',
                           case when v_mid then 'true' else (d_later = d_later_172)::text end);
      -- a customer delivered again unchanged: only its write time moves, the run stays quiet
      select c.id into v_cust from cma.commerce_customer c where c.tenant_id = t.id order by c.id limit 1;
      update cma.commerce_customer c set synced_at = clock_timestamp() + interval '1 second' where c.tenant_id = t.id and c.id = v_cust;
      update cma.active_take k set computed_at = v_now - v_due where k.tenant_id = t.id;
      perform set_config('role', 'cma_app', true);
      j2 := cma.active_refresh_of(t.id, false, v_now);
      v_calls := v_calls + 1;
      v_q := v_q || format(' | a customer delivered again unchanged: unchanged %s', coalesce(j2 ->> 'unchanged', case when v_cust is null then 'true' end));
      -- the inputs' markers again, after the last run that must be quiet (the step's own write above moved a write time
      -- only, which the customers' marker leaves out): an ingest that wrote meanwhile makes R1, Q1 and E2 a skip
      v_k1 := cma.active_inputs_key_of(t.id);
      -- a customer whose link to a contact changed (written without a write time, 58). A customer that holds a link:
      -- the link's three columns are set together (commerce_customer_crm_link_check), so the moment of a customer
      -- without one cannot be moved (prod's first run of this script, 12 November 2026, stopped there)
      perform set_config('role', 'cma_owner', true);
      select c.id into v_link from cma.commerce_customer c where c.tenant_id = t.id and c.matched_at is not null order by c.id limit 1;
      update cma.commerce_customer c set matched_at = c.matched_at + interval '1 second' where c.tenant_id = t.id and c.id = v_link;
      update cma.active_take k set computed_at = v_now - v_due where k.tenant_id = t.id;
      perform set_config('role', 'cma_app', true);
      j2 := cma.active_refresh_of(t.id, false, v_now);
      v_calls := v_calls + 1; v_comp := v_comp + case when v_link is null then 0 else 1 end;
      v_q := v_q || format(' | a customer''s link changed: unchanged %s', case when v_link is null then 'false' else j2 ->> 'unchanged' end);
      -- a subscription written since
      perform set_config('role', 'cma_owner', true);
      select s.id into v_sub from cma.subscription s where s.tenant_id = t.id order by s.id limit 1;
      update cma.subscription s set synced_at = clock_timestamp() + interval '1 second' where s.tenant_id = t.id and s.id = v_sub;
      update cma.active_take k set computed_at = v_now - v_due where k.tenant_id = t.id;
      perform set_config('role', 'cma_app', true);
      j2 := cma.active_refresh_of(t.id, false, v_now);
      v_calls := v_calls + 1; v_comp := v_comp + 1;
      v_q := v_q || format(' | a subscription written since: unchanged %s', j2 ->> 'unchanged');
      -- a setting saved since: the take is marked stale
      perform set_config('role', 'cma_owner', true);
      update cma.active_take k set computed_at = v_now - v_due, stale = true, stale_since = v_now where k.tenant_id = t.id;
      perform set_config('role', 'cma_app', true);
      j2 := cma.active_refresh_of(t.id, false, v_now);
      v_calls := v_calls + 1; v_comp := v_comp + 1; v_hist := v_hist + 1;
      v_q := v_q || format(' | a stale take: unchanged %s', j2 ->> 'unchanged');
      -- a new business date
      perform set_config('role', 'cma_owner', true);
      update cma.active_take k set computed_at = v_now - v_due, business_date = k.business_date - 1 where k.tenant_id = t.id;
      perform set_config('role', 'cma_app', true);
      j2 := cma.active_refresh_of(t.id, false, v_now);
      v_calls := v_calls + 1; v_comp := v_comp + 1; v_hist := v_hist + 1;
      v_q := v_q || format(' | a new business date: unchanged %s', j2 ->> 'unchanged');
      -- a take of 0009l: no inputs_key yet
      perform set_config('role', 'cma_owner', true);
      update cma.active_take k set computed_at = v_now - v_due, inputs_key = null where k.tenant_id = t.id;
      perform set_config('role', 'cma_app', true);
      j2 := cma.active_refresh_of(t.id, false, v_now);
      v_calls := v_calls + 1; v_comp := v_comp + 1;
      v_q := v_q || format(' | a take without inputs_key: unchanged %s, then it holds one %s', j2 ->> 'unchanged',
                           ((select k.inputs_key from cma.active_take k where k.tenant_id = t.id) is not null)::text);

      -- E1. the forced refresh, timed at the seventh execution or later of every statement of the refresh on this
      --     connection: forced refreshes until it computed eight times, six of them with the history
      while v_comp < 8 or v_hist < 6 loop
        j2 := cma.active_refresh_of(t.id, true, v_now);
        v_calls := v_calls + 1; v_comp := v_comp + 1; v_hist := v_hist + 1;
      end loop;
      v_t0 := clock_timestamp();
      j2 := cma.active_refresh_of(t.id, true, v_now);
      v_forced := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
      v_calls := v_calls + 1;

      -- E3. the live present of the tiles, the best of three after six calls
      for i in 1 .. 9 loop
        v_t0 := clock_timestamp();
        j2 := cma.active_now_of(t.id, null, null, null, now(), false);
        v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
        if i > 6 then v_live := least(coalesce(v_live, v_ms), v_ms); end if;
      end loop;

      -- W1. the attribution's window: as configured, then opened inside this step
      perform set_config('role', 'cma_owner', true);
      v_attr := (select h.history_start from cma.first_orders_history_start_of(t.id) h);
      v_win := cma.setting_of(t.id, 'attribution.window_days')::integer;
      v_w := format('as configured: intake.start_date %s + attribution.window_days %s, the history starts %s (%s)',
                    cma.setting_of(t.id, 'intake.start_date'), v_win, coalesce(v_attr::text, 'never: no order deal'),
                    case when v_attr is null then 'nothing to attribute'
                         when v_attr > v_today and exists (select 1 from cma.schema_migration m where m.version = '0009n')
                         then format('%s days ahead: since 0009n the customers are attributed all the same, and the date is the note''s', v_attr - v_today)
                         when v_attr > v_today then format('%s days ahead: every customer is Unknown until then', v_attr - v_today)
                         else format('%s days of history', v_today - v_attr) end);
      insert into cma.tenant_setting (tenant_id, key, value) values (t.id, 'intake.start_date', (v_today - v_win - 400)::text)
      on conflict (tenant_id, key) do update set value = excluded.value;
      v_attr := (select h.history_start from cma.first_orders_history_start_of(t.id) h);
      perform set_config('role', 'cma_app', true);
      j2 := cma.active_refresh_of(t.id, true, v_now);
      select count(*) into v_known from cma.active_customer c where c.tenant_id = t.id and c.channel <> 'unknown';
      if v_attr is null then v_first := 0;
      else
        select count(*) into v_first
        from cma.first_orders_of(t.id, v_attr::timestamp at time zone v_zone, v_now) o
        join cma.commerce_order co on co.tenant_id = t.id and co.id = o.order_id
        join cma.active_customer c on c.tenant_id = t.id and c.connection_id = co.connection_id and c.source_id = co.customer_source_id
        where o.kind = 'first';
      end if;
      v_wres := case when pg_temp.v0009m_p('W1') then 'FAIL' when v_first = 0 then 'skip' when v_attr <= v_today and v_known > 0 then 'PASS' else 'FAIL' end;
      v_w := format('opened in this step: the history starts %s (%s days back), first orders of the take''s customers %s, customers with a known acquisition channel %s | ',
                    coalesce(v_attr::text, 'never'), coalesce((v_today - v_attr)::text, '-'), v_first, v_known) || v_w;
      raise exception using errcode = 'CMAOK', message = 'rollback';
    exception
      when sqlstate 'CMAOK' then null;
      when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
    end;
    perform set_config('role', 'cma_owner', true);
    if v_err is not null then
      insert into pg_temp.verify_0009m values (100, 'P1 to E3 ' || t.slug || ': the checks ran to their end', 'FAIL', v_err);
      continue;
    end if;
    perform pg_temp.v0009m_row(10, 'P1', t.slug || ': the live present of 174 equals 172''s row for row',
      format('rows differing %s; rows %s', n_diff + case when pg_temp.v0009m_p('P1') then 1 else 0 end, case when n_new > 0 then 'some' else 'none' end),
      format('rows differing 0; rows %s', case when exists (select 1 from cma.subscription s where s.tenant_id = t.id and s.source_deleted_at is null
                                                                and s.status = any (cma.flash_holding_statuses_of(t.id))) then 'some' else 'none' end));
    v_moved := v_k0 is distinct from v_k1 and current_setting('verify.provoke') = 'false';
    if v_moved then
      insert into pg_temp.verify_0009m values (20, 'R1, Q1, E2 ' || t.slug || ': the refreshes compared on the same rows', 'skip',
        'the inputs moved during the check (an ingest wrote a subscription, a device, a customer, an order or a contact): run again');
    else
      perform pg_temp.v0009m_row(20, 'R1', t.slug || ': a forced refresh of 174 writes the same take as 172''s at the same moment', d_new, d_old);
      perform pg_temp.v0009m_row(30, 'Q1', t.slug || ': a due run with nothing changed computes nothing and leaves what a recompute would write; a changed input, a stale take, a new business date and a take without a key compute again', v_q,
        'nothing changed: refreshed true unchanged true rows 0, the take''s moment moved true, the six tables as they were true'
        || ' | past the refresh''s interval, a quiet run leaves what 172''s due run writes then: true'
        || ' | a customer delivered again unchanged: unchanged true | a customer''s link changed: unchanged false'
        || ' | a subscription written since: unchanged false | a stale take: unchanged false | a new business date: unchanged false'
        || ' | a take without inputs_key: unchanged false, then it holds one true');
    end if;
    perform pg_temp.v0009m_row(40, 'A1', t.slug || ': the planner''s row counts of the take''s tables follow a fill', v_a,
      'tables whose planner count is off by more than a fifth: 0; tables with rows and no statistics: 0; a second call analyzes 0; the first refresh reported tables_analyzed a number');
    if v_mid then
      insert into pg_temp.verify_0009m values (31, 'Q1 note ' || t.slug, 'info',
        'the later moment falls on the tenant''s next business date: the quiet take was not compared with 172''s due run at that moment; run again after midnight');
    end if;
    insert into pg_temp.verify_0009m values (50, 'W1 ' || t.slug || ': with the attribution''s window open, customers get a known acquisition channel', v_wres, left(v_w, 1500));
    insert into pg_temp.verify_0009m values (60, 'E1 ' || t.slug || ': the forced refresh within its budget, after it computed ' || v_comp || ' times on this connection (' || v_hist || ' with the history)',
      case when v_forced <= case when pg_temp.v0009m_p('E1') then 0 else current_setting('verify.max_refresh_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms against %s ms', v_forced, case when pg_temp.v0009m_p('E1') then '0' else current_setting('verify.max_refresh_ms') end));
    if not v_moved then
    insert into pg_temp.verify_0009m values (61, 'E2 ' || t.slug || ': a due run with nothing changed within the quiet budget',
      case when v_quiet <= case when pg_temp.v0009m_p('E2') then 0 else current_setting('verify.max_quiet_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms (best of 3) against %s ms', coalesce(v_quiet::text, 'no quiet run'), case when pg_temp.v0009m_p('E2') then '0' else current_setting('verify.max_quiet_ms') end));
    end if;
    insert into pg_temp.verify_0009m values (62, 'E3 ' || t.slug || ': the live present of the tiles within the above-the-fold budget',
      case when v_live <= case when pg_temp.v0009m_p('E3') then 0 else current_setting('verify.max_top_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms (best of 3, after six calls) against %s ms', v_live, case when pg_temp.v0009m_p('E3') then '0' else current_setting('verify.max_top_ms') end));
  end loop;
  if not v_any then
    insert into pg_temp.verify_0009m values (10, 'P1 to E3 the refresh and the live present per tenant',
      case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end, 'no active tenant with a subscription has its sources set up');
  end if;
end
$$;

drop function if exists pg_temp.v0009m_refresh_172(uuid, boolean, timestamptz);
drop function if exists pg_temp.v0009m_present_172(uuid);
drop function if exists pg_temp.v0009m_digest(text, uuid, text[]);
drop function if exists pg_temp.v0009m_row(integer, text, text, text, text);
drop function if exists pg_temp.v0009m_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009m
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009m where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009m where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('175_verify_active_refresh_quiet: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009m where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009m where result = 'FAIL'), (select count(*) from pg_temp.verify_0009m where result = 'skip'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0009m;
reset role;
