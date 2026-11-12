-- =============================================================================================
-- 174_active_refresh_quiet.sql: addition 0009m, Customers → Active's refresh after its first prod runs: a quiet run that
-- computes nothing, statistics that follow a fill, and a slimmer live present
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 172_active_customers.sql
-- (0009l). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 175_verify_active_refresh_quiet.sql there (normal, then provoked), then the verifies that read what this script
-- re-creates: 173_verify_active_customers.sql (not edited: its E4 and E5 are the two figures this change answers) and
-- 131_time_all.sql part b (its Active rows). No other verify reads cma.active_refresh_of or cma.active_present_of. Prod: this script, 175 and 173 before the merge of #267; the web of
-- main does not read these functions yet.
--
-- Why (Martin, 12 November 2026, prod's first runs of 173 and tools/perf/active-refresh-breakdown.sql;
-- records/0009l-prod-2026-11-12/):
--   1. Inside 173 the forced refresh took 56 and 45 s; alone on the same database 5.7 s. The difference is a cached
--      plan: 173's fixture block runs the refresh more than five times for tenants of a handful of rows, so the
--      connection keeps plans made for one row, and the timed refresh of the real tenant runs them over thousands (the
--      customers' statement as a nested loop of 22,680 by 12,915 rows on the three-times fixture: 16.8 s for it alone,
--      the whole run over eleven minutes; with the plans dropped first, 5.5 s). The job opens a connection per run and
--      plans each statement once, after the rows before it are written, so it does not meet this; but nothing told the
--      planner that the take's tables had grown, and a connection that planned a read of them while they were empty
--      would keep that plan. So the refresh itself analyzes a take table whose size changed much
--      (cma.active_take_analyze), which makes every connection plan again: 173, unchanged, then times the refresh at
--      what it costs (tools/perf/active-refresh-stale-plan.sql shows the kept plan beside the fresh one).
--   2. The live present of the tiles took 717 ms at prod's busy hour against 400 ms. It read Flash's whole per-customer
--      figures (every subscription grouped, every device grouped, the contacts' references) to learn two things per
--      holding subscription: its store customer and that customer's segment. cma.active_present_of now reads those
--      directly (the store's customer by its id, the contact's segment): the same rows, by construction and compared
--      row for row in 175 with 172's definition. Still live, nothing moved into the take.
--   3. A due run with nothing changed computed everything for 5.4 s and wrote nothing. The refresh now reads the
--      inputs' change markers first (cma.active_inputs_key_of) and leaves a take whose markers, business date and
--      settings are unchanged as it is, moving only its moment. Everything is computed again when a marker changes,
--      on a new business date (so at least nightly), after a settings change and when forced.
--
-- What it adds
--   column     cma.active_take.inputs_key: the markers' digest the take was computed under (null on a take of 0009l:
--              the next due run computes once and fills it)
--   function   cma.active_inputs_key_of(tenant): a digest of, per input table, its row count and latest write
--              (synced_at, which the mirrors move only when a row changes): the subscriptions, their events, the
--              devices, the stores' customers and orders, the CRM's contacts; and the stores (count and updated_at)
--   function   cma.active_take_analyze(tenant): analyzes each of the take's six tables whose row count differs from
--              the planner's by more than a fifth (and by 50 rows), or that was never analyzed; SECURITY DEFINER, owned
--              by cma_owner (the application may not analyze), search path pinned, the current tenant only; the
--              application's, called by the refresh
-- What it re-creates (each from its latest definition, 172, with its -- based on: line)
--   cma.active_present_of(tenant)                  the slimmer live read (2); JIT off repeated
--   cma.active_refresh_of(tenant, force, now)      the quiet run (3), the analyze after a fill (1), inputs_key written;
--                                                  its answer gains unchanged and tables_analyzed; JIT off repeated
-- What it leaves: 172's tables, reads, documents and the job. A take's meaning does not change: "History as of" is the
-- moment the take was last found or made current.
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
  if not exists (select 1 from cma.schema_migration where version = '0009l') then
    raise exception 'addition 0009l (172_active_customers.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The take's row: the inputs' markers it was computed under
-- ---------------------------------------------------------------------------------------------
alter table cma.active_take add column if not exists inputs_key text;
comment on column cma.active_take.inputs_key is 'The digest of the inputs'' change markers (cma.active_inputs_key_of) the take was computed under: a due refresh that finds the same digest computes nothing (addition 0009m)';

-- ---------------------------------------------------------------------------------------------
-- 2. The inputs' change markers
-- ---------------------------------------------------------------------------------------------
-- Per input table of the take the tenant's row count and latest write, as one digest. synced_at is the mirror's own
-- write time: an upsert moves it only when a row reads differently, a delete in the source sets it with
-- source_deleted_at, so an unchanged table gives the same pair. Epoch seconds, never a timestamp's text (a session's
-- time zone would change it). The caller's rights: the application reads its tenant's rows
create or replace function cma.active_inputs_key_of(p_tenant_id uuid)
returns text
language sql stable
as $$
  select md5(concat_ws('|',
    (select count(*)::text || '@' || coalesce(extract(epoch from max(x.synced_at))::text, '') from cma.subscription x where x.tenant_id = p_tenant_id),
    (select count(*)::text || '@' || coalesce(extract(epoch from max(x.synced_at))::text, '') from cma.subscription_event x where x.tenant_id = p_tenant_id),
    (select count(*)::text || '@' || coalesce(extract(epoch from max(x.synced_at))::text, '') from cma.device x where x.tenant_id = p_tenant_id),
    (select count(*)::text || '@' || coalesce(extract(epoch from max(x.synced_at))::text, '') from cma.commerce_customer x where x.tenant_id = p_tenant_id),
    (select count(*)::text || '@' || coalesce(extract(epoch from max(x.synced_at))::text, '') from cma.commerce_order x where x.tenant_id = p_tenant_id),
    (select count(*)::text || '@' || coalesce(extract(epoch from max(x.synced_at))::text, '') from cma.crm_contact x where x.tenant_id = p_tenant_id),
    (select count(*)::text || '@' || coalesce(extract(epoch from max(x.updated_at))::text, '') from cma.commerce_store x where x.tenant_id = p_tenant_id)))
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The take's statistics after a fill
-- ---------------------------------------------------------------------------------------------
-- A take table whose row count differs from the planner's figure by more than a fifth (and by more than 50 rows), or
-- that was never analyzed while it holds rows, is analyzed: the planner then knows the size the refresh just gave it,
-- and every connection drops the plans it made for the old size (an analyze invalidates them). Counted over the whole
-- table, every tenant's rows (the statistics are the table's). SECURITY DEFINER: the application may not analyze; the
-- function names its six tables itself and takes nothing of the caller's into a statement. Answers how many it analyzed
create or replace function cma.active_take_analyze(p_tenant_id uuid)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, cma, pg_temp
as $$
declare
  r      record;
  n      bigint;
  v_done integer := 0;
begin
  if p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a take''s statistics follow a refresh of the current tenant only' using errcode = 'CMA04';
  end if;
  for r in
    select c.oid::regclass as tbl, c.reltuples
    from pg_class c
    where c.oid in ('cma.active_base'::regclass, 'cma.active_customer'::regclass, 'cma.active_spell'::regclass,
                    'cma.active_month'::regclass, 'cma.active_cohort'::regclass, 'cma.active_document'::regclass)
    order by c.relname
  loop
    execute format('select count(*) from %s', r.tbl) into n;
    if (r.reltuples < 0 and n > 0) or abs(n - greatest(r.reltuples, 0)) > greatest(50, 0.2 * greatest(r.reltuples, 0)) then
      execute format('analyze %s', r.tbl);
      v_done := v_done + 1;
    end if;
  end loop;
  return v_done;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The live present, slimmer
-- ---------------------------------------------------------------------------------------------
-- The subscriptions in a device-holding status, each with its amount turned into a month, its store's market, its store
-- customer and that customer's segment. As 172's: the same rows and columns. 172 read them through Flash's per-customer
-- figures (cma.flash_customer_figures_of), which groups every subscription and every device of the tenant and reads the
-- contacts' references to answer far more than this read uses; here the store's customer is read by its key and the
-- contact's segment by its own, with Flash's own rule for it (cma.flash_segment_of). A customer found this way holds at
-- least the subscription it was found through, so it is an Active customer (Flash's holding_subscriptions > 0) by
-- construction; 175 compares the two definitions row for row
-- based on: 172_active_customers.sql
create or replace function cma.active_present_of(p_tenant_id uuid)
returns table (subscription_id uuid, status text, is_paying boolean, currency text, monthly_amount numeric, customer_id uuid,
               is_active boolean, market text, segment text)
language sql stable
rows 10000
as $$
  with s as materialized (
    select cma.flash_holding_statuses_of(p_tenant_id) as holding, cma.flash_active_statuses_of(p_tenant_id) as paying,
           cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments')) as segments,
           array(select lower(x) from unnest(cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments'))) with ordinality u(x, o)
                 order by o) as segments_lower
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  ), s0 as materialized (
    select x.id, x.connection_id, x.customer_source_id, x.status, x.currency,
           x.amount_per_cycle * cma.active_month_factor_of(x.billing_interval, x.billing_interval_count) as monthly_amount,
           x.status = any ((select s.paying from s)::text[]) as is_paying
    from cma.subscription x
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.status = any ((select s.holding from s)::text[])
  )
  select x.id, x.status, x.is_paying, x.currency, x.monthly_amount, c.id, c.id is not null,
         coalesce(sm.market, 'unknown'),
         case when c.id is null then 'unknown'
              else coalesce(cma.flash_segment_of(k.segment, (select s.segments from s), (select s.segments_lower from s)), 'unknown') end
  from s0 x
  left join sm on sm.connection_id = x.connection_id
  left join cma.commerce_customer c
    on c.tenant_id = p_tenant_id and c.connection_id = sm.store_connection_id and c.source_id = x.customer_source_id
   and c.source_deleted_at is null
  left join cma.crm_contact k
    on k.tenant_id = c.tenant_id and k.connection_id = c.crm_connection_id and k.source_id = c.crm_contact_source_id
   and k.source_deleted_at is null
$$;
alter function cma.active_present_of(uuid) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 5. The refresh: a quiet run, statistics after a fill
-- ---------------------------------------------------------------------------------------------
-- As 172's, statement for statement, with three additions: step 0 (the quiet run: the markers' digest compared with the
-- take's before anything is computed), cma.active_take_analyze after the base, the customers and the history are
-- written, and inputs_key on the take's row. Its answer gains unchanged (true for a quiet run, with every count 0) and
-- tables_analyzed
-- based on: 172_active_customers.sql
create or replace function cma.active_refresh_of(p_tenant_id uuid, p_force boolean default false, p_now timestamptz default null)
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
  v_inputs text;
  n_stats  integer := 0;
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

  -- 0. the quiet run (0009m): the inputs' change markers, read before anything is computed (a row that changes after
  --    this read gives the next run another key). The same key as the take's, on the same business date, with no
  --    setting saved since and no force: nothing the take is computed from changed, so the take stands as it is and
  --    only its moment moves. What the markers do not hold (the CRM's deals and calls behind the acquisition channel)
  --    is read again at the next change of a marker and at every new business date
  v_inputs := cma.active_inputs_key_of(p_tenant_id);
  if not v_all and v_take.inputs_key is not distinct from v_inputs then
    update cma.active_take t
    set computed_at = v_now, duration_ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer
    where t.tenant_id = p_tenant_id;
    return jsonb_build_object('refreshed', true, 'unchanged', true, 'base_rows', 0, 'customer_rows', 0, 'history_rows', 0,
                              'document_rows', 0, 'rows', 0,
                              'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
  end if;

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
  -- the take's tables just changed in size (a first take, a tenant's first fill): their statistics follow at once, so
  -- no plan made for a handful of rows is run over thousands (0009m; cma.active_take_analyze)
  if n_base + n_gone > 0 then n_stats := n_stats + cma.active_take_analyze(p_tenant_id); end if;

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
  if n_cust > 0 then n_stats := n_stats + cma.active_take_analyze(p_tenant_id); end if;

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
    -- the history's tables were written again: the documents below read them
    n_stats := n_stats + cma.active_take_analyze(p_tenant_id);
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
  insert into cma.active_take (tenant_id, computed_at, business_date, duration_ms, history_key, customers, subscriptions, attribution_start, stale, stale_since, inputs_key)
  values (p_tenant_id, v_now, v_today, 0, v_key, n_active, n_subs, v_attr, false, null, v_inputs)
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
      history_key = v_key, customers = n_active, subscriptions = n_subs, attribution_start = v_attr, inputs_key = v_inputs,
      stale = t.stale_marks is distinct from coalesce(v_take.stale_marks, 0),
      stale_since = case when t.stale_marks is distinct from coalesce(v_take.stale_marks, 0) then t.stale_since end
  where t.tenant_id = p_tenant_id;

  return jsonb_build_object('refreshed', true, 'unchanged', false, 'tables_analyzed', n_stats, 'base_rows', n_base + n_gone, 'customer_rows', n_cust, 'history_rows', n_hist,
                            'document_rows', n_docs, 'rows', n_base + n_gone + n_cust + n_hist + n_docs,
                            'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
end
$$;
alter function cma.active_refresh_of(uuid, boolean, timestamptz) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 6. Grants: the application only
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.active_inputs_key_of(uuid) from public;
grant execute on function cma.active_inputs_key_of(uuid) to cma_app;
revoke execute on function cma.active_take_analyze(uuid) from public;
grant execute on function cma.active_take_analyze(uuid) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 7. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009m', 'Customers → Active''s refresh after its first prod runs: a due run whose inputs'' change markers (cma.active_inputs_key_of, kept in cma.active_take.inputs_key) are unchanged computes nothing and moves the take''s moment only; a take table whose size changed much is analyzed at once (cma.active_take_analyze), so no plan made for a handful of rows is run over thousands; cma.active_present_of reads the store''s customer and the contact''s segment directly instead of Flash''s whole per-customer figures (the same rows)')
on conflict (version) do nothing;

commit;
reset role;
