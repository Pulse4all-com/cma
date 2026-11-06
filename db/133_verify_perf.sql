-- =============================================================================================
-- 133_verify_perf.sql: verifies addition 0008zr, the fastest Workspace (night N06, 5 November 2026)
-- =============================================================================================
-- Universal: no seed is assumed. Block S checks structure, privileges and settings; block E proves every rewritten read
-- answers exactly what it did, on the database it runs in (the volume fixture locally, the seeds, dev's and prod's own
-- data): the previous definition of each function is kept here, as a temporary function, and the two are compared row
-- for row (and in order, where the function orders) for every active tenant, as the application acting as the tenant's
-- first person holding tenant.configure (a tenant without one reads skip); block A works on a throwaway tenant inside a
-- subtransaction that is always rolled back, so nothing stays and the script runs in dev and in prod. Every check writes
-- one row, ok or FAIL, and the last row is the verdict, because Cloud SQL Studio shows no notices. Run as your own IAM
-- login after 132_perf.sql, dev first, then prod. The previous definitions are those of 118 (connection_held_kinds_of),
-- 78 (system_health_runs), 60 (missed_callbacks_of), 76 (calls_of, inbound_calls_of), 74 (intake_per_day_of), 72
-- (open_tickets_of, open_tasks_of) and 122 (flash_findings_of), copied verbatim with pg_temp.old_ in place of cma.
-- Since 144_held_kinds_restore.sql (0008zx) E1 compares with 118's definition (0008zl), the latest before 0008zr: until
-- 0008zx this script kept 70's (0008n), the one 132 had been rebuilt from, so the two agreed and the kinds 132 lost
-- (reviews, assets, subscriptions) went unseen; on 0008zr alone E1 reads FAIL wherever a connection holds those rows.
-- 145_verify_held_kinds_restore.sql is 0008zx's own check.
-- Block E's data-quality check refreshes the current tenant's stored result inside its subtransaction and compares it
-- with the live computation; the subtransaction is rolled back, so the stored result is as it was.
-- Expected verdict, in dev and in prod: "0008zr verified | 133_verify_perf: <n> ok, 0 FAIL, <k> skip" (the skips are
-- tenants without a person holding tenant.configure); provoked (verify.provoke true at the top): every E row reads FAIL
-- (the previous definition's first row is dropped before the comparison, or the row says the set was empty), every S
-- and A row reads FAIL, and the verdict PROVOKED, NOT A PASS.
--   S  the addition row after 0008zq; the two tables' columns, row-level security, the policy, the grants, no audit
--      trigger; the setting with its range; the permission on every scheduler role; the job in sync_run's list and
--      cma.job_permission_of; the plan settings on the six set functions; cma.data_quality no longer stable
--   E  connection_held_kinds_of for every connection; system_health_runs; missed_callbacks_of; calls_of and
--      inbound_calls_of over the last 92 days; intake_per_day_of over the last 92 days; open_tickets_of and open_tasks_of
--      in order; the stored findings against the live computation
--   A  a throwaway tenant: the refresh skips while fresh and refreshes when the setting allows; the fallback computes
--      once on demand; data_quality() and data_quality_rows() carry the result; an agent is refused; inbound_now()'s
--      shape and permission; the setting's range; the job's run row as the scheduler and as a manager
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

drop table if exists pg_temp.verify_0008zr;
create temporary table verify_0008zr (ord integer, check_name text, result text, detail text);
-- blocks E and A write their rows while acting as the application
grant select, insert on pg_temp.verify_0008zr to cma_app;

-- The previous definitions, verbatim, under pg_temp.old_
-- connection_held_kinds_of as 118 (0008zl) defined it
create function pg_temp.old_connection_held_kinds_of(p_tenant_id uuid, p_connection_id uuid)
returns text[]
language sql stable
as $$
  select array_remove(array[
    case when exists (select 1 from cma.crm_record x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_contact x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_pipeline x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_form x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_call_outcome x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id
                        and x.entity not in ('device', 'device_component'))
           or exists (select 1 from cma.writeback_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox_channel x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_email_rule x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.email_message x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.email_thread x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_task x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_task_status x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_task_type x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'crm' end,
    case when exists (select 1 from cma.telephony_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_tag x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_number x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'telephony' end,
    case when exists (select 1 from cma.commerce_store x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.commerce_customer x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.commerce_order x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'commerce' end,
    case when exists (select 1 from cma.review_channel x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.review x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'reviews' end,
    case when exists (select 1 from cma.device x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id
                        and x.entity in ('device', 'device_component'))
         then 'assets' end,
    case when exists (select 1 from cma.subscription x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.subscription_event x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'subscriptions' end], null)
$$;

-- system_health_runs as 78 defined it
create function pg_temp.old_system_health_runs()
returns table(
  job text, connection_id uuid,
  last_started_at timestamptz, last_finished_at timestamptz, last_status text, last_error text, last_counts jsonb,
  last_succeeded_at timestamptz, last_failed_at timestamptz, last_failed_error text,
  runs_24h integer, failed_24h integer)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    with runs as (
      select r.id, r.job, r.connection_id, r.started_at, r.finished_at, r.status, r.error, r.counts
      from cma.sync_run r
      where r.tenant_id = cma.current_tenant_id() and r.started_at > now() - interval '30 days'),
    last as (
      select distinct on (r.job, r.connection_id) r.job, r.connection_id, r.started_at, r.finished_at, r.status, r.error, r.counts
      from runs r order by r.job, r.connection_id, r.started_at desc, r.id desc),
    ok as (
      select r.job, r.connection_id, max(r.finished_at) as at from runs r where r.status = 'succeeded' group by 1, 2),
    bad as (
      select distinct on (r.job, r.connection_id) r.job, r.connection_id, r.finished_at, r.error
      from runs r where r.status = 'failed' order by r.job, r.connection_id, r.finished_at desc, r.id desc),
    day as (
      select r.job, r.connection_id, count(*)::integer as runs, (count(*) filter (where r.status = 'failed'))::integer as failed
      from runs r where r.started_at > now() - interval '24 hours' group by 1, 2)
    select l.job, l.connection_id, l.started_at, l.finished_at, l.status, l.error, l.counts,
           ok.at, bad.finished_at, bad.error, coalesce(day.runs, 0), coalesce(day.failed, 0)
    from last l
    left join ok  on ok.job = l.job  and ok.connection_id  is not distinct from l.connection_id
    left join bad on bad.job = l.job and bad.connection_id is not distinct from l.connection_id
    left join day on day.job = l.job and day.connection_id is not distinct from l.connection_id
    order by l.job, l.connection_id;
end
$$;

-- missed_callbacks_of as 60 defined it
create function pg_temp.old_missed_callbacks_of(p_tenant_id uuid)
returns table (
  call_id                   uuid,
  connection_id             uuid,
  source_id                 text,
  line_ref                  text,
  line_name                 text,
  market                    text,
  reason_code               text,
  reason_label              text,
  started_at                timestamptz,
  missed_count              integer,
  waiting_seconds           integer,
  waiting_business_seconds  integer
)
language sql stable
as $$
  with s as (
    select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback
    from cma.tenant t where t.id = p_tenant_id
  ),
  m as materialized (
    select x.*, tc.counterpart_hash as h
    from s
    cross join lateral cma.inbound_calls_of(p_tenant_id, now() - make_interval(days => s.lookback), null) x
    join cma.telephony_call tc on tc.tenant_id = p_tenant_id and tc.id = x.call_id
    where x.reason_code is not null and tc.counterpart_hash is not null
  ),
  l as (
    select distinct on (m.h) m.*
    from m where m.needs_callback
    order by m.h, m.started_at desc, m.call_id desc
  ),
  -- a callback: any outbound call to the caller, connected or not, or an answered inbound call from
  -- them, on any telephony connection of the tenant; the latest one after the listed call (which takes
  -- the caller off the list) and the latest one before it (from which missed_count counts)
  k as (
    select l.*, cb.next_callback_at, cb.last_callback_at
    from l
    cross join lateral (
      select max(o.started_at) filter (where o.started_at > l.started_at) as next_callback_at,
             max(o.started_at) filter (where o.started_at < l.started_at) as last_callback_at
      from cma.telephony_call o
      where o.tenant_id = p_tenant_id and o.counterpart_hash = l.h and o.source_deleted_at is null
        and (o.direction = 'outbound' or (o.direction = 'inbound' and o.answered_at is not null))
    ) cb
  )
  select k.call_id, k.connection_id, k.source_id, k.line_ref, k.line_name, k.market, k.reason_code, k.reason_label,
         k.started_at,
         (select count(*)::integer from m where m.h = k.h and (k.last_callback_at is null or m.started_at > k.last_callback_at)),
         greatest(0, floor(extract(epoch from now() - k.started_at)))::integer,
         cma.business_seconds_of(p_tenant_id, nullif(k.market, 'unknown'), k.started_at, now())
  from k
  where k.next_callback_at is null
  order by k.started_at, k.source_id
$$;

-- calls_of as 76 defined it
create function pg_temp.old_calls_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz, p_market text, p_line text)
returns table(connection_id uuid, source_system text, direction text, line_key text, line_name text, market text, zone text,
              started_at timestamptz, business_date date, week_start date, local_time time, user_ref text,
              is_answered_inbound boolean, is_connected_outbound boolean, is_conversation boolean, talk_seconds integer,
              tag_refs text[], is_tagged boolean)
language sql stable
as $$
  with s as (
    select t.timezone as tenant_zone,
           greatest(0, cma.setting_of(t.id, 'telephony.connected_min_seconds')::integer) as connected_min
    from cma.tenant t where t.id = p_tenant_id
  ),
  c as (
    select tc.connection_id, tc.source_system, tc.direction, tc.source_id, tc.started_at, tc.answered_at, tc.talk_seconds,
           tc.user_ref, tc.connection_id::text || ':' || coalesce(tc.number_ref, '') as lk,
           coalesce(n.name, tc.number_ref) as ln, coalesce(m.code, 'unknown') as mk, coalesce(m.time_zone, s.tenant_zone) as z,
           s.connected_min
    from cma.telephony_call tc
    cross join s
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = p_tenant_id
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and coalesce(n.is_counted, true)
      and tc.started_at >= coalesce(p_from, '-infinity'::timestamptz)
      and tc.started_at < coalesce(p_to, 'infinity'::timestamptz)
  )
  select c.connection_id, c.source_system, c.direction, c.lk, c.ln, c.mk, c.z, c.started_at,
         (c.started_at at time zone c.z)::date,
         date_trunc('week', (c.started_at at time zone c.z)::date::timestamp)::date,
         (c.started_at at time zone c.z)::time,
         c.user_ref,
         k.answered_in, k.connected_out, k.answered_in or k.connected_out,
         c.talk_seconds,
         coalesce(tg.refs, '{}'::text[]), tg.refs is not null
  from c
  cross join lateral (
    select c.direction = 'inbound' and c.answered_at is not null as answered_in,
           c.direction = 'outbound' and coalesce(c.talk_seconds >= c.connected_min, false) as connected_out) k
  left join lateral (
    select array_agg(ct.tag_ref order by ct.tag_ref) as refs
    from cma.telephony_call_tag ct
    where ct.tenant_id = p_tenant_id and ct.connection_id = c.connection_id and ct.call_source_id = c.source_id
      and ct.untagged_at is null) tg on true
  where (p_market is null or c.mk = p_market)
    and (p_line is null or c.lk = p_line)
$$;

-- inbound_calls_of as 76 defined it
create function pg_temp.old_inbound_calls_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table(call_id uuid, connection_id uuid, source_system text, source_id text, line_key text, line_ref text, line_name text,
              market text, zone text, started_at timestamptz, business_date date, local_hour integer, is_answered boolean,
              is_waiting boolean, answer_seconds numeric, reason_code text, reason_label text, needs_callback boolean,
              in_service_level boolean)
language sql stable
as $$
  with s as (
    select t.timezone as tenant_zone,
           greatest(0, cma.setting_of(t.id, 'telephony.waiting_max_minutes')::integer) as waiting_max
    from cma.tenant t where t.id = p_tenant_id
  ),
  c as (
    select tc.*, n.name as n_name, m.code as m_code, coalesce(m.time_zone, s.tenant_zone) as z,
           (tc.answered_at is null and tc.ended_at is null
            and tc.started_at >= now() - make_interval(mins => s.waiting_max)) as waiting
    from cma.telephony_call tc
    cross join s
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = p_tenant_id
      and tc.direction = 'inbound'
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and coalesce(n.is_counted, true)
      and tc.started_at >= coalesce(p_from, '-infinity'::timestamptz)
      and tc.started_at < coalesce(p_to, 'infinity'::timestamptz)
  )
  select c.id, c.connection_id, c.source_system, c.source_id,
         c.connection_id::text || ':' || coalesce(c.number_ref, ''),
         c.number_ref, coalesce(c.n_name, c.number_ref), coalesce(c.m_code, 'unknown'), c.z,
         c.started_at, (c.started_at at time zone c.z)::date, extract(hour from c.started_at at time zone c.z)::integer,
         c.answered_at is not null,
         c.waiting,
         case when c.answered_at is not null then greatest(0, extract(epoch from c.answered_at - c.started_at)) end,
         case when r.unanswered then r.code end,
         case when r.unanswered then coalesce(mr.label, r.code) end,
         case when r.unanswered then coalesce(mr.needs_callback, true) end,
         c.answered_at is not null or (r.unanswered and coalesce(mr.counts_in_service_level, true))
  from c
  cross join lateral (select c.answered_at is null and not c.waiting as unanswered,
                             coalesce(nullif(btrim(c.missed_reason), ''), 'unknown') as code) r
  left join cma.telephony_missed_reason mr
    on mr.tenant_id = c.tenant_id and mr.source_system = c.source_system and mr.code = r.code
$$;

-- intake_per_day_of as 74 defined it
create function pg_temp.old_intake_per_day_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
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
    where fs.tenant_id = p_tenant_id and f.is_counted and cma.form_is_lead(f.lead_condition, fs.kept_values)
      and fs.submitted_at >= s.from_at and fs.submitted_at < s.to_at
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

-- open_tickets_of as 72 defined it
create function pg_temp.old_open_tickets_of(p_tenant_id uuid)
returns setof cma.open_ticket_row
language sql stable
as $$
  with s as (
    select greatest(1, cma.setting_of(p_tenant_id, 'tickets.sla_minutes')::integer) as sla_default,
           least(100, greatest(0, cma.setting_of(p_tenant_id, 'tickets.sla_warning_pct')::integer)) as warn_pct
  ),
  k as (
    select r.id, r.connection_id, r.source_system, r.source_id, r.pipeline_id, coalesce(p.label, r.pipeline_id) as pipeline_label,
           r.stage_id, coalesce(st.label, r.stage_id) as stage_label, r.owner_ref, r.source_created_at,
           coalesce(p.sla_minutes, s.sla_default) as sla, s.warn_pct, rm.code as market
    from cma.crm_record r
    cross join s
    left join cma.connection_pipeline p
      on p.tenant_id = r.tenant_id and p.connection_id = r.connection_id and p.record_type = r.record_type and p.source_pipeline_id = r.pipeline_id
    left join cma.connection_stage st
      on st.tenant_id = r.tenant_id and st.connection_id = r.connection_id and st.record_type = r.record_type
     and st.source_pipeline_id = r.pipeline_id and st.source_stage_id = r.stage_id
    cross join lateral cma.record_market_of(r.tenant_id, r.connection_id, r.market, r.contact_source_id) rm
    where r.tenant_id = p_tenant_id and r.record_type = 'ticket' and r.source_deleted_at is null
      and not coalesce(r.is_closed, false) and coalesce(p.is_counted, true)
  ),
  m as (
    select k.*, cma.business_seconds_of(p_tenant_id, nullif(k.market, 'unknown'), k.source_created_at, now()) as open_s from k
  )
  select p_tenant_id, m.id, m.connection_id, m.source_id, m.pipeline_id, m.pipeline_label, m.stage_id, m.stage_label,
         cma.owner_user_of(p_tenant_id, m.source_system, m.owner_ref), m.owner_ref, m.market, m.source_created_at,
         m.open_s, m.sla,
         case when m.open_s is null then 'no_hours'
              when m.open_s >= m.sla * 60 then 'breached'
              when m.open_s * 100 >= m.sla * 60 * m.warn_pct then 'at_risk'
              else 'ok' end,
         case when m.open_s is null then null else m.sla - floor(m.open_s / 60.0)::integer end
  from m
  order by case when m.open_s is null then 1 else 0 end, (m.sla * 60 - m.open_s), m.source_created_at, m.source_id
$$;

-- open_tasks_of as 72 defined it
create function pg_temp.old_open_tasks_of(p_tenant_id uuid)
returns setof cma.open_task_row
language sql stable
as $$
  with s as (
    select t.timezone as zone, (now() at time zone t.timezone)::date as today from cma.tenant t where t.id = p_tenant_id
  )
  select p_tenant_id, k.id, k.connection_id, k.source_id, k.type_ref, coalesce(y.label, k.type_ref), coalesce(y.is_callback, false),
         k.priority_ref, k.status_ref, coalesce(st.label, k.status_ref),
         cma.owner_user_of(p_tenant_id, k.source_system, k.owner_ref), k.owner_ref,
         cma.task_market_of(p_tenant_id, k.connection_id, k.deal_source_id, k.ticket_source_id, k.contact_source_id),
         k.due_at,
         case when k.due_at is null then 'none'
              when (k.due_at at time zone s.zone)::date < s.today then 'overdue'
              when (k.due_at at time zone s.zone)::date = s.today then 'today'
              else 'later' end,
         case when k.deal_source_id is not null then 'deal' when k.ticket_source_id is not null then 'ticket' end,
         coalesce(k.deal_source_id, k.ticket_source_id),
         k.source_created_at
  from cma.crm_task k
  cross join s
  left join cma.connection_task_status st
    on st.tenant_id = k.tenant_id and st.connection_id = k.connection_id and st.status_ref = k.status_ref
  left join cma.connection_task_type y
    on y.tenant_id = k.tenant_id and y.connection_id = k.connection_id and y.type_ref = k.type_ref
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and not coalesce(st.is_done, false) and coalesce(y.is_counted, true)
  order by k.due_at nulls last, k.source_created_at, k.source_id
$$;

-- flash_findings_of as 122 defined it
create function pg_temp.old_flash_findings_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text, market text, fix_in text, fix_adapter text)
language sql stable
as $$
  with f as materialized (
    select q.* from cma.data_quality_of(p_tenant_id) q
  ), c as materialized (
    select ic.id, ic.adapter, coalesce(ic.kind, (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1]) as kind, ic.status
    from cma.integration_connection ic where ic.tenant_id = p_tenant_id
  ), ka as materialized (
    select distinct on (c.kind) c.kind, c.adapter from c where c.status = 'active' and c.kind is not null order by c.kind, c.id
  ), st as materialized (
    select x.connection_id, x.market from cma.commerce_store x where x.tenant_id = p_tenant_id
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  )
  select f.check_key, f.connection_id, f.object_type, f.object_id, f.value,
         coalesce(case f.object_type
                    when 'commerce_customer' then st.market
                    when 'subscription' then sm.market
                    when 'market' then f.object_id
                    -- a record's own market, read for the findings of its type only
                    when 'device' then (select d.market from cma.device d
                                        where d.tenant_id = p_tenant_id and d.connection_id = f.connection_id and d.source_id = f.object_id)
                    when 'contact' then (select cma.market_code_of(p_tenant_id, k.country) from cma.crm_contact k
                                         where k.tenant_id = p_tenant_id and k.connection_id = f.connection_id and k.source_id = f.object_id)
                    when 'form' then (select cf.market from cma.connection_form cf
                                      where cf.tenant_id = p_tenant_id and cf.connection_id = f.connection_id and cf.source_form_id = f.object_id)
                    when 'review_channel' then (select ch.market from cma.review_channel ch
                                                where ch.tenant_id = p_tenant_id and ch.connection_id = f.connection_id and ch.source_id = f.object_id)
                    -- 0007d's market rule (cma.record_market_of) for a deal's or ticket's finding
                    when 'deal' then (select coalesce(cma.market_code_of(p_tenant_id, r.market), cma.market_code_of(p_tenant_id, rk.country))
                                      from cma.crm_record r
                                      left join cma.crm_contact rk
                                        on rk.tenant_id = r.tenant_id and rk.connection_id = r.connection_id and rk.source_id = r.contact_source_id
                                      where r.tenant_id = p_tenant_id and r.connection_id = f.connection_id and r.record_type = 'deal'
                                        and r.source_id = f.object_id)
                    when 'ticket' then (select coalesce(cma.market_code_of(p_tenant_id, r.market), cma.market_code_of(p_tenant_id, rk.country))
                                        from cma.crm_record r
                                        left join cma.crm_contact rk
                                          on rk.tenant_id = r.tenant_id and rk.connection_id = r.connection_id and rk.source_id = r.contact_source_id
                                        where r.tenant_id = p_tenant_id and r.connection_id = f.connection_id and r.record_type = 'ticket'
                                          and r.source_id = f.object_id) end, 'unknown'),
         x.fix_in,
         case when x.fix_in = 'cma' then null when c1.kind = x.fix_in then c1.adapter else ka.adapter end
  from f
  cross join lateral (select cma.data_quality_fix_in(f.check_key, f.value) as fix_in) x
  left join c c1 on c1.id = f.connection_id
  left join ka on ka.kind = x.fix_in
  left join st on f.object_type = 'commerce_customer' and st.connection_id = f.connection_id
  left join sm on f.object_type = 'subscription' and sm.connection_id = f.connection_id
$$;

-- Two set-returning calls compared: null when they answer the same rows (the same multiset; the same sequence when
-- p_ordered), else what differs; in provoke mode the old side loses its first row, so the comparison must fail
create or replace function pg_temp.v0008zr_diff(p_new text, p_old text, p_ordered boolean)
returns text
language plpgsql
as $$
declare
  v_old text := p_old;
  v_n_new bigint; v_n_old bigint; v_only_new bigint; v_only_old bigint; v_same boolean;
begin
  if current_setting('verify.provoke')::boolean then
    v_old := format('select * from (%s) z offset 1', p_old);
  end if;
  execute format('select count(*) from (%s) a', p_new) into v_n_new;
  execute format('select count(*) from (%s) a', v_old) into v_n_old;
  if current_setting('verify.provoke')::boolean and v_n_new = 0 then
    return 'provoked, but the set is empty: nothing to differ (FAIL by the switch)';
  end if;
  if p_ordered then
    execute format('select (select string_agg(a::text, ''|'' order by a.o) from (select row_number() over () as o, t from (%s) t) a) is not distinct from
                           (select string_agg(b::text, ''|'' order by b.o) from (select row_number() over () as o, t from (%s) t) b)', p_new, v_old) into v_same;
  else
    v_same := true;
  end if;
  execute format('select count(*) from ((%s) except all (%s)) a', p_new, v_old) into v_only_new;
  execute format('select count(*) from ((%s) except all (%s)) a', v_old, p_new) into v_only_old;
  if v_only_new = 0 and v_only_old = 0 and v_same then
    return null;
  end if;
  return format('%s rows now against %s before: %s only now, %s only before%s', v_n_new, v_n_old, v_only_new, v_only_old,
                case when not v_same and v_only_new = 0 and v_only_old = 0 then ', the same rows in another order' else '' end);
end
$$;

-- A check row kept as four texts, for the blocks whose subtransaction is rolled back (their rows must outlive it)
create or replace function pg_temp.v0008zr_row(p_ord integer, p_name text, p_result text, p_detail text)
returns text[] language sql immutable as $$ select array[p_ord::text, p_name, p_result, p_detail] $$;

-- The tenant's first active person (the oldest) holding a permission, as the time scripts pick it
create or replace function pg_temp.v0008zr_user(p_tenant uuid, p_perm text)
returns uuid
language sql
as $$
  select u.id from cma.app_user u
  where u.tenant_id = p_tenant and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, p_perm)
  order by u.created_at, u.id limit 1
$$;

-- ---------------------------------------------------------------------------------------------
-- S. Structure, privileges, settings
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_ok boolean; v_txt text; v_n integer;
  function_settings text[] := array['calls_of', 'calls_figures_of', 'inbound_calls_of', 'intake_per_day_of', 'open_tasks_of', 'open_tickets_of'];
  f text;
begin
  v_ok := exists (select 1 from cma.schema_migration where version = '0008zr');
  insert into verify_0008zr values (1, 'S1 addition 0008zr recorded', case when v_ok and not v_provoke then 'ok' else 'FAIL' end,
    case when v_ok then 'cma.schema_migration holds 0008zr' else 'no 0008zr row' end);

  select string_agg(column_name, ',' order by ordinal_position) into v_txt from information_schema.columns
  where table_schema = 'cma' and table_name = 'data_quality_finding';
  v_ok := v_txt = 'tenant_id,ord,check_key,connection_id,object_type,object_id,value,market,fix_in,fix_adapter'
          and (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
               where table_schema = 'cma' and table_name = 'data_quality_snapshot') = 'tenant_id,computed_at,duration_ms,findings';
  insert into verify_0008zr values (2, 'S2 the two tables with their columns', case when v_ok and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_txt, 'no table'));

  v_ok := (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'cma' and c.relname in ('data_quality_finding', 'data_quality_snapshot') and c.relrowsecurity) = 2
          and (select count(*) from pg_policies where schemaname = 'cma' and tablename in ('data_quality_finding', 'data_quality_snapshot') and policyname = 'tenant_app') = 2
          and (select count(*) from information_schema.role_table_grants where table_schema = 'cma' and table_name in ('data_quality_finding', 'data_quality_snapshot')
               and grantee = 'cma_app' and privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')) = 8
          and not exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid where c.relname in ('data_quality_finding', 'data_quality_snapshot') and t.tgname = 'audit')
          and not exists (select 1 from information_schema.role_table_grants where table_schema = 'cma' and table_name in ('data_quality_finding', 'data_quality_snapshot') and grantee = 'cma_readonly');
  insert into verify_0008zr values (3, 'S3 row-level security, the tenant policy, the application''s grants, no audit trigger, nothing for the readers',
    case when v_ok and not v_provoke then 'ok' else 'FAIL' end, 'as cma.setup_tenant_table() gives, the audit trigger dropped');

  v_ok := exists (select 1 from cma.setting where key = 'data_quality.refresh_minutes' and value_type = 'integer' and default_value = '5')
          and exists (select 1 from cma.permission where key = 'data_quality.refresh')
          and not exists (select 1 from cma.app_role r where r.key = 'scheduler'
                          and not exists (select 1 from cma.role_permission rp where rp.tenant_id = r.tenant_id and rp.role_id = r.id and rp.permission_key = 'data_quality.refresh'))
          and not exists (select 1 from cma.role_permission rp where rp.permission_key = 'data_quality.refresh'
                          and exists (select 1 from cma.app_role r where r.tenant_id = rp.tenant_id and r.id = rp.role_id and r.key <> 'scheduler'))
          and cma.job_permission_of('refresh_data_quality') = 'data_quality.refresh';
  insert into verify_0008zr values (4, 'S4 the setting (integer, 5), the permission on every scheduler role and no other, the job''s permission',
    case when v_ok and not v_provoke then 'ok' else 'FAIL' end, 'data_quality.refresh_minutes, data_quality.refresh, refresh_data_quality');

  v_n := 0;
  foreach f in array function_settings loop
    if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'cma' and p.proname = f and 'jit=off' = any (p.proconfig)) then
      v_n := v_n + 1;
    end if;
  end loop;
  v_ok := v_n = 6
          and (select provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'cma' and p.proname = 'data_quality') = 'v'
          and (select provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'cma' and p.proname = 'data_quality_rows') = 'v';
  insert into verify_0008zr values (5, 'S5 jit off on the six set functions; data_quality and data_quality_rows volatile (the fallback writes)',
    case when v_ok and not v_provoke then 'ok' else 'FAIL' end, format('%s of 6 functions carry jit=off', v_n));

  v_ok := not exists (select 1 from information_schema.role_routine_grants g
                      where g.specific_schema = 'cma' and g.grantee = 'PUBLIC'
                        and g.routine_name in ('inbound_now', 'refresh_data_quality', 'refresh_data_quality_of', 'data_quality_snapshot_of', 'data_quality_computed_at',
                                               'flash_findings_compute_of', 'market_codes_of', 'check_data_quality_setting'))
          and (select count(distinct g.routine_name) from information_schema.role_routine_grants g
               where g.specific_schema = 'cma' and g.grantee = 'cma_app'
                 and g.routine_name in ('inbound_now', 'refresh_data_quality', 'refresh_data_quality_of', 'data_quality_snapshot_of', 'data_quality_computed_at',
                                        'flash_findings_compute_of', 'market_codes_of', 'data_quality', 'data_quality_rows', 'flash_findings_of')) = 10;
  insert into verify_0008zr values (6, 'S6 the new functions executable by the application only', case when v_ok and not v_provoke then 'ok' else 'FAIL' end,
    'revoked from public, granted to cma_app');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- E. Every rewritten read answers what it did, per active tenant
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  t record; c record;
  v_user uuid; v_diff text; v_n integer; v_ord integer := 100; v_from date; v_err text;
  v_dq_before timestamptz;
  v_checks text[]; v_sql_new text[]; v_sql_old text[]; v_ordered boolean[]; i integer;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', '', true);
    v_user := pg_temp.v0008zr_user(t.id, 'tenant.configure');
    if v_user is null then
      v_ord := v_ord + 1;
      insert into verify_0008zr values (v_ord, 'E ' || t.slug, 'skip', 'no active person holds tenant.configure: nothing compared');
      continue;
    end if;
    v_from := cma.tenant_today_of(t.id) - 91;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_user::text, true);

    -- E1 connection_held_kinds_of for every connection, in one comparison (a row per connection)
    v_checks := array['E1 connection_held_kinds_of for every connection'];
    v_sql_new := array[format('select c.id, cma.connection_held_kinds_of(c.tenant_id, c.id) from cma.integration_connection c where c.tenant_id = %L', t.id)];
    v_sql_old := array[format('select c.id, pg_temp.old_connection_held_kinds_of(c.tenant_id, c.id) from cma.integration_connection c where c.tenant_id = %L', t.id)];
    v_ordered := array[false];
    -- E2 system_health_runs (ordered)
    v_checks := array_append(v_checks, 'E2 system_health_runs'); v_sql_new := array_append(v_sql_new, 'select * from cma.system_health_runs()');
    v_sql_old := array_append(v_sql_old, 'select * from pg_temp.old_system_health_runs()'); v_ordered := array_append(v_ordered, true);
    -- E3 missed_callbacks_of (ordered)
    v_checks := array_append(v_checks, 'E3 missed_callbacks_of'); v_sql_new := array_append(v_sql_new, format('select * from cma.missed_callbacks_of(%L)', t.id));
    v_sql_old := array_append(v_sql_old, format('select * from pg_temp.old_missed_callbacks_of(%L)', t.id)); v_ordered := array_append(v_ordered, true);
    -- E4 calls_of over the last 92 days, E5 inbound_calls_of likewise (unordered)
    v_checks := array_append(v_checks, 'E4 calls_of over the last 92 days');
    v_sql_new := array_append(v_sql_new, format('select * from cma.calls_of(%L, %L::date::timestamptz, null, null, null)', t.id, v_from));
    v_sql_old := array_append(v_sql_old, format('select * from pg_temp.old_calls_of(%L, %L::date::timestamptz, null, null, null)', t.id, v_from)); v_ordered := array_append(v_ordered, false);
    v_checks := array_append(v_checks, 'E5 inbound_calls_of over the last 92 days');
    v_sql_new := array_append(v_sql_new, format('select * from cma.inbound_calls_of(%L, %L::date::timestamptz, null)', t.id, v_from));
    v_sql_old := array_append(v_sql_old, format('select * from pg_temp.old_inbound_calls_of(%L, %L::date::timestamptz, null)', t.id, v_from)); v_ordered := array_append(v_ordered, false);
    -- E6 intake_per_day_of over the last 92 days (unordered)
    v_checks := array_append(v_checks, 'E6 intake_per_day_of over the last 92 days');
    v_sql_new := array_append(v_sql_new, format('select * from cma.intake_per_day_of(%L, %L::date::timestamptz, null)', t.id, v_from));
    v_sql_old := array_append(v_sql_old, format('select * from pg_temp.old_intake_per_day_of(%L, %L::date::timestamptz, null)', t.id, v_from)); v_ordered := array_append(v_ordered, false);
    -- E7 open_tickets_of, E8 open_tasks_of (ordered)
    v_checks := array_append(v_checks, 'E7 open_tickets_of'); v_sql_new := array_append(v_sql_new, format('select * from cma.open_tickets_of(%L)', t.id));
    v_sql_old := array_append(v_sql_old, format('select * from pg_temp.old_open_tickets_of(%L)', t.id)); v_ordered := array_append(v_ordered, true);
    v_checks := array_append(v_checks, 'E8 open_tasks_of'); v_sql_new := array_append(v_sql_new, format('select * from cma.open_tasks_of(%L)', t.id));
    v_sql_old := array_append(v_sql_old, format('select * from pg_temp.old_open_tasks_of(%L)', t.id)); v_ordered := array_append(v_ordered, true);

    for i in 1 .. cardinality(v_checks) loop
      v_ord := v_ord + 1;
      begin
        v_diff := pg_temp.v0008zr_diff(v_sql_new[i], v_sql_old[i], v_ordered[i]);
        execute format('select count(*) from (%s) a', v_sql_new[i]) into v_n;
        insert into verify_0008zr values (v_ord, v_checks[i] || ' (' || t.slug || ')', case when v_diff is null then 'ok' else 'FAIL' end,
          coalesce(v_diff, format('%s row(s), the same%s', v_n, case when v_ordered[i] then ' in the same order' else '' end)));
      exception when others then
        insert into verify_0008zr values (v_ord, v_checks[i] || ' (' || t.slug || ')', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 120));
      end;
    end loop;

    -- E9 the stored findings against the live computation: refreshed inside a subtransaction that is rolled back; the
    -- row's values kept in variables, so they outlive the rollback
    v_ord := v_ord + 1;
    v_diff := null; v_n := null; v_dq_before := null; v_err := null;
    begin
      select s.computed_at into v_dq_before from cma.data_quality_snapshot s where s.tenant_id = t.id;
      delete from cma.data_quality_snapshot s where s.tenant_id = t.id;
      perform cma.refresh_data_quality_of(t.id, true);
      v_diff := pg_temp.v0008zr_diff(format('select * from cma.flash_findings_of(%L)', t.id), format('select * from pg_temp.old_flash_findings_of(%L)', t.id), false);
      select s.findings into v_n from cma.data_quality_snapshot s where s.tenant_id = t.id;
      raise exception using errcode = 'CMAOK';
    exception
      when sqlstate 'CMAOK' then null;
      when others then v_err := 'error ' || sqlstate || ': ' || left(sqlerrm, 120);
    end;
    insert into verify_0008zr values (v_ord, 'E9 the stored findings equal the live computation (' || t.slug || ')',
      case when v_err is null and v_diff is null then 'ok' else 'FAIL' end,
      coalesce(v_err, v_diff, format('%s finding(s) stored, the same as computed live; the stored result of %s is kept (rolled back)', v_n, coalesce(v_dq_before::text, 'never'))));
  end loop;
  perform set_config('role', 'cma_owner', true);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- A. Behaviour on a throwaway tenant, rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t uuid; v_analyst uuid; v_agent uuid; v_sched uuid; v_crm uuid;
  r jsonb; v_ok boolean; v_state text; v_at timestamptz; v_run uuid; n integer;
  rows_ text[] := '{}';
begin
  begin
    v_t := cma.create_tenant('verify-0008zr', 'Verify 0008zr', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-0008zr-analyst@example.invalid', 'analyst') returning id into v_analyst;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_analyst, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'analytics';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-0008zr-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_agent, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'agent';
    select u.id into v_sched from cma.app_user u where u.tenant_id = v_t and u.email = 'scheduler@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t, 'verifycrm', 'CRM', 'portal-zr', 'crm') returning id into v_crm;
    insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country) values (v_t, v_crm, 'verifycrm', 'c-1', 'XX');

    -- A1 the fallback: data_quality() on a tenant without a result computes it once; computed_at set; the finding there
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_analyst::text, true);
    v_ok := not exists (select 1 from cma.data_quality_snapshot s where s.tenant_id = v_t);
    select count(*) into n from cma.data_quality() q where q.check_key = 'market_not_in_catalog' and q.total = 1;
    v_at := cma.data_quality_computed_at();
    v_ok := v_ok and n = 1 and v_at is not null and exists (select 1 from cma.data_quality_snapshot s where s.tenant_id = v_t and s.findings >= 1)
            and (cma.data_quality_rows('market_not_in_catalog') ->> 'computed_at')::timestamptz = v_at
            and (select count(*) from cma.flash_findings_of(v_t) f where f.check_key = 'market_not_in_catalog') = 1;
    rows_ := rows_ || pg_temp.v0008zr_row(301, 'A1 a tenant without a stored result computes it once on demand; the pages read it with Refreshed at',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end, format('market_not_in_catalog counted %s, computed at %s', n, v_at));

    -- A2 the refresh skips while fresh, refreshes once the result is older than the setting
    r := cma.refresh_data_quality_of(v_t);
    v_ok := (r ->> 'refreshed')::boolean = false and r ->> 'reason' = 'fresh';
    perform set_config('role', 'cma_owner', true);
    update cma.data_quality_snapshot s set computed_at = now() - interval '6 minutes' where s.tenant_id = v_t;
    perform set_config('role', 'cma_app', true);
    r := cma.refresh_data_quality_of(v_t);
    v_ok := v_ok and (r ->> 'refreshed')::boolean = true and (r ->> 'rows')::integer >= 1
            and (select s.computed_at from cma.data_quality_snapshot s where s.tenant_id = v_t) > now() - interval '1 minute';
    r := cma.refresh_data_quality_of(v_t, true);
    v_ok := v_ok and (r ->> 'refreshed')::boolean = false and r ->> 'reason' = 'present';
    rows_ := rows_ || pg_temp.v0008zr_row(302, 'A2 the refresh skips a fresh result (reason fresh), refreshes an old one, and a waiting refresh finds it present',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end, 'data_quality.refresh_minutes 5: skipped at 0 minutes, refreshed at 6');

    -- A3 the setting's range
    perform set_config('app.user_id', (select u.id::text from cma.app_user u where u.tenant_id = v_t and u.email = 'scheduler@system.invalid'), true);
    perform set_config('role', 'cma_owner', true);
    v_state := 'none';
    begin
      insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'data_quality.refresh_minutes', '0');
    exception when others then v_state := sqlstate;
    end;
    v_ok := v_state = 'CMA04';
    v_state := 'none';
    begin
      insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'data_quality.refresh_minutes', '1441');
    exception when others then v_state := sqlstate;
    end;
    v_ok := v_ok and v_state = 'CMA04';
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'data_quality.refresh_minutes', '1');
    v_ok := v_ok and cma.setting_of(v_t, 'data_quality.refresh_minutes') = '1';
    rows_ := rows_ || pg_temp.v0008zr_row(303, 'A3 data_quality.refresh_minutes takes 1 to 1440 (0 and 1441 refused with CMA04)',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end, 'set to 1 for the tenant');

    -- A4 the job's run row: the scheduler's user may, a person may not; the refresh entry needs the permission
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_sched::text, true);
    v_run := cma.job_run_start('refresh_data_quality');
    r := cma.refresh_data_quality();
    perform cma.job_run_finish(v_run, 'succeeded', jsonb_build_object('rows', coalesce((r ->> 'rows')::integer, 0)));
    v_ok := exists (select 1 from cma.sync_run x where x.tenant_id = v_t and x.id = v_run and x.job = 'refresh_data_quality' and x.connection_id is null and x.status = 'succeeded');
    perform set_config('app.user_id', v_analyst::text, true);
    v_state := 'none';
    begin
      perform cma.refresh_data_quality();
    exception when others then v_state := sqlstate;
    end;
    v_ok := v_ok and v_state = 'CMA06';
    v_state := 'none';
    begin
      perform cma.job_run_start('refresh_data_quality');
    exception when others then v_state := sqlstate;
    end;
    v_ok := v_ok and v_state = 'CMA06';
    rows_ := rows_ || pg_temp.v0008zr_row(304, 'A4 the scheduler''s user writes the job''s run row and refreshes; an analyst is refused (CMA06) on both',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end, 'job refresh_data_quality without a connection');

    -- A5 an agent is refused the readers; inbound_now needs monitoring.live and answers the three parts
    perform set_config('app.user_id', v_agent::text, true);
    v_state := 'none';
    begin
      perform count(*) from cma.data_quality();
    exception when others then v_state := sqlstate;
    end;
    v_ok := v_state = 'CMA06';
    v_state := 'none';
    begin
      perform cma.data_quality_computed_at();
    exception when others then v_state := sqlstate;
    end;
    v_ok := v_ok and v_state = 'CMA06';
    v_state := 'none';
    begin
      perform cma.inbound_now();
    exception when others then v_state := sqlstate;
    end;
    v_ok := v_ok and v_state = 'CMA06';
    perform set_config('role', 'cma_owner', true);
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_agent, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'supervisor';
    perform set_config('role', 'cma_app', true);
    r := cma.inbound_now();
    v_ok := v_ok and r ? 'today' and r ? 'callbacks' and r ? 'summary' and jsonb_typeof(r -> 'callbacks') = 'array'
            and (r -> 'summary' ->> 'listed')::integer = jsonb_array_length(r -> 'callbacks') and (r -> 'today' ->> 'offered')::integer = 0;
    rows_ := rows_ || pg_temp.v0008zr_row(305, 'A5 an agent is refused data_quality, data_quality_computed_at and inbound_now (CMA06); a supervisor reads inbound_now with today, callbacks and summary',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end, 'the summary''s listed equals the callbacks listed');

    raise exception using errcode = 'CMAOK';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || pg_temp.v0008zr_row(399, 'A block ended early', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 160));
  end;
  insert into verify_0008zr (ord, check_name, result, detail)
  select rows_[4 * i - 3]::integer, rows_[4 * i - 2], rows_[4 * i - 1], rows_[4 * i] from generate_series(1, cardinality(rows_) / 4) i;
end
$$;

drop function if exists pg_temp.v0008zr_diff(text, text, boolean);
drop function if exists pg_temp.v0008zr_user(uuid, text);
drop function if exists pg_temp.v0008zr_row(integer, text, text, text);
drop function if exists pg_temp.old_connection_held_kinds_of;
drop function if exists pg_temp.old_system_health_runs;
drop function if exists pg_temp.old_missed_callbacks_of;
drop function if exists pg_temp.old_calls_of;
drop function if exists pg_temp.old_inbound_calls_of;
drop function if exists pg_temp.old_intake_per_day_of;
drop function if exists pg_temp.old_open_tickets_of;
drop function if exists pg_temp.old_open_tasks_of;
drop function if exists pg_temp.old_flash_findings_of;

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0008zr
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0008zr where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0008zr where result = 'ok') then 'FAIL'
                  else '0008zr verified' end,
             format('133_verify_perf: %s ok, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0008zr where result = 'ok'),
                    (select count(*) from pg_temp.verify_0008zr where result = 'FAIL'), (select count(*) from pg_temp.verify_0008zr where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0008zr;
reset role;
