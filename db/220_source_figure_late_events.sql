-- =============================================================================================
-- 220_source_figure_late_events.sql: addition 0009zj, a source figure's CMA value counts the events the CMA stored after
-- the value was first taken
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 218_source_figure_moves.sql
-- (0009zi). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 221_verify_source_figure_late_events.sql there (normal, then provoked), then the verifies that read what this
-- re-creates: 215_verify_source_figures.sql and 219_verify_source_figure_moves.sql (cma.ingest_upsert_source_figures;
-- neither is edited: a write without a late event answers as before). No other verify reads the write (grep -lw
-- 'cma\.ingest_upsert_source_figures' db/*verify*.sql). Prod: this script, 221 and 219 (their blocks B refuse prod's data,
-- as 215's does; 215 runs in dev only), away from the hourly figures job (41 * * * *). No page reads anything new and no ingest code
-- changes, so the order against the merge does not matter; no index (the late events are found through
-- subscription_event_synced_idx, 212).
--
-- Why (Martin, 23 November 2026, PROD_RUNBOOK 19.16, 19.18 and 19.19 after 218 in prod): the CMA read 0 for DE's exits into
-- canceled on days until 20 May 2026 while it holds DE's status_changed events into canceled every month from February to
-- May (12, 11, 15, 11) and B39c's churned equals the app's for DE in February to April. The difference between the two
-- counts is the moment: B39c reads the events the CMA holds now, the source figure the events the CMA held when its value
-- was taken (synced_at <= cma_at, 218's rule, so a stored value can be counted again exactly). An event stored after the
-- value was taken (a late sync or a backfill of the events) never reached it, because a day's figure is written once,
-- when its day is read (the daily read, or the month backfill of PROD_RUNBOOK 19.9), and never again. Every other path
-- of 218's rule (a status_from, a previous status event, the day's bounds in the tenant's zone) is the same in B39c's
-- moves, which match. PROD_RUNBOOK 19.20 shows the late events per row before this runs (counts and dates only).
--
-- The rule (unchanged): cma.source_figure_moves_of, one move into a status counted once (218). What changes is when a
-- stored value is taken again:
--   at each write (cma.ingest_upsert_source_figures, once a day per store): besides the days it was given, every exits and
--     pauses row of the connection whose business day (the tenant's zone) holds a status event stored since the previous
--     write (the connection's latest cma_at before this write, one hour earlier: a sync that committed late is still
--     found, and a day counted twice costs a few milliseconds), or the next status event of such an event's subscription
--     (whose previous status the late event may change: a cancellation stored late makes the next day's report into
--     canceled no move), is counted again among the events the CMA holds now, and its cma_at moves to now. The rows are
--     locked in key order first, as the write orders its own. The answer names those rows as recounted, only when there
--     are any (the ingest sums its three counts only, so the run's log does not show it)
--   now, once (section 2): every stored exits and pauses row of every tenant is counted among the events the CMA holds
--     now, cma_at now, so the first write after this one starts from a current state
-- cma_at keeps its meaning (the moment the CMA's value was taken), so 219's A3 (the value equals the rule among the
-- events held at cma_at) stays exact. A backfill of the events (the next addition's) reaches the stored figures at the
-- next write of each store, without a recount of its own.
--
-- What it re-creates
--   cma.ingest_upsert_source_figures(uuid,uuid,jsonb)   218: the days with events stored since the previous write counted
--                                                       again; JIT off
-- What it changes in stored rows
--   cma.source_figure.cma_value and cma_at of every exits and pauses row: counted among the events the CMA holds now. A
--   NOTICE names the values changed per figure and the rows taken again (psql shows it; Studio does not, so the runbook
--   runs this from the Terminal: PROD_RUNBOOK 19.21). No audit trigger on the table (214); 221's A3 and A4 prove the state
--   after it, not what it changed.
-- Who reads the values: cma.source_figure_rows_of and cma.source_figure_compare_of, so data quality's source_figure_gap
-- and through it Flash's findings (from their next refresh), and cma_read.source_figure.
-- Cost: the write reads the connection's status events stored since the previous write (a day's sync: hundreds) through
-- subscription_event_synced_idx (tenant, synced_at), then counts again the few rows of their days (a day's sync touches
-- the day before and today, both written anyway); after a backfill of the events, every day of the history once (some
-- milliseconds a row: a store's whole history, 1,532 rows, in 390 ms on the volume fixture under one CPU; the next call
-- 14 ms). Section 2 counts every stored exits and pauses row once, as 218's recount did.
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
  if not exists (select 1 from cma.schema_migration where version = '0009zi') then
    raise exception 'addition 0009zi (218_source_figure_moves.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The write: a day with events stored since the previous write is counted again
-- ---------------------------------------------------------------------------------------------
-- As 0009zi's (218), with the late days counted again after the write; nothing else changes
-- based on: 218_source_figure_moves.sql
create or replace function cma.ingest_upsert_source_figures(p_connection_id uuid, p_run_id uuid, p_items jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_zone   text;
  v_bad    text;
  v_out    jsonb;
  v_since  timestamptz;
  v_days   date[];
  v_late   integer := 0;
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

  -- 0009zj: the previous write's moment (its cma_at), an hour earlier, read before this write: the events stored since
  -- then are the ones its counts may lack
  select max(f.cma_at) - interval '1 hour' into v_since
  from cma.source_figure f
  where f.tenant_id = v_tenant and f.connection_id = p_connection_id and f.figure_key in ('exits', 'pauses') and f.cma_at is not null;

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

  -- 0009zj: an event the CMA stored after a day's count was taken (a late sync, a backfill) is counted at the next write:
  -- every stored exits and pauses row of a day that holds a status event stored since the previous write is counted
  -- again among the events the CMA holds now, and its cma_at moves to now. Planned at each call (a range over
  -- subscription_event_synced_idx, whose bound only the call knows)
  if v_since is not null then
    -- a late event's own day, and the day of its subscription's next status event, whose previous status it may change
    -- (a late cancellation on one day makes the next day's report into canceled no move)
    execute 'with late as (
               select e.subscription_source_id, e.occurred_at, e.source_id
               from cma.subscription_event e
               where e.tenant_id = $1 and e.synced_at > $4 and e.connection_id = $2
                 and e.event_type in (''status_changed'', ''canceled'', ''paused'', ''resumed'', ''reactivated''))
             select array_agg(distinct d.day)
             from (select (l.occurred_at at time zone $3)::date as day from late l
                   union all
                   select (n.occurred_at at time zone $3)::date
                   from late l
                   cross join lateral (
                     select x.occurred_at
                     from cma.subscription_event x
                     where x.tenant_id = $1 and x.connection_id = $2 and x.subscription_source_id = l.subscription_source_id
                       and x.event_type in (''status_changed'', ''canceled'', ''paused'', ''resumed'', ''reactivated'')
                       and (x.occurred_at > l.occurred_at or (x.occurred_at = l.occurred_at and x.source_id collate "C" > l.source_id collate "C"))
                     order by x.occurred_at, x.source_id collate "C"
                     limit 1) n) d'
      into v_days using v_tenant, p_connection_id, v_zone, v_since;
    if v_days is not null then
      -- the rows locked in key order first, as the write above orders its own; two writes on one connection (the hourly
      -- job and a month backfill) whose written and late days overlap can still wait on each other, and Postgres then
      -- ends one, which the next hourly run repeats
      perform 1
      from cma.source_figure f
      where f.tenant_id = v_tenant and f.connection_id = p_connection_id and f.figure_key in ('exits', 'pauses')
        and f.business_date = any (v_days) and f.cma_value is not null and f.cma_at < now()
      order by f.figure_key, f.business_date, f.dims
      for update;
      update cma.source_figure f
      set cma_value = cma.source_figure_moves_of(v_tenant, p_connection_id, case f.figure_key when 'pauses' then 'paused' else f.dims ->> 'status' end,
                                                 f.business_date::timestamp at time zone v_zone,
                                                 (f.business_date + 1)::timestamp at time zone v_zone, now())::numeric,
          cma_at = now()
      where f.tenant_id = v_tenant and f.connection_id = p_connection_id and f.figure_key in ('exits', 'pauses')
        and f.business_date = any (v_days) and f.cma_value is not null and f.cma_at < now();
      get diagnostics v_late = row_count;
    end if;
  end if;
  -- the rows counted again, named only when there are any (the answer's three counts stay as they were)
  return case when v_late > 0 then v_out || jsonb_build_object('recounted', v_late) else v_out end;
end
$$;

do $$
begin
  execute 'revoke execute on function cma.ingest_upsert_source_figures(uuid,uuid,jsonb) from public';
  execute 'grant execute on function cma.ingest_upsert_source_figures(uuid,uuid,jsonb) to cma_app';
  -- a create or replace replaces a function's settings: JIT off said again, as 214 and 218 set it
  execute 'alter function cma.ingest_upsert_source_figures(uuid,uuid,jsonb) set jit = off';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The stored values counted among the events the CMA holds now
-- ---------------------------------------------------------------------------------------------
-- Every exits and pauses row with a CMA value, every tenant: the moves of its business date in the tenant's zone among
-- the events the CMA holds now; cma_at now for every row, so the next write's watermark starts here
do $$
declare
  v_changes text;
  v_rows    bigint;
begin
  with n as (
    select f.tenant_id, f.connection_id, f.figure_key, f.business_date, f.dims, f.cma_value as old_value,
           cma.source_figure_moves_of(f.tenant_id, f.connection_id,
                                      case f.figure_key when 'pauses' then 'paused' else f.dims ->> 'status' end,
                                      f.business_date::timestamp at time zone t.timezone,
                                      (f.business_date + 1)::timestamp at time zone t.timezone, now())::numeric as new_value
    from cma.source_figure f
    join cma.tenant t on t.id = f.tenant_id
    where f.figure_key in ('exits', 'pauses') and f.cma_value is not null and f.cma_at is not null
  ), w as (
    update cma.source_figure f
    set cma_value = n.new_value, cma_at = now()
    from n
    where f.tenant_id = n.tenant_id and f.connection_id = n.connection_id and f.figure_key = n.figure_key
      and f.business_date = n.business_date and f.dims = n.dims
    returning f.figure_key, n.old_value, n.new_value
  ), x as (
    select w.figure_key, count(*) filter (where w.old_value is distinct from w.new_value) as n,
           sum(w.old_value) filter (where w.old_value is distinct from w.new_value)::bigint as old_sum,
           sum(w.new_value) filter (where w.old_value is distinct from w.new_value)::bigint as new_sum, count(*) as taken
    from w group by 1
  )
  select string_agg(x.figure_key || ' ' || x.n || ' row(s)' || case when x.n > 0 then ', ' || x.old_sum || ' to ' || x.new_sum else '' end,
                    '; ' order by x.figure_key collate "C"),
         sum(x.taken)
  into v_changes, v_rows
  from x;
  raise notice '0009zj: the stored CMA values counted among the events held now: % row(s) taken again; values changed: %',
    coalesce(v_rows, 0), coalesce(v_changes, 'none');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zj', 'A source figure''s CMA value counts the events the CMA stored after the value was first taken: cma.ingest_upsert_source_figures re-created from 218, each write also counting again the connection''s exits and pauses rows of the days that hold a status event stored since the previous write, and every stored exits and pauses row counted among the events held now (cma_at now)')
on conflict (version) do nothing;

commit;
reset role;
