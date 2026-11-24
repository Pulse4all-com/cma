-- =============================================================================================
-- 237_verify_jobs_off_the_vcpu.sql: verifies addition 0009zr, the minute jobs off the vCPU (brief N07, PR N07a)
-- =============================================================================================
-- Universal: no seed is assumed. S1 checks the structure on the database itself; G1 to G4 write throwaway run rows, F1 to
-- F4 throwaway events, each inside a subtransaction that is always rolled back, so nothing stays and the script runs in
-- dev and in prod; L1 and L2 compare reads row for row and write nothing. Synthetic data only (invented ids v9zr-…, no
-- name, address or phone number of anyone); the comparisons print counts, never a row. Every check writes one row, OK or
-- FAIL (its detail then starts "FAIL <id>"), because Cloud SQL Studio shows no notices. Run as your own IAM login after
-- 236_jobs_off_the_vcpu.sql, dev first, then prod. Expected: S1, G1 to G4, F1 to F4, L1, L2 OK, then "PASS 0009zr".
-- Provoked (verify.provoke true at the top): every row FAIL and the verdict PROVOKED, NOT A PASS; F1 and L1 then also
-- compare with a deliberate difference (one stored outcome removed, one deal left out of 234's side), which their details
-- show (1 row differs, at least 1 row differs).
--
--   S1  0009zr recorded after 0009zq; cma.web_busy(text) SECURITY DEFINER owned by cma_owner; it, cma.job_gate_of(text),
--       cma.speed_to_lead_rows_of and cma.renewal_outcomes_of(uuid, uuid[], text[]) the application's only (not
--       public); the settings jobs.defer_web_statements (2), jobs.defer_max_in_a_row (5) and customers.refresh_minutes'
--       default 10; a value out of range refused (CMA04); cma.refresh_follow_up_of and the new outcomes form without
--       JIT; the small configuration tables with their analyze threshold
--   G1  the gate of every active tenant's jobs answers go or a known reason; a person without the job's permission is
--       refused (CMA06) by the gate and by cma.web_busy, which counts no statement of its own session
--   G2  backoff: one run cancelled by the statement timeout (57014) 3 minutes ago waits (5 minutes), 6 minutes ago goes;
--       two in a row 8 minutes ago wait (10); a gated run between them neither counts nor resets them; a succeeded run
--       after them resets the wait; six in a row wait at most 60 minutes
--   G3  the deferrals in a row are counted from the newest run back to the first one that did not defer
--   G4  nothing to read: the follow-up's gate for a tenant without an active CRM connection (all made inactive inside
--       the block) answers nothing_to_read; Flash's and data quality's never do
--   F1  a forced facts refresh stores exactly the outcomes 210's whole computation (kept below) gives
--   F2  new events on three subscriptions (a renewal, a failed renewal then a renewal, a new cycle) and a refresh twenty
--       minutes later: incremental (outcomes_whole false, its scope the subscriptions written), the stored outcomes equal
--       210's whole computation row for row
--   F3  a subscription's row written (its instrument type): in the scope, equal again
--   F4  a billing event written since: the next refresh computes the whole set (outcomes_whole true), equal again
--   L1  cma.speed_to_lead_of equals 234's definition (kept below) row for row for every active tenant, the whole history
--       and the previous calendar month
--   L2  cma.open_leads_of equals 234's open_leads_of row for row for every active tenant (the open-only bound)
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every check fail

drop table if exists pg_temp.verify_0009zr;
create temporary table verify_0009zr (ord integer, check_name text, result text, detail text);

create or replace function pg_temp.v9zr_row(p_ord integer, p_id text, p_name text, p_ok boolean, p_detail text)
returns void
language sql
as $$
  insert into pg_temp.verify_0009zr
  select p_ord, p_id || ' ' || p_name,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then 'OK' else 'FAIL' end,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then coalesce(p_detail, '')
              else 'FAIL ' || p_id || ': ' || case when current_setting('verify.provoke')::boolean then 'provoked; ' else '' end
                   || coalesce(p_detail, '(no detail)') end
$$;

create or replace function pg_temp.v9zr_code(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end
$$;

-- The previous definitions, verbatim: 234's cma.speed_to_lead_of and cma.open_leads_of, 210's cma.renewal_outcomes_of
create or replace function pg_temp.v9zr_stl_234(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
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

create or replace function pg_temp.v9zr_ol_234(p_tenant_id uuid)
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
    select * from pg_temp.v9zr_stl_234(p_tenant_id, null, null) x where x.status = 'not_called_open'
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

create or replace function pg_temp.v9zr_ro_210(p_tenant_id uuid)
returns table (connection_id uuid, subscription_source_id text, renewal_key text, cycle_index integer, renewal_source_id text,
               first_attempt_at timestamptz, outcome text, attempts integer, recovered_at timestamptz, days_to_recover numeric,
               error_code text, instrument_type text, payment_method_changed_before_recovery boolean)
language sql stable
rows 50000
as $$
  with a as (
    select e.connection_id, e.subscription_source_id, e.cycle_index,
           min(e.occurred_at) as first_at,
           min(e.occurred_at) filter (where e.event_type = 'renew_failed') as first_failed_at,
           min(e.occurred_at) filter (where e.event_type = 'renewed') as renewed_at,
           count(*) filter (where e.event_type = 'renew_failed') as failures,
           (array_agg(e.error_code order by e.occurred_at, e.source_id collate "C") filter (where e.event_type = 'renew_failed'))[1] as error_code,
           (array_agg(e.order_source_id order by e.occurred_at, e.source_id collate "C") filter (where e.event_type = 'renewed'))[1] as order_source_id
    from cma.subscription_event e
    where e.tenant_id = p_tenant_id and e.event_type in ('renewed', 'renew_failed') and e.cycle_index is not null
    group by 1, 2, 3
  ), cyc as (
    select a.connection_id, a.subscription_source_id, 'cycle:' || a.cycle_index as renewal_key, a.cycle_index, null::text as renewal_source_id,
           a.first_at,
           case when a.renewed_at is not null and exists (
                       select 1 from cma.billing_event b
                       where b.tenant_id = p_tenant_id and b.connection_id = a.connection_id and b.kind = 'chargeback'
                         and b.order_source_id = a.order_source_id) then 'charged_back'
                when a.renewed_at is not null and a.failures = 0 then 'paid_first_attempt'
                when a.renewed_at is not null then 'recovered'
                else 'not_recovered' end as outcome,
           (a.failures + case when a.renewed_at is not null then 1 else 0 end)::integer as attempts,
           case when a.failures > 0 then a.renewed_at end as recovered_at,
           case when a.failures > 0 and a.renewed_at is not null
                then round((extract(epoch from a.renewed_at - a.first_failed_at) / 86400)::numeric, 1) end as days_to_recover,
           a.error_code,
           case when a.failures > 0 and a.renewed_at is not null then exists (
                  select 1 from cma.subscription_event p
                  where p.tenant_id = p_tenant_id and p.connection_id = a.connection_id and p.subscription_source_id = a.subscription_source_id
                    and p.event_type = 'payment_method_changed' and p.occurred_at > a.first_failed_at and p.occurred_at < a.renewed_at) end as pm_changed
    from a
  ), inv as (
    select b.connection_id, b.renewal_source_id,
           coalesce(max(b.subscription_source_id),
                    (select min(x.source_id) from cma.subscription x
                     where x.tenant_id = p_tenant_id and x.connection_id = b.connection_id and x.customer_source_id = min(b.customer_source_id)
                       and x.source_deleted_at is null
                     having count(*) = 1)) as subscription_source_id,
           min(b.occurred_at) filter (where b.kind = 'invoice_placed') as placed_at,
           min(b.occurred_at) filter (where b.kind = 'invoice_paid') as paid_at,
           count(*) filter (where b.kind = 'invoice_payment_failed') as failures
    from cma.billing_event b
    where b.tenant_id = p_tenant_id and b.kind like 'invoice\_%' and b.renewal_source_id is not null
    group by 1, 2
  )
  select c.connection_id, c.subscription_source_id, c.renewal_key, c.cycle_index, c.renewal_source_id, c.first_at, c.outcome, c.attempts,
         c.recovered_at, c.days_to_recover, c.error_code, s.payment_instrument_type, c.pm_changed
  from cyc c
  left join cma.subscription s on s.tenant_id = p_tenant_id and s.connection_id = c.connection_id and s.source_id = c.subscription_source_id
  union all
  select i.connection_id, i.subscription_source_id, 'invoice:' || i.renewal_source_id, null, i.renewal_source_id, i.placed_at,
         case when i.paid_at is not null then 'invoice_paid' else 'invoice_open' end,
         (1 + i.failures)::integer, null, null, null, s.payment_instrument_type, null
  from inv i
  left join cma.subscription s on s.tenant_id = p_tenant_id and s.connection_id = i.connection_id and s.source_id = i.subscription_source_id
  where i.placed_at is not null and i.subscription_source_id is not null
$$;

-- ---------------------------------------------------------------------------------------------
-- S1: the structure
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_t   uuid := (select t.id from cma.tenant t where t.status = 'active' order by t.slug collate "C" limit 1);
  ok    boolean;
  d     text;
  c1    text;
  c2    text;
  n_tab integer;
begin
  c1 := pg_temp.v9zr_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''jobs.defer_web_statements'', ''0'')', v_t));
  c2 := pg_temp.v9zr_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''jobs.defer_max_in_a_row'', ''61'')', v_t));
  select count(*) into n_tab from pg_class c
  where c.relnamespace = 'cma'::regnamespace and c.relkind = 'r'
    and c.relname in ('setting', 'tenant_setting', 'market', 'market_alias', 'business_hours', 'business_holiday', 'telephony_tag', 'app_user_external_id')
    and c.reloptions @> array['autovacuum_analyze_threshold=10', 'autovacuum_analyze_scale_factor=0'];
  ok := (select a.applied_at >= b.applied_at from cma.schema_migration a, cma.schema_migration b where a.version = '0009zr' and b.version = '0009zq')
    and (select p.prosecdef and pg_get_userbyid(p.proowner) = 'cma_owner' from pg_proc p where p.oid = 'cma.web_busy(text)'::regprocedure)
    and not has_function_privilege('public', 'cma.web_busy(text)', 'execute') and has_function_privilege('cma_app', 'cma.web_busy(text)', 'execute')
    and not has_function_privilege('public', 'cma.job_gate_of(text)', 'execute') and has_function_privilege('cma_app', 'cma.job_gate_of(text)', 'execute')
    and not has_function_privilege('public', 'cma.speed_to_lead_rows_of(uuid,timestamptz,timestamptz,boolean)', 'execute')
    and has_function_privilege('cma_app', 'cma.speed_to_lead_rows_of(uuid,timestamptz,timestamptz,boolean)', 'execute')
    and not has_function_privilege('public', 'cma.renewal_outcomes_of(uuid,uuid[],text[])', 'execute')
    and has_function_privilege('cma_app', 'cma.renewal_outcomes_of(uuid,uuid[],text[])', 'execute')
    and (select s.default_value from cma.setting s where s.key = 'jobs.defer_web_statements') = '2'
    and (select s.default_value from cma.setting s where s.key = 'jobs.defer_max_in_a_row') = '5'
    and (select s.default_value from cma.setting s where s.key = 'customers.refresh_minutes') = '10'
    and c1 = 'CMA04' and c2 = 'CMA04'
    and (select 'jit=off' = any (p.proconfig) from pg_proc p where p.oid = 'cma.refresh_follow_up_of(uuid,boolean)'::regprocedure)
    and (select 'jit=off' = any (p.proconfig) from pg_proc p where p.oid = 'cma.renewal_outcomes_of(uuid,uuid[],text[])'::regprocedure)
    and n_tab = 8;
  d := format('order, web_busy definer of cma_owner, grants, settings 2/5/10, range refusals %s/%s, jit off, %s small tables', c1, c2, n_tab);
  perform pg_temp.v9zr_row(1, 'S1', 'structure', ok, d);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- G1 to G4: the gate, on throwaway run rows (rolled back)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t        record;
  v_t      uuid;
  v_sched  uuid;
  v_person uuid;
  g        jsonb;
  ok1      boolean := true;
  d1       text := '';
  n_t      integer := 0;
  c_gate   text;
  c_busy   text;
  v_busy   integer;
  r        jsonb := '{}';
  v_job    text := 'refresh_data_quality';
begin
  -- G1: every active tenant's four jobs answer go or a known reason, as the tenant's scheduler
  for t in select x.id from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    v_sched := (select u.id from cma.app_user_external_id e join cma.app_user u on u.tenant_id = e.tenant_id and u.id = e.user_id
                where e.tenant_id = t.id and e.system = 'scheduler' and e.external_id = 'scheduler' and u.status = 'active');
    continue when v_sched is null;
    n_t := n_t + 1;
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', v_sched::text, true);
    foreach v_job in array array['refresh_follow_up', 'refresh_data_quality', 'refresh_active_customers', 'flash_snapshot'] loop
      g := cma.job_gate_of(v_job);
      if not ((g ->> 'go')::boolean or g ->> 'reason' in ('nothing_to_read', 'backoff', 'deferred')) then
        ok1 := false;
        d1 := d1 || format(' %s answered %s;', v_job, g);
      end if;
    end loop;
    v_busy := cma.web_busy('refresh_data_quality');
    if v_busy is not null and v_busy < 0 then ok1 := false; end if;
    -- a person without the permission is refused by both
    v_person := (select u.id from cma.app_user u where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person'
                   and not cma.has_permission(u.id, 'data_quality.refresh') order by u.id limit 1);
    if v_person is not null then
      perform set_config('app.user_id', v_person::text, true);
      c_gate := pg_temp.v9zr_code('select cma.job_gate_of(''refresh_data_quality'')');
      c_busy := pg_temp.v9zr_code('select cma.web_busy(''refresh_data_quality'')');
      if c_gate <> 'CMA06' or c_busy <> 'CMA06' then
        ok1 := false;
        d1 := d1 || format(' a person: gate %s, web_busy %s;', c_gate, c_busy);
      end if;
    end if;
    v_t := coalesce(v_t, t.id);
  end loop;
  perform pg_temp.v9zr_row(10, 'G1', 'every tenant''s gate answers; a person refused', ok1 and n_t > 0,
                           format('%s tenants, web statements now %s%s', n_t, coalesce(v_busy::text, 'unknown (no pg_read_all_stats)'), d1));

  -- G2 and G3 on the first tenant with a scheduler, job refresh_data_quality (never nothing_to_read); deferral off
  v_sched := (select u.id from cma.app_user_external_id e join cma.app_user u on u.tenant_id = e.tenant_id and u.id = e.user_id
              where e.tenant_id = v_t and e.system = 'scheduler' and e.external_id = 'scheduler' and u.status = 'active');
  begin
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_sched::text, true);
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'jobs.defer_max_in_a_row', '0')
    on conflict (tenant_id, key) do update set value = excluded.value;
    delete from cma.sync_run x where x.tenant_id = v_t and x.job = 'refresh_data_quality' and x.connection_id is null;
    -- a) one timeout 3 minutes ago: waits 5
    insert into cma.sync_run (tenant_id, job, started_at, finished_at, status, counts, error)
    values (v_t, 'refresh_data_quality', now() - interval '210 seconds', now() - interval '3 minutes', 'failed', '{}', '57014');
    r := r || jsonb_build_object('a', cma.job_gate_of('refresh_data_quality'));
    -- b) the same 6 minutes ago: goes (a finished run row is never updated: written again)
    delete from cma.sync_run x where x.tenant_id = v_t and x.job = 'refresh_data_quality' and x.connection_id is null;
    insert into cma.sync_run (tenant_id, job, started_at, finished_at, status, counts, error)
    values (v_t, 'refresh_data_quality', now() - interval '390 seconds', now() - interval '6 minutes', 'failed', '{}', '57014');
    r := r || jsonb_build_object('b', cma.job_gate_of('refresh_data_quality'));
    -- c) a second timeout, 8 minutes ago (the first now 9): waits 10
    delete from cma.sync_run x where x.tenant_id = v_t and x.job = 'refresh_data_quality' and x.connection_id is null;
    insert into cma.sync_run (tenant_id, job, started_at, finished_at, status, counts, error)
    values (v_t, 'refresh_data_quality', now() - interval '9 minutes 30 seconds', now() - interval '9 minutes', 'failed', '{}', '57014'),
           (v_t, 'refresh_data_quality', now() - interval '8 minutes 30 seconds', now() - interval '8 minutes', 'failed', '{}', '57014');
    r := r || jsonb_build_object('c', cma.job_gate_of('refresh_data_quality'));
    -- d) a gated run after them: still two in a row
    insert into cma.sync_run (tenant_id, job, started_at, finished_at, status, counts)
    values (v_t, 'refresh_data_quality', now() - interval '2 minutes', now() - interval '2 minutes', 'succeeded', '{"skipped": 1, "backoff_wait": 1}');
    r := r || jsonb_build_object('d', cma.job_gate_of('refresh_data_quality'));
    -- e) a succeeded run after them: the wait is gone
    insert into cma.sync_run (tenant_id, job, started_at, finished_at, status, counts)
    values (v_t, 'refresh_data_quality', now() - interval '1 minute', now() - interval '50 seconds', 'succeeded', '{"rows": 1}');
    r := r || jsonb_build_object('e', cma.job_gate_of('refresh_data_quality'));
    -- f) six timeouts in a row, the newest 50 minutes ago: waits 60 at most
    delete from cma.sync_run x where x.tenant_id = v_t and x.job = 'refresh_data_quality' and x.connection_id is null;
    insert into cma.sync_run (tenant_id, job, started_at, finished_at, status, counts, error)
    select v_t, 'refresh_data_quality', now() - make_interval(mins => 50 + 60 * i) - interval '30 seconds', now() - make_interval(mins => 50 + 60 * i),
           'failed', '{}', '57014'
    from generate_series(0, 5) i;
    r := r || jsonb_build_object('f', cma.job_gate_of('refresh_data_quality'));
    -- G3: three deferrals, newest first, after an ordinary run: counted 3 (deferral off, so the gate goes)
    delete from cma.sync_run x where x.tenant_id = v_t and x.job = 'refresh_data_quality' and x.connection_id is null;
    insert into cma.sync_run (tenant_id, job, started_at, finished_at, status, counts)
    values (v_t, 'refresh_data_quality', now() - interval '4 minutes', now() - interval '4 minutes', 'succeeded', '{"rows": 1}'),
           (v_t, 'refresh_data_quality', now() - interval '3 minutes', now() - interval '3 minutes', 'succeeded', '{"skipped": 1, "defer_wait": 1}'),
           (v_t, 'refresh_data_quality', now() - interval '2 minutes', now() - interval '2 minutes', 'succeeded', '{"skipped": 1, "defer_wait": 1}'),
           (v_t, 'refresh_data_quality', now() - interval '1 minute', now() - interval '1 minute', 'succeeded', '{"skipped": 1, "defer_wait": 1}');
    r := r || jsonb_build_object('g3', cma.job_gate_of('refresh_data_quality'));
    -- G4: the tenant's CRM connections (and those without a kind) inactive: the follow-up has nothing to read
    update cma.integration_connection ic set status = 'inactive' where ic.tenant_id = v_t and (ic.kind = 'crm' or ic.kind is null);
    r := r || jsonb_build_object('g4fu', cma.job_gate_of('refresh_follow_up'), 'g4dq', cma.job_gate_of('refresh_data_quality'),
                                 'g4fl', cma.job_gate_of('flash_snapshot'));
    raise exception using errcode = 'V9ZR0', message = 'rolled back';
  exception when sqlstate 'V9ZR0' then
    null;
  end;
  perform pg_temp.v9zr_row(11, 'G2', 'the timeout''s backoff',
    r -> 'a' ->> 'reason' = 'backoff' and (r -> 'a' ->> 'wait_minutes')::integer = 5
    and (r -> 'b' ->> 'go')::boolean and (r -> 'b' ->> 'timeouts_in_a_row')::integer = 1
    and r -> 'c' ->> 'reason' = 'backoff' and (r -> 'c' ->> 'wait_minutes')::integer = 10
    and r -> 'd' ->> 'reason' = 'backoff' and (r -> 'd' ->> 'timeouts_in_a_row')::integer = 2
    and (r -> 'e' ->> 'go')::boolean and (r -> 'e' ->> 'timeouts_in_a_row')::integer = 0
    and r -> 'f' ->> 'reason' = 'backoff' and (r -> 'f' ->> 'wait_minutes')::integer = 60,
    format('a %s/%s, b %s, c %s/%s, d %s/%s, e %s, f %s/%s', r -> 'a' ->> 'reason', r -> 'a' ->> 'wait_minutes', r -> 'b' ->> 'go',
           r -> 'c' ->> 'reason', r -> 'c' ->> 'wait_minutes', r -> 'd' ->> 'reason', r -> 'd' ->> 'timeouts_in_a_row', r -> 'e' ->> 'go',
           r -> 'f' ->> 'reason', r -> 'f' ->> 'wait_minutes'));
  perform pg_temp.v9zr_row(12, 'G3', 'the deferrals in a row',
    (r -> 'g3' ->> 'go')::boolean and (r -> 'g3' ->> 'deferrals_in_a_row')::integer = 3,
    format('%s deferrals counted', r -> 'g3' ->> 'deferrals_in_a_row'));
  perform pg_temp.v9zr_row(13, 'G4', 'nothing to read',
    r -> 'g4fu' ->> 'reason' = 'nothing_to_read' and coalesce(r -> 'g4dq' ->> 'reason', 'go') <> 'nothing_to_read'
    and coalesce(r -> 'g4fl' ->> 'reason', 'go') <> 'nothing_to_read',
    format('follow-up %s, data quality %s, Flash %s', coalesce(r -> 'g4fu' ->> 'reason', 'go'), coalesce(r -> 'g4dq' ->> 'reason', 'go'),
           coalesce(r -> 'g4fl' ->> 'reason', 'go')));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- F1 to F4: the incremental renewal outcomes against 210's whole computation (rolled back)
-- ---------------------------------------------------------------------------------------------
create or replace function pg_temp.v9zr_outcome_diff(p_tenant_id uuid)
returns integer
language sql
as $$
  select ((select count(*) from (
             select x.connection_id, x.subscription_source_id, x.renewal_key, x.cycle_index, x.renewal_source_id, x.first_attempt_at,
                    x.outcome, x.attempts, x.recovered_at, x.days_to_recover, x.error_code, x.instrument_type,
                    x.payment_method_changed_before_recovery
             from cma.renewal_outcome x where x.tenant_id = p_tenant_id
             except all
             select * from pg_temp.v9zr_ro_210(p_tenant_id)) a)
        + (select count(*) from (
             select * from pg_temp.v9zr_ro_210(p_tenant_id)
             except all
             select x.connection_id, x.subscription_source_id, x.renewal_key, x.cycle_index, x.renewal_source_id, x.first_attempt_at,
                    x.outcome, x.attempts, x.recovered_at, x.days_to_recover, x.error_code, x.instrument_type,
                    x.payment_method_changed_before_recovery
             from cma.renewal_outcome x where x.tenant_id = p_tenant_id) b))::integer
$$;

do $$
declare
  v_t   uuid;
  s     record;
  r0    jsonb;
  r1    jsonb;
  r2    jsonb;
  r3    jsonb;
  d0    integer;
  d1    integer;
  d2    integer;
  d3    integer;
  n     integer := 0;
  v_sub record;
begin
  v_t := (select t.id from cma.tenant t where t.status = 'active' and coalesce(cma.flash_source_set_up_of(t.id, 'subscriptions'), false)
          order by t.slug collate "C" limit 1);
  if v_t is null then
    perform pg_temp.v9zr_row(20, 'F1', 'forced refresh equals 210', true, 'no tenant with subscriptions set up: nothing to compare');
    perform pg_temp.v9zr_row(21, 'F2', 'new events: incremental, equal', true, 'no tenant with subscriptions set up');
    perform pg_temp.v9zr_row(22, 'F3', 'a subscription row: in scope, equal', true, 'no tenant with subscriptions set up');
    perform pg_temp.v9zr_row(23, 'F4', 'a billing event: whole, equal', true, 'no tenant with subscriptions set up');
    return;
  end if;
  begin
    perform set_config('app.tenant_id', v_t::text, true);
    r0 := cma.subscription_facts_refresh_of(v_t, true);
    -- provoked: one stored outcome removed, a deliberate difference the comparison must see (its detail then says 1)
    if current_setting('verify.provoke')::boolean then
      delete from cma.renewal_outcome x
      where x.ctid = (select y.ctid from cma.renewal_outcome y where y.tenant_id = v_t order by y.connection_id, y.subscription_source_id collate "C", y.renewal_key collate "C" limit 1);
    end if;
    d0 := pg_temp.v9zr_outcome_diff(v_t);
    -- F2: three subscriptions get new events, written now
    for v_sub in select x.connection_id, x.source_id, row_number() over (order by x.connection_id, x.source_id collate "C") as k
                 from cma.subscription x where x.tenant_id = v_t and x.source_deleted_at is null
                 order by x.connection_id, x.source_id collate "C" limit 3 loop
      insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, cycle_index, error_code)
      select v_t, v_sub.connection_id, 'v9zr', 'v9zr-' || v_sub.k || '-' || e.n, v_sub.source_id, e.kind, now() - make_interval(mins => 60 - e.n), 9000 + v_sub.k::integer, e.err
      from (values (1, case when v_sub.k = 2 then 'renew_failed' else 'renewed' end, case when v_sub.k = 2 then 'card_declined' end),
                   (2, 'renewed', null::text)) e(n, kind, err)
      where v_sub.k = 2 or e.n = 1;
      n := n + 1;
    end loop;
    r1 := cma.subscription_facts_refresh_of(v_t, false, now() + interval '20 minutes');
    d1 := pg_temp.v9zr_outcome_diff(v_t);
    -- F3: a fourth subscription's row written (its instrument type)
    update cma.subscription x set payment_instrument_type = case when x.payment_instrument_type = 'card' then 'paypal' else 'card' end, synced_at = now()
    where x.id = (select y.id from cma.subscription y where y.tenant_id = v_t and y.source_deleted_at is null
                  order by y.connection_id, y.source_id collate "C" offset 3 limit 1);
    r2 := cma.subscription_facts_refresh_of(v_t, false, now() + interval '40 minutes');
    d2 := pg_temp.v9zr_outcome_diff(v_t);
    -- F4: a billing event written: the whole set next time (56 minutes: before the hourly whole computation is due)
    insert into cma.billing_event (tenant_id, connection_id, source_system, source_id, kind, occurred_at)
    select v_t, x.connection_id, 'v9zr', 'v9zr-billing-1', 'chargeback', now()
    from cma.subscription x where x.tenant_id = v_t order by x.connection_id, x.source_id collate "C" limit 1;
    r3 := cma.subscription_facts_refresh_of(v_t, false, now() + interval '56 minutes');
    d3 := pg_temp.v9zr_outcome_diff(v_t);
    raise exception using errcode = 'V9ZR0', message = 'rolled back';
  exception when sqlstate 'V9ZR0' then
    null;
  end;
  perform pg_temp.v9zr_row(20, 'F1', 'forced refresh equals 210', d0 = 0 and (r0 ->> 'outcomes_whole')::boolean,
                           format('%s rows differ, %s outcome rows', d0, r0 ->> 'outcome_rows'));
  perform pg_temp.v9zr_row(21, 'F2', 'new events: incremental, equal',
                           d1 = 0 and not (r1 ->> 'outcomes_whole')::boolean and (r1 ->> 'outcomes_scope')::integer >= n,
                           format('%s rows differ, whole %s, scope %s subscriptions (%s written)', d1, r1 ->> 'outcomes_whole',
                                  r1 ->> 'outcomes_scope', n));
  perform pg_temp.v9zr_row(22, 'F3', 'a subscription row: in scope, equal',
                           d2 = 0 and not (r2 ->> 'outcomes_whole')::boolean and (r2 ->> 'outcomes_scope')::integer >= 1,
                           format('%s rows differ, whole %s, scope %s', d2, r2 ->> 'outcomes_whole', r2 ->> 'outcomes_scope'));
  perform pg_temp.v9zr_row(23, 'F4', 'a billing event: whole, equal', d3 = 0 and (r3 ->> 'outcomes_whole')::boolean,
                           format('%s rows differ, whole %s', d3, r3 ->> 'outcomes_whole'));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- L1, L2: speed to lead and the open leads against 234's definitions (read only)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t      record;
  v_from timestamptz;
  v_to   timestamptz;
  n1     integer := 0;
  n2     integer := 0;
  rows1  integer := 0;
  rows2  integer := 0;
  x      integer;
begin
  for t in select y.id, y.timezone from cma.tenant y where y.status = 'active' order by y.slug collate "C" loop
    perform set_config('app.tenant_id', t.id::text, true);
    v_from := (date_trunc('month', (now() at time zone t.timezone)) - interval '1 month') at time zone t.timezone;
    v_to := date_trunc('month', (now() at time zone t.timezone)) at time zone t.timezone;
    -- provoked: 234's side without its first deal, a deliberate difference the comparison must see
    select count(*) into x from (select * from cma.speed_to_lead_of(t.id, null, null)
                                 except all
                                 select * from pg_temp.v9zr_stl_234(t.id, null, null) z
                                 where not current_setting('verify.provoke')::boolean
                                    or z.deal_id <> (select min(w.deal_id::text)::uuid from pg_temp.v9zr_stl_234(t.id, null, null) w)) a;
    n1 := n1 + x;
    select count(*) into x from (select * from pg_temp.v9zr_stl_234(t.id, null, null) except all select * from cma.speed_to_lead_of(t.id, null, null)) a;
    n1 := n1 + x;
    select count(*) into x from (select * from cma.speed_to_lead_of(t.id, v_from, v_to) except all select * from pg_temp.v9zr_stl_234(t.id, v_from, v_to)) a;
    n1 := n1 + x;
    select count(*) into x from (select * from pg_temp.v9zr_stl_234(t.id, v_from, v_to) except all select * from cma.speed_to_lead_of(t.id, v_from, v_to)) a;
    n1 := n1 + x;
    rows1 := rows1 + (select count(*) from cma.speed_to_lead_of(t.id, null, null));
    select count(*) into x from (select * from cma.open_leads_of(t.id) except all select * from pg_temp.v9zr_ol_234(t.id)) a;
    n2 := n2 + x;
    select count(*) into x from (select * from pg_temp.v9zr_ol_234(t.id) except all select * from cma.open_leads_of(t.id)) a;
    n2 := n2 + x;
    rows2 := rows2 + (select count(*) from cma.open_leads_of(t.id));
  end loop;
  perform pg_temp.v9zr_row(30, 'L1', 'speed to lead equals 234', n1 = 0, format('%s rows differ over %s lead deals', n1, rows1));
  perform pg_temp.v9zr_row(31, 'L2', 'the open leads equal 234', n2 = 0, format('%s rows differ over %s open leads', n2, rows2));
end
$$;

drop function if exists pg_temp.v9zr_outcome_diff(uuid);
drop function if exists pg_temp.v9zr_ro_210(uuid);
drop function if exists pg_temp.v9zr_ol_234(uuid);
drop function if exists pg_temp.v9zr_stl_234(uuid, timestamptz, timestamptz);
drop function if exists pg_temp.v9zr_code(text);
drop function if exists pg_temp.v9zr_row(integer, text, text, boolean, text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009zr
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009zr where result <> 'OK') then 'FAIL'
                  when (select count(*) from pg_temp.verify_0009zr where result = 'OK') <> 11 then 'FAIL'
                  else 'PASS 0009zr' end,
             format('237_verify_jobs_off_the_vcpu: %s OK, %s FAIL', (select count(*) from pg_temp.verify_0009zr where result = 'OK'),
                    (select count(*) from pg_temp.verify_0009zr where result <> 'OK'))) x
order by ord;
reset role;
