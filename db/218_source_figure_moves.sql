-- =============================================================================================
-- 218_source_figure_moves.sql: addition 0009zi, the source figures' exits and pauses count one move into a status
-- once, however many of the subscription app's events report it
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 214_source_figures.sql
-- (0009zg); it does not need 216 (0009zh, #308), which re-creates none of what this script re-creates, and either may
-- run first. Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 219_verify_source_figure_moves.sql there (normal, then provoked), then the verify that reads what this re-creates:
-- 215_verify_source_figures.sql (cma.ingest_upsert_source_figures; unchanged by this change, it still expects its hand
-- counts). No other verify reads the write (grep -lw 'cma\.ingest_upsert_source_figures' db/*verify*.sql). Prod: this
-- script and 219 (its block B refuses prod's data, as 215's does; block A reads prod's stored figures). No page reads
-- anything new, so the order against the merge does not matter; no index (below).
--
-- Why (Martin, 22 November 2026, after the first prod run of the source figures, PROD_RUNBOOK 19.6 and 19.7): 106 of 108
-- figures equal; the two that differ are both exits into canceled on 21 November, DE app 11, CMA 22, GB app 1, CMA 2:
-- the CMA's side exactly double, for canceled only. The subscription app reports a cancellation twice (the adapter maps
-- subscription:cancelled to canceled and subscription:updated with the status CANCELLED to status_changed into
-- canceled: ingest/src/adapters/juo/map.mjs), and 214 counted every event whose status_to is the figure's status. A move
-- into failed comes as status_changed alone, which is why failed matched.
--
-- The rule (cma.source_figure_moves_of): a move into a status is an event that sets a status (status_changed, canceled,
-- paused, resumed, reactivated; the status as cma.subscription_moves_of reads it: status_changed its status_to, canceled
-- canceled, paused paused, resumed and reactivated active) while the subscription was not in it already: the status
-- before the event is the one its previous status event set (by time, then the event's id in "C" order, as
-- cma.subscription_moves_of orders them), else the event's own status_from. So the second report of one cancellation is
-- no move, a cancel, reactivation and cancel on one day are two, and a report into canceled of a subscription canceled the
-- day before is none. It is the same rule for reported moves as cma.subscription_moves_of's for the Churn rate and the
-- Failed rate (B39c), which already counts each move once (219 B2 proves both on the same events). Where they differ,
-- none of it the double report: that one reads present subscriptions only, adds a last move into the current status
-- where no event reports it, takes a first event's missing status_from as active and calls a move from one ended status
-- into another no churn; this one counts the events of every subscription the app reported, a first event without a
-- status_from as a move, and a move into expired from canceled as an exit into expired. Only events the CMA held by a moment count (synced_at, the moment the
-- CMA first held the event; events are append-only), so a stored value can be counted again exactly as it was taken.
-- A data prerequisite (CLAUDE.md, principle 6): a move the app reports with no event (the audit's status_chain, 210) is
-- missing here as in cma.subscription_moves_of: canceled, reactivated without an event, canceled again counts once.
--
-- What it adds
--   function   cma.source_figure_moves_of(tenant, connection, status, from, to, known_by): the moves of a connection into a
--              status between two moments, of the events the CMA held by known_by (the application's: the write calls it
--              under the ingest with now())
-- What it re-creates
--   cma.ingest_upsert_source_figures(uuid,uuid,jsonb)   214: exits and pauses count moves (the rest unchanged); JIT off
-- What it changes in stored rows
--   cma.source_figure.cma_value of every exits and pauses row: recounted with the rule for its business date, of the
--   events the CMA held at cma_at, cma_at kept: the value is the CMA's as it was taken, counted by the rule. A NOTICE names the rows changed per figure (psql shows it; Studio does not, so the
--   runbook runs this from the Terminal and lists the differing rows before and after from Studio: PROD_RUNBOOK 19.13 and
--   19.16). No audit trigger on the table (214); 219's A3 proves the state after it, not what it changed.
-- Who reads the recounted values: cma.source_figure_rows_of and cma.source_figure_compare_of, so data quality's
-- source_figure_gap and through it Flash's findings (from their next refresh; a stored Flash snapshot keeps what it took),
-- and cma_read.source_figure. #308's source counts (216) read only subscriptions_in_status and recurring_amount_active,
-- which this does not touch.
-- No index: the day's events of a connection are found as 214 found them (subscription_event_occurred_idx), and each
-- event's previous status event through subscription_event_subscription_idx (tenant, connection, subscription); a day
-- holds some 20 such events a store.
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
  if not exists (select 1 from cma.schema_migration where version = '0009zg') then
    raise exception 'addition 0009zg (214_source_figures.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The moves of a connection into a status between two moments
-- ---------------------------------------------------------------------------------------------
-- Keyed by p_tenant_id (the owner's recount below reads every tenant; under the application row-level security keeps the
-- current tenant's rows). Events from p_from up to, not including, p_to, the CMA held by p_known_by (synced_at), the
-- previous status event among them too
create or replace function cma.source_figure_moves_of(p_tenant_id uuid, p_connection_id uuid, p_status text, p_from timestamptz,
                                                      p_to timestamptz, p_known_by timestamptz)
returns bigint
language sql stable
as $$
  select count(*)
  from cma.subscription_event e
  where e.tenant_id = p_tenant_id and e.connection_id = p_connection_id
    and e.occurred_at >= p_from and e.occurred_at < p_to and e.synced_at <= p_known_by
    and e.event_type in ('status_changed', 'canceled', 'paused', 'resumed', 'reactivated')
    and case e.event_type when 'status_changed' then e.status_to when 'canceled' then 'canceled' when 'paused' then 'paused'
                          else 'active' end = p_status
    -- the status before it: its previous status event's, else its own status_from
    and coalesce((select case p.event_type when 'status_changed' then p.status_to when 'canceled' then 'canceled'
                                           when 'paused' then 'paused' else 'active' end
                   from cma.subscription_event p
                   where p.tenant_id = p_tenant_id and p.connection_id = p_connection_id
                     and p.subscription_source_id = e.subscription_source_id and p.synced_at <= p_known_by
                     and p.event_type in ('status_changed', 'canceled', 'paused', 'resumed', 'reactivated')
                     and (p.occurred_at < e.occurred_at
                          or (p.occurred_at = e.occurred_at and p.source_id collate "C" < e.source_id collate "C"))
                   order by p.occurred_at desc, p.source_id collate "C" desc
                   limit 1),
                  e.status_from) is distinct from p_status
$$;
comment on function cma.source_figure_moves_of(uuid, uuid, text, timestamptz, timestamptz, timestamptz) is
  'The moves of a subscriptions connection into a status between two moments, of the events the CMA held by a third (synced_at) (addition 0009zi): events that set a status while the subscription was not in it already (its previous status event''s status, else the event''s status_from), so one move counts once however many of the app''s events report it';

-- ---------------------------------------------------------------------------------------------
-- 2. The write: exits and pauses count moves
-- ---------------------------------------------------------------------------------------------
-- As 0009zg's (214), with exits and pauses counted by cma.source_figure_moves_of; nothing else changes
-- based on: 214_source_figures.sql
create or replace function cma.ingest_upsert_source_figures(p_connection_id uuid, p_run_id uuid, p_items jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_zone   text;
  v_bad    text;
  v_out    jsonb;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if not exists (select 1 from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id and c.kind = 'subscriptions') then
    raise exception 'connection % is not a subscriptions connection', p_connection_id using errcode = 'CMA02';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 2000 then
    raise exception 'source figures are an array of at most 2,000 items' using errcode = 'CMA04';
  end if;
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;

  -- every item checked before anything is written: the first fault named
  select f.fault into v_bad
  from jsonb_array_elements(p_items) with ordinality i(x, n)
  left join cma.source_figure_keys() k on k.figure_key = i.x ->> 'figureKey'
  cross join lateral (select case
           when jsonb_typeof(i.x) <> 'object' then 'an item is no object'
           when exists (select 1 from jsonb_object_keys(i.x) y
                        where y not in ('figureKey', 'sourceMetric', 'businessDate', 'dims', 'value', 'unit')) then 'an item holds a key outside the list'
           when k.figure_key is null then 'figureKey is no figure of cma.source_figure_keys()'
           when coalesce(i.x ->> 'sourceMetric', '') !~ '^[a-z][a-z0-9:._-]{0,79}$' then 'sourceMetric is out of its form'
           when coalesce(i.x ->> 'businessDate', '') !~ '^\d{4}-\d{2}-\d{2}$' then 'businessDate is no date as YYYY-MM-DD'
           when jsonb_typeof(i.x -> 'value') is distinct from 'number' then 'value is no number'
           when (i.x ->> 'value')::numeric < 0 or round((i.x ->> 'value')::numeric, 2) >= 1e16 then 'value is out of its range (0 to 10^16)'
           when (i.x ->> 'unit') is distinct from k.unit then 'unit is not the figure''s'
           when not cma.source_figure_dims_ok(k.figure_key, coalesce(i.x -> 'dims', '{}'::jsonb)) then 'dims are not the figure''s'
         end as fault) f
  where f.fault is not null
  order by i.n
  limit 1;
  if v_bad is not null then
    raise exception 'invalid source figure: %', v_bad using errcode = 'CMA04';
  end if;
  begin
    perform (i ->> 'businessDate')::date from jsonb_array_elements(p_items) i;
  exception when others then
    raise exception 'invalid source figure: businessDate is no date as YYYY-MM-DD' using errcode = 'CMA04';
  end;

  with it as (
    -- one item per key: the last one given wins
    select distinct on (i.x ->> 'figureKey', (i.x ->> 'businessDate')::date, coalesce(i.x -> 'dims', '{}'::jsonb))
           i.x ->> 'figureKey' as figure_key, i.x ->> 'sourceMetric' as source_metric, (i.x ->> 'businessDate')::date as business_date,
           coalesce(i.x -> 'dims', '{}'::jsonb) as dims, round((i.x ->> 'value')::numeric, 2) as value, i.x ->> 'unit' as unit
    from jsonb_array_elements(p_items) with ordinality i(x, n)
    order by i.x ->> 'figureKey', (i.x ->> 'businessDate')::date, coalesce(i.x -> 'dims', '{}'::jsonb), i.n desc
  ), cur as (
    -- the connection's active subscriptions' monthly amount and its currencies, once (recurring_amount_active)
    select count(distinct s.currency) as currencies, min(s.currency) as currency,
           round(coalesce(sum(s.amount_per_cycle * cma.active_month_factor_of(s.billing_interval, s.billing_interval_count)), 0), 2) as amount
    from cma.subscription s
    where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.source_deleted_at is null and s.status = 'active'
      and s.currency is not null and s.amount_per_cycle is not null
  ), v as (
    select it.*,
           case when it.figure_key = 'recurring_amount_active' then (select case when cur.currencies = 1 then cur.currency end from cur) end as currency,
           case it.figure_key
             when 'subscriptions_in_status' then
               (select count(*) from cma.subscription s
                where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.source_deleted_at is null
                  and s.status = it.dims ->> 'status')::numeric
             when 'recurring_amount_active' then
               (select case when cur.currencies = 1 then cur.amount when cur.currencies = 0 then 0 end from cur)
             when 'renewal_survival' then null::numeric
             else
               case it.figure_key
                 when 'renewals' then
                   (select count(*) from cma.subscription_event e
                    where e.tenant_id = v_tenant and e.connection_id = p_connection_id and e.event_type = 'renewed'
                      and e.occurred_at >= (it.business_date::timestamp at time zone v_zone)
                      and e.occurred_at < ((it.business_date + 1)::timestamp at time zone v_zone))::numeric
                 when 'purchases' then
                   (select count(*) from cma.subscription_event e
                    where e.tenant_id = v_tenant and e.connection_id = p_connection_id and e.event_type = 'purchased'
                      and e.occurred_at >= (it.business_date::timestamp at time zone v_zone)
                      and e.occurred_at < ((it.business_date + 1)::timestamp at time zone v_zone))::numeric
                 -- 0009zi: one move into the status counts once, however many of the app's events report it (a
                 -- cancellation arrives as canceled and as status_changed into canceled)
                 when 'pauses' then
                   cma.source_figure_moves_of(v_tenant, p_connection_id, 'paused', (it.business_date::timestamp at time zone v_zone),
                                              ((it.business_date + 1)::timestamp at time zone v_zone), now())::numeric
                 when 'exits' then
                   cma.source_figure_moves_of(v_tenant, p_connection_id, it.dims ->> 'status', (it.business_date::timestamp at time zone v_zone),
                                              ((it.business_date + 1)::timestamp at time zone v_zone), now())::numeric
               end
           end as cma_value
    from it
  ), old as (
    select f.figure_key, f.business_date, f.dims, f.value, f.currency, f.cma_value
    from cma.source_figure f
    join v on v.figure_key = f.figure_key and v.business_date = f.business_date and v.dims = f.dims
    where f.tenant_id = v_tenant and f.connection_id = p_connection_id
  ), w as (
    insert into cma.source_figure as f (tenant_id, connection_id, figure_key, source_metric, business_date, dims, value, unit, currency,
                                        cma_value, cma_at, fetched_at, run_id, raw)
    select v_tenant, p_connection_id, v.figure_key, v.source_metric, v.business_date, v.dims, v.value, v.unit, v.currency,
           v.cma_value, case when v.cma_value is not null then now() end, now(), p_run_id,
           jsonb_build_object('first_fetched_at', now(), 'fetches', 1)
    from v
    order by v.figure_key, v.business_date, v.dims
    on conflict (tenant_id, connection_id, figure_key, business_date, dims) do update
      set source_metric = excluded.source_metric, value = excluded.value, unit = excluded.unit, currency = excluded.currency,
          cma_value = excluded.cma_value, cma_at = excluded.cma_at, fetched_at = excluded.fetched_at, run_id = excluded.run_id,
          raw = jsonb_build_object('first_fetched_at', coalesce(f.raw -> 'first_fetched_at', excluded.raw -> 'first_fetched_at'),
                                   'fetches', coalesce((f.raw ->> 'fetches')::integer, 0) + 1)
    returning f.figure_key, f.business_date, f.dims, f.value, f.currency, f.cma_value
  )
  select jsonb_build_object(
           'inserted',  count(*) filter (where o.figure_key is null),
           'updated',   count(*) filter (where o.figure_key is not null
                                         and (o.value, o.currency, o.cma_value) is distinct from (w.value, w.currency, w.cma_value)),
           'unchanged', count(*) filter (where o.figure_key is not null
                                         and (o.value, o.currency, o.cma_value) is not distinct from (w.value, w.currency, w.cma_value)))
  into v_out
  from w
  left join old o on o.figure_key = w.figure_key and o.business_date = w.business_date and o.dims = w.dims;
  return v_out;
end
$$;
do $$
declare
  f text;
begin
  foreach f in array array['cma.source_figure_moves_of(uuid,uuid,text,timestamptz,timestamptz,timestamptz)', 'cma.ingest_upsert_source_figures(uuid,uuid,jsonb)'] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- a create or replace replaces a function's settings: JIT off said again, as 214 set it
  execute 'alter function cma.ingest_upsert_source_figures(uuid,uuid,jsonb) set jit = off';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The stored values recounted
-- ---------------------------------------------------------------------------------------------
-- Every exits and pauses row with a CMA value, every tenant: the moves of its business date in the tenant's zone among
-- the events the CMA held at cma_at, so the value is the one 214 took then, counted by the rule. Only a value that
-- differs is written; cma_at is kept
do $$
declare
  v_changes text;
begin
  with n as (
    select f.tenant_id, f.connection_id, f.figure_key, f.business_date, f.dims, f.cma_value as old_value,
           cma.source_figure_moves_of(f.tenant_id, f.connection_id,
                                      case f.figure_key when 'pauses' then 'paused' else f.dims ->> 'status' end,
                                      f.business_date::timestamp at time zone t.timezone,
                                      (f.business_date + 1)::timestamp at time zone t.timezone, f.cma_at)::numeric as new_value
    from cma.source_figure f
    join cma.tenant t on t.id = f.tenant_id
    where f.figure_key in ('exits', 'pauses') and f.cma_value is not null and f.cma_at is not null
  ), w as (
    update cma.source_figure f
    set cma_value = n.new_value
    from n
    where f.tenant_id = n.tenant_id and f.connection_id = n.connection_id and f.figure_key = n.figure_key
      and f.business_date = n.business_date and f.dims = n.dims and f.cma_value is distinct from n.new_value
    returning f.figure_key, n.old_value, n.new_value
  )
  select string_agg(x.figure_key || ' ' || x.n || ' row(s), ' || x.old_sum || ' to ' || x.new_sum, '; ' order by x.figure_key collate "C")
  into v_changes
  from (select w.figure_key, count(*) as n, sum(w.old_value)::bigint as old_sum, sum(w.new_value)::bigint as new_sum from w group by 1) x;
  raise notice '0009zi: the stored CMA values recounted: %', coalesce(v_changes, 'none changed');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zi', 'The source figures'' exits and pauses count one move into a status once, however many of the subscription app''s events report it (a cancellation arrives as canceled and as status_changed into canceled; 214 counted both): cma.source_figure_moves_of (the application''s), cma.ingest_upsert_source_figures re-created from 214 with exits and pauses counted by it, and the stored exits and pauses rows'' CMA values recounted for the moment they were taken (cma_at kept)')
on conflict (version) do nothing;

commit;
reset role;
