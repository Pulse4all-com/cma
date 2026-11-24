-- =============================================================================================
-- 232_intake_call_center.sql: addition 0009zp, Intake separates call center work from the overall picture: lead deals
-- in and closed, and the other deals in, per business date and market
-- =============================================================================================
-- Universal: no customer, tenant, pipeline or vendor specifics. Runs unchanged in every database, after
-- 230_hours_market.sql (0009zo); it refuses to run before 0009zo is recorded. Rerunnable, forward-only, in one transaction
-- with a lock timeout. It reads crm_record and changes no table: no index, no lock on a busy table.
-- Run as your own IAM login: dev first, then 233_verify_intake_call_center.sql there (normal, then provoked), then the
-- verifies that read what this changes (below), then the datamap refresh; then prod, before the merge: this script, 233
-- and the same verifies. Main's web runs unchanged on it: its read of Intake takes select * from cma.intake_per_day and
-- maps the columns it knows by name, so the three new columns, appended last, are ignored until the web that reads them
-- is merged (RUNBOOK 7: prod's migration just before the merge).
--
-- Why (Martin, 24 November 2026, brief "Intake separates call center work from the overall picture"; applies Kira's
-- rule in Open decisions, Indirect sales: "once Shopify is connected, orders come from Shopify and the intake tiles count
-- lead pipelines only"; Decision log, 24 Nov 2026): Intake's Deals in and Deals closed counted every counted deal
-- pipeline, the order pipelines included, whose deals are web orders created and closed as won in one go. That inflated
-- both columns (23 Nov 2026: GB 68 in and 85 closed) and showed the same orders twice, as they are under Shop too.
--   1. Call center work counts deals of lead pipelines only: a counted deal pipeline with is_lead; a pipeline not yet
--      seen counts as lead, as in cma.lead_deals_of; a pipeline marked both lead and order counts as lead.
--   2. Deals of the other counted deal pipelines are no call center work: they show once, as a count (other deals in).
--   3. No pipeline flag changes.
--   6. The data keeps the old totals: deals_created and deals_closed (every counted deal pipeline) keep their meaning.
--
-- What it changes
--   cma.intake_per_day_row          three attributes appended last (alter type ... add attribute; the first fifteen keep
--                                   their names, types and positions): lead_deals_created (deals created in a lead
--                                   pipeline), lead_deals_closed (deals of a lead pipeline closed, won or lost, by their
--                                   closing time), other_deals_created (deals created in a counted pipeline that is no
--                                   lead pipeline). Integer, as every count of the row
--   cma.intake_per_day_of           132's definition with the deal rows carrying coalesce(p.is_lead, true) and the three
--                                   counts appended; every other rule as 132's: the tenant's zone, the intake.start_date
--                                   clamp, the market rule, the market codes read once, jit = off (repeated: a create or
--                                   replace drops it)
--   cma.intake_per_day              40's definition, recreated so it is re-stated against the grown type
--   cma_read.intake_per_day_rows()  40's definition (security definer, search path pinned), recreated likewise
--   cma_read.intake_per_day_v       recreated: a view's columns are fixed when it is created, so it appends the three
-- lead_deals_created + other_deals_created = deals_created on every row, and lead_deals_closed <= deals_closed (233).
--
-- Verifies that read what this changes (grep -lw 'cma\.intake_per_day' db/*verify*.sql, and the same for
-- cma_read\.intake_per_day; the three below are all, and no function or view in db/ calls these): rerun each after this
-- script, in dev and in prod
--   41_verify_lead_metrics.sql     A2 to A5, D1, D2 and F4 read by names, grants and sums; F4 compares the function's and
--                                  the view's rows as whole-row text (eighteen columns each side once the view is
--                                  recreated here): unchanged, passes
--   75_verify_forms_reporting.sql  intake_per_day_of by named columns: unchanged
--   133_verify_perf.sql            edited by this change: the kept 74 definition returns its fifteen columns as a table of
--                                  its own, and E6 compares the new function's fifteen earlier columns with it; S5's
--                                  jit = off holds again, as this script repeats it
--   233_verify_intake_call_center.sql  the new verify of this change: normal, then provoked
-- Datamap: docs/datamap/catalog.json (intake_per_day_v) is edited; Martin refreshes docs/datamap/schema.json from dev
-- after running this script there.
-- 131_time_all.sql (a budget, not a verify) is edited: the Dashboard's row 'crm records per day' goes (the Dashboard no
-- longer reads cma.crm_records_per_day: its Lead deals and Tickets tiles read the intake); 'intake per day' (dashboard
-- and intake) is unchanged and is timed again after this script.
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
select set_config('app.actor_label', 'migration:0009zp', true);

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0009zo') then
    raise exception 'addition 0009zo (230_hours_market.sql) must run before 0009zp';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The row: three counts appended last (rerunnable: each only when it is not there yet)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  a text;
begin
  foreach a in array array['lead_deals_created', 'lead_deals_closed', 'other_deals_created'] loop
    if not exists (select 1 from pg_attribute
                   where attrelid = (select typrelid from pg_type where oid = 'cma.intake_per_day_row'::regtype)
                     and attname = a and not attisdropped) then
      execute format('alter type cma.intake_per_day_row add attribute %I integer', a);
    end if;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Intake per day: the deals of lead pipelines apart
-- ---------------------------------------------------------------------------------------------
-- As 0008zr's (132): the same rows and the fifteen earlier columns. A deal row carries whether its pipeline is a lead
-- pipeline as cma.counted_deals_of reads it (coalesce(p.is_lead, true): a pipeline not yet seen is one; is_order plays no
-- part, so a pipeline marked lead and order is one); every other row carries null. The three counts follow
-- based on: 132_perf.sql
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
  codes as materialized (
    select * from cma.market_codes_of(p_tenant_id)
  ),
  e as (
    select fs.submitted_at as at, coalesce(cma.market_code_of(p_tenant_id, f.market), 'unknown') as market, 'form' as metric,
           null::boolean as is_lead
    from cma.form_submission fs
    join cma.connection_form f
      on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
    where fs.tenant_id = p_tenant_id and f.is_counted and cma.form_is_lead(f.lead_condition, fs.kept_values)
      and fs.submitted_at >= (select s.from_at from s) and fs.submitted_at < (select s.to_at from s)
    union all
    select x.at, coalesce(cr.code, cc.code, 'unknown'), x.metric, coalesce(p.is_lead, true)
    from (select cr.*, cr.source_created_at as at, cr.record_type || '_created' as metric
          from cma.crm_record cr
          union all
          select cr.*, cr.closed_at, cr.record_type || '_closed'
          from cma.crm_record cr where cr.is_closed and cr.closed_at is not null) x
    left join cma.connection_pipeline p
      on p.tenant_id = x.tenant_id and p.connection_id = x.connection_id
     and p.record_type = x.record_type and p.source_pipeline_id = x.pipeline_id
    left join codes cr on cr.value = x.market
    left join cma.crm_contact k on k.tenant_id = x.tenant_id and k.connection_id = x.connection_id and k.source_id = x.contact_source_id
    left join codes cc on cc.value = k.country
    where x.tenant_id = p_tenant_id and x.record_type in ('deal', 'ticket') and x.source_deleted_at is null
      and coalesce(p.is_counted, true) and x.at >= (select s.from_at from s) and x.at < (select s.to_at from s)
    union all
    select tc.started_at, coalesce(nc.code, 'unknown'), m.metric, null::boolean
    from cma.telephony_call tc
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join codes nc on nc.value = n.market
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
      and tc.started_at >= (select s.from_at from s) and tc.started_at < (select s.to_at from s)
    union all
    select cu.source_created_at, coalesce(sc.code, 'unknown'), 'customer', null::boolean
    from cma.commerce_customer cu
    left join cma.commerce_store st on st.tenant_id = cu.tenant_id and st.connection_id = cu.connection_id
    left join codes sc on sc.value = st.market
    where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null
      and cu.source_created_at >= (select s.from_at from s) and cu.source_created_at < (select s.to_at from s)
    union all
    select co.source_created_at, coalesce(sc.code, 'unknown'), 'order_' || co.order_kind, null::boolean
    from cma.commerce_order co
    left join cma.commerce_store st on st.tenant_id = co.tenant_id and st.connection_id = co.connection_id
    left join codes sc on sc.value = st.market
    where co.tenant_id = p_tenant_id and co.source_deleted_at is null and not co.is_test and co.cancelled_at is null
      and co.source_created_at >= (select s.from_at from s) and co.source_created_at < (select s.to_at from s)
  )
  select p_tenant_id, (e.at at time zone (select s.zone from s))::date, e.market,
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
         (count(*) filter (where e.metric = 'order_renewal'))::integer,
         (count(*) filter (where e.metric = 'deal_created' and e.is_lead))::integer,
         (count(*) filter (where e.metric = 'deal_closed' and e.is_lead))::integer,
         (count(*) filter (where e.metric = 'deal_created' and not e.is_lead))::integer
  from e
  group by 2, 3
$$;

-- 132's setting, repeated: a create or replace drops it (CLAUDE.md, Performance)
alter function cma.intake_per_day_of(uuid, timestamptz, timestamptz) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 3. What returns the row, re-stated against it
-- ---------------------------------------------------------------------------------------------
-- based on: 40_lead_metrics.sql
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

-- based on: 40_lead_metrics.sql
create or replace function cma_read.intake_per_day_rows()
returns setof cma.intake_per_day_row
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select r.* from cma.tenant t
  cross join lateral cma.intake_per_day_of(t.id, null, null) r
  where cma_read.reader_sees(t.id)
$$;

-- 40's view, its three new columns last
create or replace view cma_read.intake_per_day_v as
  select * from cma_read.intake_per_day_rows();

-- ---------------------------------------------------------------------------------------------
-- 4. Grants as 40 gave them (a create or replace keeps them; stated again so a rerun proves them)
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.intake_per_day(date, date) from public;
grant execute on function cma.intake_per_day(date, date) to cma_app;
revoke execute on function cma.intake_per_day_of(uuid, timestamptz, timestamptz) from public;
grant execute on function cma.intake_per_day_of(uuid, timestamptz, timestamptz) to cma_app;
revoke execute on function cma_read.intake_per_day_rows() from public;
grant execute on function cma_read.intake_per_day_rows() to cma_readonly;
grant select on cma_read.intake_per_day_v to cma_readonly;

-- ---------------------------------------------------------------------------------------------
-- 5. The addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zp', 'Intake separates call center work from the overall picture (Martin, 24 Nov 2026, applying Kira''s rule in Open decisions, Indirect sales): cma.intake_per_day_row appends lead_deals_created, lead_deals_closed (lead pipelines: is_lead, a pipeline not yet seen counts as lead, lead and order counts as lead) and other_deals_created (the other counted deal pipelines); cma.intake_per_day_of counts them (jit = off repeated), cma.intake_per_day, cma_read.intake_per_day_rows and cma_read.intake_per_day_v re-stated; deals_created and deals_closed keep their meaning; no pipeline flag changes')
on conflict (version) do nothing;

commit;
reset role;
