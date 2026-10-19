-- =============================================================================================
-- docs/perf-2026-10-19/diagnose.sql: why the first-orders and email reports are slow in prod
-- =============================================================================================
-- Part 1 of the report speed brief (19 October 2026). Measured in prod in October as cma_app:
-- first_orders_report 26.8 s, first_orders_amounts 20.1 s, first_orders_list 21.1 s (each above the
-- web's 15 s statement_timeout), email_report 7.0 s, Email per agent 18 to 20 s. This script collects
-- what the fix needs, for tenant pulse4all-subscriptions, the period 1 to 31 October 2026, per day,
-- without filters (the pages' defaults).
--
-- Run: Studio, cma-prod-pg, as your own IAM login, the whole file in one Run. It reads for about four
-- minutes: the report functions as they are, then four EXPLAIN ANALYZE runs (two as the owner, the
-- same two as cma_app). A statement that takes longer than 180 seconds is stopped and its line says
-- so; every section catches its own error and writes it as a line, so the Run always ends with the
-- output.
--
-- Read only: nothing in schema cma changes. It writes one temporary table and five temporary functions
-- in this session's own pg_temp; they are gone when the session ends.
--
-- Output: the last result, one row per line (n, line), in sections:
--   1  the tenant, the server and its planner settings
--   2  row counts of the report tables: the whole tenant, and the read window of the period
--   3  the data's shape: fan-out per contact, per phone hash, per thread, per customer
--   4  the report settings as the functions read them
--   5  table statistics: live and dead rows, last analyze and vacuum, size
--   6  the indexes on those tables: definition, size, scans since the statistics reset
--   7  timings of the report functions as they are (owner role; two also as cma_app, with RLS)
--   8  EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT TEXT) of cma.first_orders_of's body, inlined
--   9  EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT TEXT) of cma.email_report_of's body, inlined
--  10  section 8 again as cma_app (row-level security on, as the application reads)
--  11  section 9 again as cma_app
-- No customer data: counts, codes, index definitions, settings, timings and plan text. The plans'
-- literals are the tenant id, the period's bounds and the tenant's settings; their conditions name
-- columns, never values. Plan nodes that never executed are left out, with a line counting them.
--
-- Inlined: the bodies are the functions' own text from db/84_first_orders.sql (0008u) and
-- db/82_email_reports.sql (0008t), each parameter replaced by its literal and each setting read
-- resolved to its value, so the planner shows the whole query instead of one Function Scan.
-- first_orders_of runs over the bounds the reads give it: the day before the period to two days after,
-- in the tenant's zone. email_report_of runs email_figures_of for the period and for the previous span
-- like for like (cma.forms_previous_of at the Run's start), with email_of, email_openings_of,
-- email_closes_of and email_threads_counted_of inlined in each. The helpers the bodies call per row
-- (record_market_of, crm_call_connected_of, market_code_of, business_seconds_of, setting_codes) stay
-- calls, as in the functions, so their cost shows as Function Scan or SubPlan lines with their loops.
-- JIT is off for every plan, as first_orders_of and email_of set it.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
set statement_timeout = '180s';

-- The tenant, the period and the instant every "now" of this Run uses
select set_config('perf.tenant', coalesce((select t.id::text from cma.tenant t where t.slug = 'pulse4all-subscriptions'), ''), false) as tenant,
       set_config('perf.from', '2026-10-01', false) as period_from,
       set_config('perf.to', '2026-10-31', false) as period_to,
       set_config('perf.now', now()::text, false) as run_at;

drop table if exists pg_temp.perf_diag;
create temp table perf_diag (n integer generated always as identity, line text);

-- A section: a heading, then the lines a query gives (one text column), or the error as a line
create or replace function pg_temp.perf_lines(p_title text, p_sql text)
returns void
language plpgsql
as $f$
declare
  v_line text;
begin
  insert into perf_diag (line) values (''), ('=== ' || p_title);
  for v_line in execute p_sql loop
    insert into perf_diag (line) values (v_line);
  end loop;
exception when others then
  insert into perf_diag (line) values ('ERROR ' || sqlstate || ': ' || left(sqlerrm, 200));
end
$f$;

-- A timing: the wall time of a query that answers one text (what it found), as the owner or as cma_app
-- (row-level security on, the tenant set, as the application reads); a timeout or an error as a line
create or replace function pg_temp.perf_time(p_title text, p_sql text, p_as_app boolean default false)
returns void
language plpgsql
as $f$
declare
  v_t0   timestamptz;
  v_out  text;
  v_ms   bigint;
begin
  if p_as_app then
    perform set_config('app.tenant_id', current_setting('perf.tenant'), true);
    execute 'set local role cma_app';
  end if;
  v_t0 := clock_timestamp();
  execute p_sql into v_out;
  v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000);
  if p_as_app then
    execute 'set local role cma_owner';
  end if;
  insert into perf_diag (line) values (rpad(p_title, 64) || lpad(v_ms::text, 8) || ' ms  ' || coalesce(v_out, ''));
exception when others then
  insert into perf_diag (line) values (rpad(p_title, 64) || ' ERROR ' || sqlstate || ': ' || left(sqlerrm, 160));
end
$f$;

-- A plan: EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT TEXT) of a query, JIT off (as the functions set
-- it), as the owner or as cma_app (row-level security on, the tenant set); the nodes that never
-- executed left out (with their detail lines and children), counted
create or replace function pg_temp.perf_explain(p_title text, p_sql text, p_as_app boolean default false)
returns void
language plpgsql
as $f$
declare
  v_line    text;
  v_lines   text[] := '{}';
  v_indent  integer;
  v_skip    integer;
  v_left    integer := 0;
begin
  insert into perf_diag (line) values (''), ('=== ' || p_title);
  perform set_config('jit', 'off', true);
  if p_as_app then
    perform set_config('app.tenant_id', current_setting('perf.tenant'), true);
    execute 'set local role cma_app';
  end if;
  for v_line in execute 'explain (analyze, buffers, settings, format text) ' || p_sql loop
    v_indent := length(v_line) - length(ltrim(v_line));
    if v_skip is not null and v_indent > v_skip then
      v_left := v_left + 1;
      continue;
    end if;
    v_skip := null;
    if v_line like '%(never executed)%' then
      v_skip := v_indent;
      v_left := v_left + 1;
      continue;
    end if;
    v_lines := v_lines || v_line;
  end loop;
  if p_as_app then
    execute 'set local role cma_owner';
  end if;
  insert into perf_diag (line) select x from unnest(v_lines) with ordinality u(x, i) order by i;
  insert into perf_diag (line) values ('(' || v_left || ' plan lines of nodes that never executed left out)');
exception when others then
  insert into perf_diag (line) values ('ERROR ' || sqlstate || ': ' || left(sqlerrm, 200));
end
$f$;

-- cma.first_orders_of's body (0008u) for one tenant and two bounds, the settings resolved
create or replace function pg_temp.perf_first_orders_sql(p_tenant uuid, p_from_at timestamptz, p_to_at timestamptz)
returns text
language plpgsql strict
as $f$
declare
  v_sql text := $tpl$
  with s as (
    select {{ZONE}} as tenant_zone, {{WIN}} as win, {{LEVEL_ORDER}} as level_order, {{ASSISTED}} as assisted, {{KNOWN}} as known,
           {{MATCH}} as match
  ),
  -- the won deals of the order pipelines created in the period, with their contact
  d as materialized (
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
    where r.tenant_id = {{T}} and r.record_type = 'deal' and r.source_deleted_at is null
      and r.source_created_at >= {{FROM_AT}} and r.source_created_at < {{TO_AT}}
  ),
  -- the market, the linked order and the kind
  k as materialized (
    select d.*, rm.code as market, coalesce(mk.time_zone, s.tenant_zone) as zone,
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
                             where r2.tenant_id = {{T}} and r2.connection_id = d.connection_id and r2.record_type = 'deal'
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
                             where a2.tenant_id = {{T}} and a2.connection_id = d.connection_id and a2.from_type = 'deal'
                               and a2.to_type = 'contact' and a2.to_id = d.contact and a2.removed_at is null
                               and (r2.source_created_at < d.t or (r2.source_created_at = d.t and r2.id < d.id)))
                  then 'repeat'
                when o.order_kind = 'repeat' then 'not_first'
                else 'first' end as kind
    from d
    cross join s
    cross join lateral cma.record_market_of({{T}}, d.connection_id, d.own_market, d.contact) rm
    left join cma.market mk on mk.tenant_id = {{T}} and mk.code = rm.code
    left join lateral (
      select co.id as order_id, co.source_id as order_source_id, co.order_kind, co.currency, co.total_amount as amount,
             array_remove(array[co.phone_hash, cu.phone_hash], null) as hashes
      from cma.commerce_customer cu
      join cma.commerce_order co
        on co.tenant_id = cu.tenant_id and co.connection_id = cu.connection_id and co.customer_source_id = cu.source_id
      where cu.tenant_id = {{T}} and cu.crm_connection_id = d.connection_id and cu.crm_contact_source_id = d.contact
        and not co.is_test and co.cancelled_at is null and co.source_deleted_at is null
        and co.source_created_at >= d.t - s.match and co.source_created_at <= d.t + s.match
      order by abs(extract(epoch from co.source_created_at - d.t)), co.source_created_at, co.id
      limit 1) o on true
  ),
  -- the touches of each first order in its window
  x as (
    select k.id, tt.touch, tt.at, tt.sys, tt.owner_ref
    from k
    cross join s
    cross join lateral (
      -- lead deals of the contact: primary contact
      select 'lead_deal'::text as touch, r3.source_created_at as at, r3.source_system || '_owner' as sys, r3.owner_ref
      from cma.crm_record r3
      left join cma.connection_pipeline p3
        on p3.tenant_id = r3.tenant_id and p3.connection_id = r3.connection_id and p3.record_type = r3.record_type
       and p3.source_pipeline_id = r3.pipeline_id
      where r3.tenant_id = {{T}} and r3.connection_id = k.connection_id and r3.record_type = 'deal'
        and r3.contact_source_id = k.contact and r3.source_deleted_at is null and r3.id <> k.id
        and coalesce(p3.is_counted, true) and coalesce(p3.is_lead, true) and not coalesce(p3.is_order, false)
        and r3.source_created_at >= k.t - s.win and r3.source_created_at < k.t
      union all
      -- lead deals of the contact: a current association
      select 'lead_deal', r3.source_created_at, r3.source_system || '_owner', r3.owner_ref
      from cma.crm_association a3
      join cma.crm_record r3
        on r3.tenant_id = a3.tenant_id and r3.connection_id = a3.connection_id and r3.record_type = 'deal' and r3.source_id = a3.from_id
      left join cma.connection_pipeline p3
        on p3.tenant_id = r3.tenant_id and p3.connection_id = r3.connection_id and p3.record_type = r3.record_type
       and p3.source_pipeline_id = r3.pipeline_id
      where a3.tenant_id = {{T}} and a3.connection_id = k.connection_id and a3.from_type = 'deal' and a3.to_type = 'contact'
        and a3.to_id = k.contact and a3.removed_at is null
        and r3.contact_source_id is distinct from k.contact and r3.source_deleted_at is null and r3.id <> k.id
        and coalesce(p3.is_counted, true) and coalesce(p3.is_lead, true) and not coalesce(p3.is_order, false)
        and r3.source_created_at >= k.t - s.win and r3.source_created_at < k.t
      union all
      -- calls with the contact: a conversation, else an attempt
      select case when cc.is_connected then 'conversation' else 'attempt' end, cc.effective_at, c.source_system || '_owner', c.owner_ref
      from cma.crm_association a4
      join cma.crm_call c
        on c.tenant_id = a4.tenant_id and c.connection_id = a4.connection_id and c.source_id = a4.from_id and c.source_deleted_at is null
      cross join lateral cma.crm_call_connected_of({{T}}, c.id) cc
      where a4.tenant_id = {{T}} and a4.connection_id = k.connection_id and a4.from_type = 'crm_call' and a4.to_type = 'contact'
        and a4.to_id = k.contact and a4.removed_at is null
        and cc.effective_at >= k.t - s.win and cc.effective_at < k.t
      union all
      -- agent emails to the contact: the message's own contact, its conversation's, or an engagement's association
      select 'email', em.occurred_at, em.source_system || '_owner', em.owner_ref
      from (select em1.id from cma.email_message em1
            where em1.tenant_id = {{T}} and em1.connection_id = k.connection_id and em1.contact_source_id = k.contact
            union
            select em2.id from cma.email_thread th2
            join cma.email_message em2
              on em2.tenant_id = th2.tenant_id and em2.connection_id = th2.connection_id and em2.thread_source_id = th2.source_id
            where th2.tenant_id = {{T}} and th2.connection_id = k.connection_id and th2.contact_source_id = k.contact
            union
            select em3.id from cma.crm_association a5
            join cma.email_message em3
              on em3.tenant_id = a5.tenant_id and em3.connection_id = a5.connection_id and em3.source_kind = 'crm_email'
             and em3.source_id = a5.from_id
            where a5.tenant_id = {{T}} and a5.connection_id = k.connection_id and a5.from_type = 'crm_email'
              and a5.to_type = 'contact' and a5.to_id = k.contact and a5.removed_at is null) ids
      join cma.email_message em on em.tenant_id = {{T}} and em.id = ids.id
      join cma.integration_connection ic on ic.tenant_id = em.tenant_id and ic.id = em.connection_id
      left join cma.email_thread th
        on th.tenant_id = em.tenant_id and th.connection_id = em.connection_id and th.source_id = em.thread_source_id
      where em.direction = 'out' and em.status = 'sent' and em.source_deleted_at is null
        and em.occurred_at >= k.t - s.win and em.occurred_at < k.t
        and case when em.source_kind = 'inbox_message'
                 then em.actor_kind not in ('bot', 'ai', 'system', 'integration') and not coalesce(th.is_spam, false)
                 else not (lower(coalesce(em.origin, '')) = any (cma.setting_codes(ic.settings, 'email_inbox_copy_origins')))
                      and not (lower(coalesce(em.origin, '')) = any (cma.setting_codes(ic.settings, 'email_automated_origins'))) end
      union all
      -- a CRM call from the order's phone number, any contact
      select 'phone_match', cc.effective_at, c.source_system || '_owner', c.owner_ref
      from cma.crm_call c
      cross join lateral cma.crm_call_connected_of({{T}}, c.id) cc
      where cardinality(k.hashes) > 0 and c.tenant_id = {{T}} and c.counterpart_hash = any (k.hashes)
        and c.source_deleted_at is null and cc.effective_at >= k.t - s.win and cc.effective_at < k.t
      union all
      -- a telephony call from the order's phone number, any contact
      select 'phone_match', tc.started_at, tc.source_system || '_user', tc.user_ref
      from cma.telephony_call tc
      where cardinality(k.hashes) > 0 and tc.tenant_id = {{T}} and tc.counterpart_hash = any (k.hashes)
        and tc.source_deleted_at is null and tc.started_at >= k.t - s.win and tc.started_at < k.t
    ) tt
    where k.kind = 'first'
  ),
  f as (
    select k.id,
           coalesce(bool_or(x.touch = 'lead_deal'), false) as f_lead,
           coalesce(bool_or(x.touch = 'conversation'), false) as f_conv,
           coalesce(bool_or(x.touch = 'email'), false) as f_email,
           coalesce(bool_or(x.touch = 'phone_match'), false) as f_phone,
           coalesce(bool_or(x.touch = 'attempt'), false) as f_attempt,
           coalesce((select kc.source_created_at <= k.t - s.known
                     from cma.crm_contact kc
                     where kc.tenant_id = {{T}} and kc.connection_id = k.connection_id and kc.source_id = k.contact), false) as f_known,
           min(x.at) as first_at,
           (array_agg(x.sys order by x.at desc, x.touch, x.owner_ref) filter (where x.touch = any (s.assisted)))[1] as c_sys,
           (array_agg(x.owner_ref order by x.at desc, x.touch, x.owner_ref) filter (where x.touch = any (s.assisted)))[1] as c_owner
    from k
    cross join s
    left join x on x.id = k.id
    where k.kind = 'first'
    group by k.id, k.t, k.connection_id, k.contact, s.known
  ),
  l as (
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
  select k.id, k.connection_id, k.source_system, k.source_id, k.pipeline_id, k.pipeline_label, k.contact, k.t, k.market, k.zone,
         (k.t at time zone k.zone)::date,
         date_trunc('week', (k.t at time zone k.zone)::date::timestamp)::date,
         (k.t at time zone k.zone)::time,
         k.kind, k.order_id, k.order_source_id, k.store_order_kind,
         case when k.order_id is not null then k.order_currency else k.deal_currency end,
         case when k.order_id is not null then k.order_amount else k.deal_amount end,
         cardinality(k.hashes) > 0,
         l.f_lead, l.f_conv, l.f_email, l.f_phone, l.f_attempt, l.f_known,
         l.lv,
         case when l.id is null then null when l.lv = any (l.assisted) then 'call_center' else 'self_service' end,
         l.first_at,
         case when l.first_at is not null then round((extract(epoch from k.t - l.first_at) / 86400)::numeric, 2) end,
         l.c_sys, l.c_owner,
         (select xi.user_id from cma.app_user_external_id xi
          where xi.tenant_id = {{T}} and xi.system = l.c_sys and xi.external_id = l.c_owner)
  from k
  left join l on l.id = k.id
$tpl$;
begin
  v_sql := replace(v_sql, '{{ZONE}}', quote_literal((select t.timezone from cma.tenant t where t.id = p_tenant)) || '::text');
  v_sql := replace(v_sql, '{{WIN}}', format('make_interval(days => %s)', cma.setting_of(p_tenant, 'attribution.window_days')::integer));
  v_sql := replace(v_sql, '{{LEVEL_ORDER}}', quote_literal(string_to_array(cma.setting_of(p_tenant, 'attribution.level_order'), ',')::text) || '::text[]');
  v_sql := replace(v_sql, '{{ASSISTED}}', quote_literal(coalesce(string_to_array(nullif(cma.setting_of(p_tenant, 'attribution.assisted_levels'), ''), ','),
                                                                 '{}'::text[])::text) || '::text[]');
  v_sql := replace(v_sql, '{{KNOWN}}', format('make_interval(mins => %s)', cma.setting_of(p_tenant, 'attribution.known_contact_minutes')::integer));
  v_sql := replace(v_sql, '{{MATCH}}', format('make_interval(mins => %s)', cma.setting_of(p_tenant, 'attribution.order_match_minutes')::integer));
  v_sql := replace(v_sql, '{{FROM_AT}}', quote_literal(p_from_at::text) || '::timestamptz');
  v_sql := replace(v_sql, '{{TO_AT}}', quote_literal(p_to_at::text) || '::timestamptz');
  v_sql := replace(v_sql, '{{T}}', quote_literal(p_tenant::text) || '::uuid');
  return v_sql;
end
$f$;

-- cma.email_report_of's body (0008t) for one tenant, a period per day without filters and an instant
-- (the previous span's), with email_figures_of twice and, in each, email_of, email_openings_of,
-- email_closes_of and email_threads_counted_of; the settings resolved
create or replace function pg_temp.perf_email_report_sql(p_tenant uuid, p_from date, p_to date, p_now timestamptz)
returns text
language plpgsql strict
as $f$
declare
  v_email_of text := $tpl$
  with s as (
    select {{ZONE}} as tenant_zone, {{ORD}} as ord
  ),
  e as (
    select em.connection_id, em.source_system, em.source_kind, em.source_id, em.thread_source_id, em.inbox_source_id,
           em.account_ref, em.category, em.direction, em.status, em.occurred_at, em.actor_kind, em.owner_ref,
           ib.name as ib_name, coalesce(ac.label, ac.name) as ac_name,
           lower(coalesce(em.origin, '')) = any (cma.setting_codes(c.settings, 'email_automated_origins')) as automated_origin,
           coalesce(em.contact_source_id, th.contact_source_id) as contact, th.ticket_source_id as ticket,
           coalesce(em.account_ref, th.account_ref) as m_account, coalesce(em.inbox_source_id, th.inbox_source_id) as m_inbox
    from cma.email_message em
    join cma.integration_connection c on c.tenant_id = em.tenant_id and c.id = em.connection_id
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
    where em.tenant_id = {{T}}
      and em.occurred_at >= {{F_FROM_AT}} and em.occurred_at < {{F_TO_AT}}
      and em.source_deleted_at is null
      and case when em.source_kind = 'inbox_message'
               then coalesce(ib.is_counted, true) and coalesce(ac.is_counted, true) and coalesce(ch.is_counted, true)
                    and not coalesce(th.is_spam, false)
               else not (lower(coalesce(em.origin, '')) = any (cma.setting_codes(c.settings, 'email_inbox_copy_origins'))) end
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
  cross join lateral (
    select case when e.source_kind = 'crm_email' then e.automated_origin
                else e.actor_kind in ('bot', 'ai', 'system', 'integration') end as automated) k
  cross join lateral (
    select coalesce(e.contact,
                    case when e.source_kind = 'crm_email'
                         then (select a.to_id from cma.crm_association a
                               where a.tenant_id = {{T}} and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                 and a.from_id = e.source_id and a.to_type = 'contact' and a.removed_at is null
                               order by a.first_seen_at, a.to_id
                               limit 1) end) as contact) ct
  -- the market chain of cma.email_market_of, inline: each step evaluated only when the steps before it
  -- found nothing (offset 0 keeps the chain from being copied into the zone's lookup); 83 checks it
  -- gives what cma.email_market_of gives on every row of its data
  cross join lateral (
    select
      coalesce(
      case s.ord[1]
        when 'contact' then (select cma.market_code_of({{T}}, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = {{T}} and cc.connection_id = e.connection_id and cc.source_id = ct.contact)
        when 'form' then (select cma.market_code_of({{T}}, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = {{T}} and fs.connection_id = e.connection_id and fs.contact_source_id = ct.contact
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= e.occurred_at
                            and f.is_counted and cma.market_code_of({{T}}, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then case when e.source_kind = 'crm_email'
                                then (select cma.market_code_of({{T}}, cr.market)
                                      from cma.crm_association a
                                      join cma.crm_record cr
                                        on cr.tenant_id = a.tenant_id and cr.connection_id = a.connection_id and cr.record_type = a.to_type
                                       and cr.source_id = a.to_id
                                      where a.tenant_id = {{T}} and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                        and a.from_id = e.source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null
                                        and cr.source_deleted_at is null and cma.market_code_of({{T}}, cr.market) is not null
                                      order by (a.to_type = 'ticket') desc, cr.source_created_at desc, cr.source_id
                                      limit 1)
                                else (select cma.market_code_of({{T}}, cr.market) from cma.crm_record cr
                                      where cr.tenant_id = {{T}} and cr.connection_id = e.connection_id and cr.record_type = 'ticket'
                                        and cr.source_id = e.ticket and cr.source_deleted_at is null) end
        when 'inbox' then coalesce((select cma.market_code_of({{T}}, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = {{T}} and a.connection_id = e.connection_id and a.source_account_id = e.m_account),
                                   (select cma.market_code_of({{T}}, b.market) from cma.connection_inbox b
                                    where b.tenant_id = {{T}} and b.connection_id = e.connection_id and b.source_inbox_id = e.m_inbox))
      end,
      case s.ord[2]
        when 'contact' then (select cma.market_code_of({{T}}, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = {{T}} and cc.connection_id = e.connection_id and cc.source_id = ct.contact)
        when 'form' then (select cma.market_code_of({{T}}, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = {{T}} and fs.connection_id = e.connection_id and fs.contact_source_id = ct.contact
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= e.occurred_at
                            and f.is_counted and cma.market_code_of({{T}}, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then case when e.source_kind = 'crm_email'
                                then (select cma.market_code_of({{T}}, cr.market)
                                      from cma.crm_association a
                                      join cma.crm_record cr
                                        on cr.tenant_id = a.tenant_id and cr.connection_id = a.connection_id and cr.record_type = a.to_type
                                       and cr.source_id = a.to_id
                                      where a.tenant_id = {{T}} and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                        and a.from_id = e.source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null
                                        and cr.source_deleted_at is null and cma.market_code_of({{T}}, cr.market) is not null
                                      order by (a.to_type = 'ticket') desc, cr.source_created_at desc, cr.source_id
                                      limit 1)
                                else (select cma.market_code_of({{T}}, cr.market) from cma.crm_record cr
                                      where cr.tenant_id = {{T}} and cr.connection_id = e.connection_id and cr.record_type = 'ticket'
                                        and cr.source_id = e.ticket and cr.source_deleted_at is null) end
        when 'inbox' then coalesce((select cma.market_code_of({{T}}, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = {{T}} and a.connection_id = e.connection_id and a.source_account_id = e.m_account),
                                   (select cma.market_code_of({{T}}, b.market) from cma.connection_inbox b
                                    where b.tenant_id = {{T}} and b.connection_id = e.connection_id and b.source_inbox_id = e.m_inbox))
      end,
      case s.ord[3]
        when 'contact' then (select cma.market_code_of({{T}}, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = {{T}} and cc.connection_id = e.connection_id and cc.source_id = ct.contact)
        when 'form' then (select cma.market_code_of({{T}}, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = {{T}} and fs.connection_id = e.connection_id and fs.contact_source_id = ct.contact
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= e.occurred_at
                            and f.is_counted and cma.market_code_of({{T}}, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then case when e.source_kind = 'crm_email'
                                then (select cma.market_code_of({{T}}, cr.market)
                                      from cma.crm_association a
                                      join cma.crm_record cr
                                        on cr.tenant_id = a.tenant_id and cr.connection_id = a.connection_id and cr.record_type = a.to_type
                                       and cr.source_id = a.to_id
                                      where a.tenant_id = {{T}} and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                        and a.from_id = e.source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null
                                        and cr.source_deleted_at is null and cma.market_code_of({{T}}, cr.market) is not null
                                      order by (a.to_type = 'ticket') desc, cr.source_created_at desc, cr.source_id
                                      limit 1)
                                else (select cma.market_code_of({{T}}, cr.market) from cma.crm_record cr
                                      where cr.tenant_id = {{T}} and cr.connection_id = e.connection_id and cr.record_type = 'ticket'
                                        and cr.source_id = e.ticket and cr.source_deleted_at is null) end
        when 'inbox' then coalesce((select cma.market_code_of({{T}}, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = {{T}} and a.connection_id = e.connection_id and a.source_account_id = e.m_account),
                                   (select cma.market_code_of({{T}}, b.market) from cma.connection_inbox b
                                    where b.tenant_id = {{T}} and b.connection_id = e.connection_id and b.source_inbox_id = e.m_inbox))
      end,
      case s.ord[4]
        when 'contact' then (select cma.market_code_of({{T}}, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = {{T}} and cc.connection_id = e.connection_id and cc.source_id = ct.contact)
        when 'form' then (select cma.market_code_of({{T}}, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = {{T}} and fs.connection_id = e.connection_id and fs.contact_source_id = ct.contact
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= e.occurred_at
                            and f.is_counted and cma.market_code_of({{T}}, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then case when e.source_kind = 'crm_email'
                                then (select cma.market_code_of({{T}}, cr.market)
                                      from cma.crm_association a
                                      join cma.crm_record cr
                                        on cr.tenant_id = a.tenant_id and cr.connection_id = a.connection_id and cr.record_type = a.to_type
                                       and cr.source_id = a.to_id
                                      where a.tenant_id = {{T}} and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                        and a.from_id = e.source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null
                                        and cr.source_deleted_at is null and cma.market_code_of({{T}}, cr.market) is not null
                                      order by (a.to_type = 'ticket') desc, cr.source_created_at desc, cr.source_id
                                      limit 1)
                                else (select cma.market_code_of({{T}}, cr.market) from cma.crm_record cr
                                      where cr.tenant_id = {{T}} and cr.connection_id = e.connection_id and cr.record_type = 'ticket'
                                        and cr.source_id = e.ticket and cr.source_deleted_at is null) end
        when 'inbox' then coalesce((select cma.market_code_of({{T}}, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = {{T}} and a.connection_id = e.connection_id and a.source_account_id = e.m_account),
                                   (select cma.market_code_of({{T}}, b.market) from cma.connection_inbox b
                                    where b.tenant_id = {{T}} and b.connection_id = e.connection_id and b.source_inbox_id = e.m_inbox))
      end,
      'unknown') as code
    offset 0) mk
  cross join lateral (select coalesce((select m.time_zone from cma.market m where m.tenant_id = {{T}} and m.code = mk.code),
                                      s.tenant_zone) as zone) z
$tpl$;
  v_threads text := $tpl$
  with s as (
    select {{ZONE}} as tenant_zone, {{ORD}} as ord
  )
  select th.id, th.connection_id, th.source_system, th.source_id,
         case when th.inbox_source_id is not null then th.connection_id::text || ':' || th.inbox_source_id end,
         coalesce(ib.name, th.inbox_source_id),
         case when th.account_ref is not null then th.connection_id::text || ':' || th.account_ref end,
         coalesce(ac.label, ac.name, th.account_ref),
         th.category, th.status, mk.code,
         coalesce((select m.time_zone from cma.market m where m.tenant_id = {{T}} and m.code = mk.code), s.tenant_zone)
  from cma.email_thread th
  cross join s
  left join cma.connection_inbox ib
    on ib.tenant_id = th.tenant_id and ib.connection_id = th.connection_id and ib.source_inbox_id = th.inbox_source_id
  left join cma.connection_inbox_account ac
    on ac.tenant_id = th.tenant_id and ac.connection_id = th.connection_id and ac.source_account_id = th.account_ref
  left join cma.connection_inbox_channel ch
    on ch.tenant_id = th.tenant_id and ch.connection_id = th.connection_id and ch.source_channel_id = th.channel_source_id
  -- the market chain of cma.email_market_of for a conversation, inline (as in cma.email_of)
  cross join lateral (
    select
      coalesce(
      case s.ord[1]
        when 'contact' then (select cma.market_code_of({{T}}, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = {{T}} and cc.connection_id = th.connection_id and cc.source_id = th.contact_source_id)
        when 'form' then (select cma.market_code_of({{T}}, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = {{T}} and fs.connection_id = th.connection_id and fs.contact_source_id = th.contact_source_id
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= th.source_created_at
                            and f.is_counted and cma.market_code_of({{T}}, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then (select cma.market_code_of({{T}}, cr.market) from cma.crm_record cr
                            where cr.tenant_id = {{T}} and cr.connection_id = th.connection_id and cr.record_type = 'ticket'
                              and cr.source_id = th.ticket_source_id and cr.source_deleted_at is null)
        when 'inbox' then coalesce((select cma.market_code_of({{T}}, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = {{T}} and a.connection_id = th.connection_id and a.source_account_id = th.account_ref),
                                   (select cma.market_code_of({{T}}, b.market) from cma.connection_inbox b
                                    where b.tenant_id = {{T}} and b.connection_id = th.connection_id and b.source_inbox_id = th.inbox_source_id))
      end,
      case s.ord[2]
        when 'contact' then (select cma.market_code_of({{T}}, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = {{T}} and cc.connection_id = th.connection_id and cc.source_id = th.contact_source_id)
        when 'form' then (select cma.market_code_of({{T}}, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = {{T}} and fs.connection_id = th.connection_id and fs.contact_source_id = th.contact_source_id
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= th.source_created_at
                            and f.is_counted and cma.market_code_of({{T}}, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then (select cma.market_code_of({{T}}, cr.market) from cma.crm_record cr
                            where cr.tenant_id = {{T}} and cr.connection_id = th.connection_id and cr.record_type = 'ticket'
                              and cr.source_id = th.ticket_source_id and cr.source_deleted_at is null)
        when 'inbox' then coalesce((select cma.market_code_of({{T}}, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = {{T}} and a.connection_id = th.connection_id and a.source_account_id = th.account_ref),
                                   (select cma.market_code_of({{T}}, b.market) from cma.connection_inbox b
                                    where b.tenant_id = {{T}} and b.connection_id = th.connection_id and b.source_inbox_id = th.inbox_source_id))
      end,
      case s.ord[3]
        when 'contact' then (select cma.market_code_of({{T}}, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = {{T}} and cc.connection_id = th.connection_id and cc.source_id = th.contact_source_id)
        when 'form' then (select cma.market_code_of({{T}}, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = {{T}} and fs.connection_id = th.connection_id and fs.contact_source_id = th.contact_source_id
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= th.source_created_at
                            and f.is_counted and cma.market_code_of({{T}}, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then (select cma.market_code_of({{T}}, cr.market) from cma.crm_record cr
                            where cr.tenant_id = {{T}} and cr.connection_id = th.connection_id and cr.record_type = 'ticket'
                              and cr.source_id = th.ticket_source_id and cr.source_deleted_at is null)
        when 'inbox' then coalesce((select cma.market_code_of({{T}}, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = {{T}} and a.connection_id = th.connection_id and a.source_account_id = th.account_ref),
                                   (select cma.market_code_of({{T}}, b.market) from cma.connection_inbox b
                                    where b.tenant_id = {{T}} and b.connection_id = th.connection_id and b.source_inbox_id = th.inbox_source_id))
      end,
      case s.ord[4]
        when 'contact' then (select cma.market_code_of({{T}}, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = {{T}} and cc.connection_id = th.connection_id and cc.source_id = th.contact_source_id)
        when 'form' then (select cma.market_code_of({{T}}, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = {{T}} and fs.connection_id = th.connection_id and fs.contact_source_id = th.contact_source_id
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= th.source_created_at
                            and f.is_counted and cma.market_code_of({{T}}, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then (select cma.market_code_of({{T}}, cr.market) from cma.crm_record cr
                            where cr.tenant_id = {{T}} and cr.connection_id = th.connection_id and cr.record_type = 'ticket'
                              and cr.source_id = th.ticket_source_id and cr.source_deleted_at is null)
        when 'inbox' then coalesce((select cma.market_code_of({{T}}, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = {{T}} and a.connection_id = th.connection_id and a.source_account_id = th.account_ref),
                                   (select cma.market_code_of({{T}}, b.market) from cma.connection_inbox b
                                    where b.tenant_id = {{T}} and b.connection_id = th.connection_id and b.source_inbox_id = th.inbox_source_id))
      end,
      'unknown') as code
    offset 0) mk
  where th.tenant_id = {{T}} and th.id = any ({{IDS}})
    and not th.is_spam
    and coalesce(ib.is_counted, true) and coalesce(ac.is_counted, true) and coalesce(ch.is_counted, true)
$tpl$;
  v_openings text := $tpl$
  with s as (
    select {{TARGET}} as target
  ),
  o as (
    select th.id as thread_id, 'created'::text as kind, th.source_created_at as open_at, '-infinity'::timestamptz as span_from
    from cma.email_thread th
    where th.tenant_id = {{T}} and th.source_created_at >= {{F_FROM_AT}} and th.source_created_at < {{F_TO_AT}}
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
    where ev.tenant_id = {{T}} and ev.kind = 'reopened'
      and ev.occurred_at >= {{F_FROM_AT}} and ev.occurred_at < {{F_TO_AT}}
      and pc.at is not null and pc.at >= coalesce(pc.reopened_at, '-infinity'::timestamptz)
  ),
  t as (
    select x.* from (
{{THREADS_O}}
    ) x(id, connection_id, source_system, source_id, inbox_key, inbox_name, account_key, account_name, category, status, market, zone)
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
         case when cl.at is not null then cma.business_seconds_of({{T}}, t.market, o.open_at, cl.at) end
  from o
  join t on t.id = o.thread_id
  cross join s
  left join lateral (
    select c.occurred_at as at, c.actor_kind, c.owner_ref
    from cma.email_thread_event c
    where c.tenant_id = {{T}} and c.connection_id = t.connection_id and c.thread_source_id = t.source_id
      and c.kind = 'closed' and c.occurred_at >= o.open_at
    order by c.occurred_at, c.source_id
    limit 1) cl on true
  left join lateral (
    select min(m.occurred_at) as at
    from cma.email_message m
    where m.tenant_id = {{T}} and m.connection_id = t.connection_id and m.thread_source_id = t.source_id
      and m.source_kind = 'inbox_message' and m.direction in ('in', 'forwarded') and m.source_deleted_at is null
      and m.occurred_at > o.span_from and (cl.at is null or m.occurred_at <= cl.at)) fi on true
  left join lateral (
    select m.occurred_at as at, m.owner_ref
    from cma.email_message m
    where fi.at is not null
      and m.tenant_id = {{T}} and m.connection_id = t.connection_id and m.thread_source_id = t.source_id
      and m.source_kind = 'inbox_message' and m.direction = 'out' and m.actor_kind = 'agent' and m.status <> 'failed'
      and m.source_deleted_at is null
      and m.occurred_at > fi.at and (cl.at is null or m.occurred_at <= cl.at)
    order by m.occurred_at, m.source_id
    limit 1) fr on true
  cross join lateral (
    select case when fr.at is not null then cma.business_seconds_of({{T}}, t.market, fi.at, fr.at) end as seconds) rb
$tpl$;
  v_closes text := $tpl$
  with c as (
    select ev.occurred_at, ev.actor_kind, ev.owner_ref, th.id as thread_id
    from cma.email_thread_event ev
    join cma.email_thread th
      on th.tenant_id = ev.tenant_id and th.connection_id = ev.connection_id and th.source_id = ev.thread_source_id
    where ev.tenant_id = {{T}} and ev.kind = 'closed' and ev.occurred_at >= {{F_FROM_AT}} and ev.occurred_at < {{F_TO_AT}}
  ),
  t as (
    select x.* from (
{{THREADS_C}}
    ) x(id, connection_id, source_system, source_id, inbox_key, inbox_name, account_key, account_name, category, status, market, zone)
  )
  select t.connection_id, t.source_system, t.source_id, t.inbox_key, t.inbox_name, t.account_key, t.account_name, t.category,
         c.occurred_at, c.actor_kind, c.owner_ref, t.market, t.zone,
         (c.occurred_at at time zone t.zone)::date,
         date_trunc('week', (c.occurred_at at time zone t.zone)::date::timestamp)::date,
         extract(hour from (c.occurred_at at time zone t.zone))::integer
  from c
  join t on t.id = c.thread_id
$tpl$;
  v_figures text := $tpl$
  with e as materialized (
    select x.* from (
{{EMAIL_OF}}
    ) x(connection_id, source_system, source_kind, thread_source_id, inbox_key, inbox_name, account_key, account_name, category, direction, status, occurred_at, actor_kind, owner_ref, market, zone, business_date, week_start, local_time, local_hour, is_received, is_logged_reply, is_agent_send, is_automated, is_bounced_failed)
    where x.business_date between {{F_FROM}} and {{F_TO}}
      and ({{F_UNTIL}} is null or x.business_date < {{F_TO}} or x.local_time <= ({{F_UNTIL}} at time zone x.zone)::time)
      and (null::text is null or x.market = null::text)
      and (null::text is null or x.inbox_key = null::text)
      and (null::text is null or x.account_key = null::text)
  ),
  o as materialized (
    select x.* from (
{{OPENINGS}}
    ) x(connection_id, source_system, thread_source_id, inbox_key, inbox_name, account_key, account_name, category, opening_kind, opened_at, market, zone, business_date, week_start, local_hour, first_in_at, first_reply_at, reply_owner_ref, reply_seconds, reply_business_seconds, reply_within_target, closed_at, close_actor_kind, close_owner_ref, close_seconds, close_business_seconds)
    where x.business_date between {{F_FROM}} and {{F_TO}}
      and ({{F_UNTIL}} is null or x.business_date < {{F_TO}} or (x.opened_at at time zone x.zone)::time <= ({{F_UNTIL}} at time zone x.zone)::time)
      and (null::text is null or x.market = null::text)
      and (null::text is null or x.inbox_key = null::text)
      and (null::text is null or x.account_key = null::text)
  ),
  c as materialized (
    select x.* from (
{{CLOSES}}
    ) x(connection_id, source_system, thread_source_id, inbox_key, inbox_name, account_key, account_name, category, closed_at, actor_kind, owner_ref, market, zone, business_date, week_start, local_hour)
    where x.business_date between {{F_FROM}} and {{F_TO}}
      and ({{F_UNTIL}} is null or x.business_date < {{F_TO}} or (x.closed_at at time zone x.zone)::time <= ({{F_UNTIL}} at time zone x.zone)::time)
      and (null::text is null or x.market = null::text)
      and (null::text is null or x.inbox_key = null::text)
      and (null::text is null or x.account_key = null::text)
  ),
  facts as (
    select 'email'::text as what, e.business_date, e.week_start, e.market, e.inbox_key, e.inbox_name, e.account_key, e.account_name,
           e.category, e.is_received, e.is_logged_reply, e.is_agent_send, e.is_automated, e.is_bounced_failed,
           null::timestamptz as first_reply_at, null::integer as reply_seconds, null::integer as reply_business_seconds,
           null::boolean as reply_within_target, null::timestamptz as closed_at, null::integer as close_seconds,
           null::integer as close_business_seconds
    from e
    union all
    select 'opening', o.business_date, o.week_start, o.market, o.inbox_key, o.inbox_name, o.account_key, o.account_name, o.category,
           false, false, false, false, false, o.first_reply_at, o.reply_seconds, o.reply_business_seconds, o.reply_within_target,
           o.closed_at, o.close_seconds, o.close_business_seconds
    from o
    union all
    select 'close', c.business_date, c.week_start, c.market, c.inbox_key, c.inbox_name, c.account_key, c.account_name, c.category,
           false, false, false, false, false, null, null, null, null, null, null, null
    from c
  ),
  g as (
    select d.dim, d.k, d.l, f.*
    from facts f
    cross join lateral (
      values ('total', null::text, null::text),
             ('day', f.business_date::text, f.business_date::text),
             ('week', f.week_start::text, f.week_start::text),
             ('market', f.market, f.market),
             ('inbox', coalesce(f.inbox_key, 'none'), f.inbox_name),
             ('account', coalesce(f.account_key, 'none'), f.account_name),
             ('category', coalesce(f.category, 'none'), f.category),
             ('day_inbox', f.business_date::text || '|' || coalesce(f.inbox_key, 'none'), f.inbox_name),
             ('week_inbox', f.week_start::text || '|' || coalesce(f.inbox_key, 'none'), f.inbox_name),
             ('day_account', f.business_date::text || '|' || coalesce(f.account_key, 'none'), f.account_name),
             ('week_account', f.week_start::text || '|' || coalesce(f.account_key, 'none'), f.account_name)) as d(dim, k, l)
    where d.dim = 'total' or d.dim = any ({{F_DIMS}})
  ),
  agg as (
    select g.dim, g.k, max(g.l) as l,
           (count(*) filter (where g.what = 'email' and g.is_received))::integer as received,
           (count(*) filter (where g.what = 'email' and g.is_logged_reply))::integer as logged_replies,
           (count(*) filter (where g.what = 'email' and g.is_agent_send))::integer as sent_agent,
           (count(*) filter (where g.what = 'email' and g.is_automated))::integer as sent_automated,
           (count(*) filter (where g.what = 'email' and g.is_bounced_failed))::integer as bounced_failed,
           (count(*) filter (where g.what = 'opening'))::integer as threads_opened,
           (count(*) filter (where g.what = 'close'))::integer as threads_closed,
           (count(*) filter (where g.what = 'opening' and g.first_reply_at is not null))::integer as replied,
           percentile_cont(0.5) within group (order by g.reply_seconds) filter (where g.what = 'opening' and g.first_reply_at is not null) as rm,
           percentile_cont(0.5) within group (order by g.reply_business_seconds)
             filter (where g.what = 'opening' and g.reply_business_seconds is not null) as rbm,
           (count(*) filter (where g.what = 'opening' and g.reply_within_target))::integer as within_target,
           (count(*) filter (where g.what = 'opening' and g.reply_business_seconds is not null))::integer as target_known,
           (count(*) filter (where g.what = 'opening' and g.first_reply_at is not null and g.reply_business_seconds is null))::integer as no_hours,
           percentile_cont(0.5) within group (order by g.close_seconds) filter (where g.what = 'opening' and g.closed_at is not null) as cm,
           percentile_cont(0.5) within group (order by g.close_business_seconds)
             filter (where g.what = 'opening' and g.close_business_seconds is not null) as cbm
    from g
    group by g.dim, g.k
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
$tpl$;
  v_report text := $tpl$
  select x.period, x.dimension, x.group_key, x.group_label, x.received, x.logged_replies, x.sent_agent, x.sent_automated,
         x.bounced_failed, x.threads_opened, x.threads_closed, x.replied, x.reply_median_seconds, x.reply_median_business_seconds,
         x.within_target, x.target_known, x.no_hours, x.close_median_seconds, x.close_median_business_seconds
  from (
    select 'current'::text as period, 1 as part, f.*
    from (
{{FIGURES_CURRENT}}
    ) f(dimension, group_key, group_label, received, logged_replies, sent_agent, sent_automated, bounced_failed, threads_opened, threads_closed, replied, reply_median_seconds, reply_median_business_seconds, within_target, target_known, no_hours, close_median_seconds, close_median_business_seconds)
    union all
    select 'previous', 2, f.*
    from (
{{FIGURES_PREVIOUS}}
    ) f(dimension, group_key, group_label, received, logged_replies, sent_agent, sent_automated, bounced_failed, threads_opened, threads_closed, replied, reply_median_seconds, reply_median_business_seconds, within_target, target_known, no_hours, close_median_seconds, close_median_business_seconds)
  ) x
  order by x.part, x.dimension, x.group_key
$tpl$;
  v_zone    text := (select t.timezone from cma.tenant t where t.id = p_tenant);
  v_prev    record;
  v_cur     text;
  v_prv     text;
begin
  -- one email_figures_of: email_of, the openings and the closes with their conversations inlined
  v_figures := replace(v_figures, '{{EMAIL_OF}}', v_email_of);
  v_figures := replace(v_figures, '{{OPENINGS}}',
                       replace(v_openings, '{{THREADS_O}}', replace(v_threads, '{{IDS}}', '(select coalesce(array_agg(distinct o.thread_id), ''{}'') from o)::uuid[]')));
  v_figures := replace(v_figures, '{{CLOSES}}',
                       replace(v_closes, '{{THREADS_C}}', replace(v_threads, '{{IDS}}', '(select coalesce(array_agg(distinct c.thread_id), ''{}'') from c)::uuid[]')));
  -- the period, per day, market, inbox, mailbox and category, and the received series (email_report_of's dimensions for 'day')
  v_cur := replace(v_figures, '{{F_DIMS}}', quote_literal(array['day', 'market', 'inbox', 'account', 'category', 'day_inbox', 'day_account']::text) || '::text[]');
  v_cur := replace(v_cur, '{{F_FROM_AT}}', quote_literal(((p_from - 1)::timestamp at time zone v_zone)::text) || '::timestamptz');
  v_cur := replace(v_cur, '{{F_TO_AT}}', quote_literal(((p_to + 2)::timestamp at time zone v_zone)::text) || '::timestamptz');
  v_cur := replace(v_cur, '{{F_FROM}}', quote_literal(p_from::text) || '::date');
  v_cur := replace(v_cur, '{{F_TO}}', quote_literal(p_to::text) || '::date');
  v_cur := replace(v_cur, '{{F_UNTIL}}', 'null::timestamptz');
  -- the previous span, like for like, totals only
  select * into v_prev from cma.forms_previous_of(p_tenant, p_from, p_to, p_now);
  v_prv := replace(v_figures, '{{F_DIMS}}', '''{}''::text[]');
  v_prv := replace(v_prv, '{{F_FROM_AT}}', quote_literal(((v_prev.prev_from - 1)::timestamp at time zone v_zone)::text) || '::timestamptz');
  v_prv := replace(v_prv, '{{F_TO_AT}}', quote_literal(((v_prev.prev_to + 2)::timestamp at time zone v_zone)::text) || '::timestamptz');
  v_prv := replace(v_prv, '{{F_FROM}}', quote_literal(v_prev.prev_from::text) || '::date');
  v_prv := replace(v_prv, '{{F_TO}}', quote_literal(v_prev.prev_to::text) || '::date');
  v_prv := replace(v_prv, '{{F_UNTIL}}', coalesce(quote_literal(v_prev.until::text) || '::timestamptz', 'null::timestamptz'));
  v_report := replace(replace(v_report, '{{FIGURES_CURRENT}}', v_cur), '{{FIGURES_PREVIOUS}}', v_prv);
  -- the settings and the tenant
  v_report := replace(v_report, '{{ZONE}}', quote_literal(v_zone) || '::text');
  v_report := replace(v_report, '{{ORD}}', quote_literal(string_to_array(cma.setting_of(p_tenant, 'email.market_order'), ',')::text) || '::text[]');
  v_report := replace(v_report, '{{TARGET}}', (greatest(1, cma.setting_of(p_tenant, 'email.reply_target_minutes')::integer) * 60)::text);
  v_report := replace(v_report, '{{T}}', quote_literal(p_tenant::text) || '::uuid');
  return v_report;
end
$f$;

-- 1. The tenant, the server and its planner settings
select pg_temp.perf_lines('1. Tenant, server, planner settings', $q$
  select 'tenant pulse4all-subscriptions: ' || coalesce(nullif(current_setting('perf.tenant'), ''), 'NOT FOUND')
  union all select 'tenant time zone: ' || coalesce((select t.timezone from cma.tenant t where t.id::text = current_setting('perf.tenant')), '-')
  union all select 'period: ' || current_setting('perf.from') || ' to ' || current_setting('perf.to') || ', run at ' || current_setting('perf.now')
  union all select 'server: ' || version()
  union all select 'migrations: ' || count(*) || ', latest ' || max(version) from cma.schema_migration
  union all select * from (
    select rpad(s.name, 36) || s.setting || coalesce(' ' || s.unit, '') || case when s.source <> 'default' then '  (' || s.source || ')' else '' end
    from pg_settings s
    where s.name in ('shared_buffers', 'work_mem', 'effective_cache_size', 'maintenance_work_mem', 'random_page_cost', 'seq_page_cost',
                     'effective_io_concurrency', 'max_parallel_workers_per_gather', 'max_parallel_workers', 'jit', 'jit_above_cost',
                     'default_statistics_target', 'plan_cache_mode', 'enable_memoize', 'from_collapse_limit', 'join_collapse_limit',
                     'track_io_timing', 'max_connections')
    order by s.name) x
$q$);

-- 2. Row counts: the whole tenant, and the read window the reads use (the day before the period to two days after)
select pg_temp.perf_lines('2. Row counts (whole tenant; "window" = ' || current_setting('perf.from') || ' minus a day to ' || current_setting('perf.to') || ' plus two days)', $q$
  with p as (
    select t.id as t, (current_setting('perf.from')::date - 1)::timestamp at time zone t.timezone as w_from,
           (current_setting('perf.to')::date + 2)::timestamp at time zone t.timezone as w_to
    from cma.tenant t where t.id::text = current_setting('perf.tenant')
  ),
  deals as (
    select r.*, cp.is_order, cp.is_lead, cp.is_counted, st.outcome, cp.tenant_id is not null as has_pipeline
    from p
    join cma.crm_record r on r.tenant_id = p.t and r.record_type = 'deal'
    left join cma.connection_pipeline cp
      on cp.tenant_id = r.tenant_id and cp.connection_id = r.connection_id and cp.record_type = r.record_type and cp.source_pipeline_id = r.pipeline_id
    left join cma.connection_stage st
      on st.tenant_id = r.tenant_id and st.connection_id = r.connection_id and st.record_type = r.record_type
     and st.source_pipeline_id = r.pipeline_id and st.source_stage_id = r.stage_id
  ),
  c(label, value) as (
    select 'crm_record ' || r.record_type, count(*) from p join cma.crm_record r on r.tenant_id = p.t group by r.record_type
    union all select 'crm_record deal, deleted', count(*) from deals where source_deleted_at is not null
    union all select 'crm_record deal, not deleted, ' || case when not has_pipeline then 'pipeline not configured'
                                                              when is_order and is_counted then 'order pipeline'
                                                              when is_lead and is_counted then 'lead pipeline'
                                                              else 'other pipeline' end || ', stage outcome ' || coalesce(outcome, 'none'), count(*)
              from deals where source_deleted_at is null group by 1
    union all select 'crm_record deal, order pipeline, won, created in window', count(*)
              from deals, p where source_deleted_at is null and is_order and is_counted and outcome = 'won'
                and source_created_at >= p.w_from and source_created_at < p.w_to
    union all select 'crm_record deal, order pipeline, won, created in window, no primary contact', count(*)
              from deals, p where source_deleted_at is null and is_order and is_counted and outcome = 'won' and contact_source_id is null
                and source_created_at >= p.w_from and source_created_at < p.w_to
    union all select 'crm_record deal, not deleted, no primary contact', count(*) from deals where source_deleted_at is null and contact_source_id is null
    union all select 'crm_association ' || a.from_type || ' -> ' || a.to_type || case when a.removed_at is null then ', current' else ', removed' end, count(*)
              from p join cma.crm_association a on a.tenant_id = p.t group by a.from_type, a.to_type, a.removed_at is null
    union all select 'crm_contact', count(*) from p join cma.crm_contact cc on cc.tenant_id = p.t
    union all select 'crm_contact, deleted', count(*) from p join cma.crm_contact cc on cc.tenant_id = p.t where cc.source_deleted_at is not null
    union all select 'crm_contact, with a creation time', count(*) from p join cma.crm_contact cc on cc.tenant_id = p.t where cc.source_created_at is not null
    union all select 'crm_contact, with a country', count(*) from p join cma.crm_contact cc on cc.tenant_id = p.t where cc.country is not null
    union all select 'crm_call', count(*) from p join cma.crm_call c on c.tenant_id = p.t
    union all select 'crm_call, deleted', count(*) from p join cma.crm_call c on c.tenant_id = p.t where c.source_deleted_at is not null
    union all select 'crm_call, with a counterpart hash', count(*) from p join cma.crm_call c on c.tenant_id = p.t where c.counterpart_hash is not null
    union all select 'crm_call, occurred in window', count(*) from p join cma.crm_call c on c.tenant_id = p.t
              where c.occurred_at >= p.w_from and c.occurred_at < p.w_to
    union all select 'call_link, current', count(*) from p join cma.call_link l on l.tenant_id = p.t where l.unlinked_at is null
    union all select 'telephony_call', count(*) from p join cma.telephony_call tc on tc.tenant_id = p.t
    union all select 'telephony_call, with a counterpart hash', count(*) from p join cma.telephony_call tc on tc.tenant_id = p.t where tc.counterpart_hash is not null
    union all select 'telephony_call, started in window', count(*) from p join cma.telephony_call tc on tc.tenant_id = p.t
              where tc.started_at >= p.w_from and tc.started_at < p.w_to
    union all select 'email_message ' || em.source_kind || ' ' || em.direction, count(*) from p join cma.email_message em on em.tenant_id = p.t
              group by em.source_kind, em.direction
    union all select 'email_message ' || em.source_kind || ', occurred in window', count(*) from p join cma.email_message em on em.tenant_id = p.t
              where em.occurred_at >= p.w_from and em.occurred_at < p.w_to group by em.source_kind
    union all select 'email_message, deleted', count(*) from p join cma.email_message em on em.tenant_id = p.t where em.source_deleted_at is not null
    union all select 'email_message, with its own contact', count(*) from p join cma.email_message em on em.tenant_id = p.t where em.contact_source_id is not null
    union all select 'email_thread', count(*) from p join cma.email_thread th on th.tenant_id = p.t
    union all select 'email_thread, created in window', count(*) from p join cma.email_thread th on th.tenant_id = p.t
              where th.source_created_at >= p.w_from and th.source_created_at < p.w_to
    union all select 'email_thread, with a contact', count(*) from p join cma.email_thread th on th.tenant_id = p.t where th.contact_source_id is not null
    union all select 'email_thread, spam', count(*) from p join cma.email_thread th on th.tenant_id = p.t where th.is_spam
    union all select 'email_thread_event ' || ev.kind, count(*) from p join cma.email_thread_event ev on ev.tenant_id = p.t group by ev.kind
    union all select 'email_thread_event ' || ev.kind || ', in window', count(*) from p join cma.email_thread_event ev on ev.tenant_id = p.t
              where ev.occurred_at >= p.w_from and ev.occurred_at < p.w_to group by ev.kind
    union all select 'commerce_order', count(*) from p join cma.commerce_order co on co.tenant_id = p.t
    union all select 'commerce_order, order_kind ' || co.order_kind, count(*) from p join cma.commerce_order co on co.tenant_id = p.t group by co.order_kind
    union all select 'commerce_order, with a phone hash', count(*) from p join cma.commerce_order co on co.tenant_id = p.t where co.phone_hash is not null
    union all select 'commerce_order, created in window', count(*) from p join cma.commerce_order co on co.tenant_id = p.t
              where co.source_created_at >= p.w_from and co.source_created_at < p.w_to
    union all select 'commerce_customer', count(*) from p join cma.commerce_customer cu on cu.tenant_id = p.t
    union all select 'commerce_customer, matched to a CRM contact', count(*) from p join cma.commerce_customer cu on cu.tenant_id = p.t
              where cu.crm_contact_source_id is not null
    union all select 'commerce_customer, with a phone hash', count(*) from p join cma.commerce_customer cu on cu.tenant_id = p.t where cu.phone_hash is not null
    union all select 'form_submission', count(*) from p join cma.form_submission fs on fs.tenant_id = p.t
    union all select 'app_user_external_id', count(*) from p join cma.app_user_external_id x on x.tenant_id = p.t
    union all select 'integration_connection ' || coalesce(ic.kind, 'no kind'), count(*) from p join cma.integration_connection ic on ic.tenant_id = p.t group by ic.kind
    union all select 'connection_pipeline', count(*) from p join cma.connection_pipeline x on x.tenant_id = p.t
    union all select 'connection_stage', count(*) from p join cma.connection_stage x on x.tenant_id = p.t
    union all select 'connection_inbox', count(*) from p join cma.connection_inbox x on x.tenant_id = p.t
    union all select 'connection_inbox_account', count(*) from p join cma.connection_inbox_account x on x.tenant_id = p.t
    union all select 'connection_inbox_channel', count(*) from p join cma.connection_inbox_channel x on x.tenant_id = p.t
    union all select 'market', count(*) from p join cma.market x on x.tenant_id = p.t
    union all select 'market_alias', count(*) from p join cma.market_alias x on x.tenant_id = p.t
  )
  select rpad(c.label, 84) || lpad(c.value::text, 12) from c order by c.label
$q$);

-- 3. The data's shape: how many rows one first order, one contact or one phone number fans out to
select pg_temp.perf_lines('3. Shape (n = keys, max and p99 rows per key)', $q$
  with p as (
    select t.id as t, (current_setting('perf.from')::date - 1)::timestamp at time zone t.timezone as w_from,
           (current_setting('perf.to')::date + 2)::timestamp at time zone t.timezone as w_to
    from cma.tenant t where t.id::text = current_setting('perf.tenant')
  ),
  f(label, k) as (
    select 'crm_call per counterpart hash (not deleted)', count(*) from p join cma.crm_call c on c.tenant_id = p.t
      where c.counterpart_hash is not null and c.source_deleted_at is null group by c.counterpart_hash
    union all select 'telephony_call per counterpart hash', count(*) from p join cma.telephony_call tc on tc.tenant_id = p.t
      where tc.counterpart_hash is not null and tc.source_deleted_at is null group by tc.counterpart_hash
    union all select 'crm_association ' || a.from_type || ' per contact (current)', count(*) from p join cma.crm_association a on a.tenant_id = p.t
      where a.to_type = 'contact' and a.removed_at is null group by a.from_type, a.connection_id, a.to_id
    union all select 'crm_association contacts per deal (current)', count(*) from p join cma.crm_association a on a.tenant_id = p.t
      where a.from_type = 'deal' and a.to_type = 'contact' and a.removed_at is null group by a.connection_id, a.from_id
    union all select 'crm_record deals per primary contact', count(*) from p join cma.crm_record r on r.tenant_id = p.t
      where r.record_type = 'deal' and r.contact_source_id is not null and r.source_deleted_at is null group by r.connection_id, r.contact_source_id
    union all select 'email_message per own contact', count(*) from p join cma.email_message em on em.tenant_id = p.t
      where em.contact_source_id is not null group by em.connection_id, em.contact_source_id
    union all select 'email_thread per contact', count(*) from p join cma.email_thread th on th.tenant_id = p.t
      where th.contact_source_id is not null group by th.connection_id, th.contact_source_id
    union all select 'email_message per thread', count(*) from p join cma.email_message em on em.tenant_id = p.t
      where em.thread_source_id is not null group by em.connection_id, em.thread_source_id
    union all select 'email_thread_event per thread', count(*) from p join cma.email_thread_event ev on ev.tenant_id = p.t
      group by ev.connection_id, ev.thread_source_id
    union all select 'commerce_order per customer', count(*) from p join cma.commerce_order co on co.tenant_id = p.t
      group by co.connection_id, co.customer_source_id
    union all select 'commerce_customer per CRM contact', count(*) from p join cma.commerce_customer cu on cu.tenant_id = p.t
      where cu.crm_contact_source_id is not null group by cu.crm_connection_id, cu.crm_contact_source_id
    union all select 'form_submission per contact', count(*) from p join cma.form_submission fs on fs.tenant_id = p.t
      where fs.contact_source_id is not null group by fs.connection_id, fs.contact_source_id
  ),
  -- the phone tier's reach: CRM and telephony calls sharing a hash with an order of the window (its own or its customer's)
  ph(label, value) as (
    select 'calls sharing a phone hash with an order created in window (crm_call)', count(*)
    from p join cma.commerce_order co on co.tenant_id = p.t
    left join cma.commerce_customer cu on cu.tenant_id = co.tenant_id and cu.connection_id = co.connection_id and cu.source_id = co.customer_source_id
    join cma.crm_call c on c.tenant_id = p.t and c.counterpart_hash in (co.phone_hash, cu.phone_hash)
    where co.source_created_at >= p.w_from and co.source_created_at < p.w_to
    union all
    select 'calls sharing a phone hash with an order created in window (telephony_call)', count(*)
    from p join cma.commerce_order co on co.tenant_id = p.t
    left join cma.commerce_customer cu on cu.tenant_id = co.tenant_id and cu.connection_id = co.connection_id and cu.source_id = co.customer_source_id
    join cma.telephony_call tc on tc.tenant_id = p.t and tc.counterpart_hash in (co.phone_hash, cu.phone_hash)
    where co.source_created_at >= p.w_from and co.source_created_at < p.w_to
  )
  select rpad(f.label, 64) || ' n ' || lpad(count(*)::text, 9) || '  max ' || lpad(max(f.k)::text, 7)
         || '  p99 ' || lpad(percentile_disc(0.99) within group (order by f.k)::text, 6) || '  avg ' || round(avg(f.k), 2)
  from f group by f.label
  union all
  select rpad(ph.label, 84) || lpad(ph.value::text, 12) from ph
$q$);

-- 4. The settings the report functions read, resolved for the tenant
select pg_temp.perf_lines('4. Report settings', $q$
  select rpad(k, 40) || coalesce(cma.setting_of(t.id, k), '-')
  from cma.tenant t
  cross join unnest(array['attribution.window_days', 'attribution.level_order', 'attribution.assisted_levels', 'attribution.known_contact_minutes',
                          'attribution.order_match_minutes', 'email.market_order', 'email.reply_target_minutes', 'email.no_response_days',
                          'email.start_date', 'intake.start_date', 'telephony.connected_min_seconds', 'follow_up.list_rows',
                          'reports.per_person']) k
  where t.id::text = current_setting('perf.tenant')
  union all
  select rpad('connection ' || coalesce(ic.kind, '-') || ' ' || ic.adapter, 40)
         || 'inbox-copy origins ' || cardinality(cma.setting_codes(ic.settings, 'email_inbox_copy_origins'))
         || ', automated origins ' || cardinality(cma.setting_codes(ic.settings, 'email_automated_origins'))
         || ', status ' || ic.status
  from cma.integration_connection ic
  where ic.tenant_id::text = current_setting('perf.tenant')
$q$);

-- 5. Table statistics: are the planner's row estimates fresh?
select pg_temp.perf_lines('5. Table statistics (all tenants)', $q$
  select rpad(s.relname, 26) || ' live ' || lpad(s.n_live_tup::text, 10) || '  dead ' || lpad(s.n_dead_tup::text, 8)
         || '  analyzed ' || coalesce(to_char(greatest(s.last_analyze, s.last_autoanalyze), 'YYYY-MM-DD HH24:MI'), 'never')
         || '  vacuumed ' || coalesce(to_char(greatest(s.last_vacuum, s.last_autovacuum), 'YYYY-MM-DD HH24:MI'), 'never')
         || '  size ' || pg_size_pretty(pg_total_relation_size(s.relid))
  from pg_stat_user_tables s
  where s.schemaname = 'cma'
    and s.relname in ('crm_record', 'crm_association', 'crm_contact', 'crm_call', 'telephony_call', 'call_link', 'email_message', 'email_thread',
                      'email_thread_event', 'commerce_order', 'commerce_customer', 'form_submission', 'app_user_external_id',
                      'connection_pipeline', 'connection_stage', 'market', 'market_alias')
  order by s.relname
$q$);

-- 6. The indexes on those tables
select pg_temp.perf_lines('6. Indexes (definition, size, scans)', $q$
  select rpad(i.relname, 22) || ' ' || pg_get_indexdef(i.indexrelid) || '  [' || pg_size_pretty(pg_relation_size(i.indexrelid))
         || ', ' || i.idx_scan || ' scans]'
  from pg_stat_user_indexes i
  where i.schemaname = 'cma'
    and i.relname in ('crm_record', 'crm_association', 'crm_contact', 'crm_call', 'telephony_call', 'call_link', 'email_message', 'email_thread',
                      'email_thread_event', 'commerce_order', 'commerce_customer', 'form_submission', 'app_user_external_id',
                      'connection_pipeline', 'connection_stage', 'market', 'market_alias')
  order by i.relname, i.indexrelname
$q$);

-- 7. Timings of the report functions as they are, October, per day, no filters
select pg_temp.perf_lines('7. Timings (owner role unless "as cma_app")', $q$ select rpad('function', 64) || lpad('wall time', 11) || '  what it found' $q$);
select pg_temp.perf_time('first_orders_of, one pass (what amounts and list each run)', format($q$
  select sum(n) || ' order deals; ' || string_agg(k || ' ' || n, ', ' order by k)
  from (select x.kind || coalesce('/' || x.level, '') as k, count(*) as n
        from cma.tenant t
        cross join lateral cma.first_orders_of(t.id, (%2$L::date - 1)::timestamp at time zone t.timezone, (%3$L::date + 2)::timestamp at time zone t.timezone) x
        where t.id = %1$L::uuid and x.business_date between %2$L::date and %3$L::date
        group by 1) y
$q$, current_setting('perf.tenant'), current_setting('perf.from'), current_setting('perf.to')));
select pg_temp.perf_time('first_orders_report_of (the period and the previous span)', format($q$
  with r as materialized (select * from cma.first_orders_report_of(%1$L::uuid, %2$L::date, %3$L::date, 'day', null, null, %4$L::timestamptz))
  select (select count(*) from r) || ' rows; ' ||
         (select string_agg(r.period || ' first ' || r.first_orders || ' (call center ' || r.call_center || ', self-service ' || r.self_service
                            || '), repeat ' || r.repeats || ', renewal ' || r.renewals || ', not first ' || r.not_first || ', no contact ' || r.no_contact,
                            '; ' order by r.period)
          from r where r.dimension = 'total')
$q$, current_setting('perf.tenant'), current_setting('perf.from'), current_setting('perf.to'), current_setting('perf.now')));
select pg_temp.perf_time('first_orders_history_start_of', format($q$
  select coalesce(h.history_start::text, '-') || ' / phone ' || coalesce(h.phone_start::text, '-') from cma.first_orders_history_start_of(%1$L::uuid) h
$q$, current_setting('perf.tenant')));
select pg_temp.perf_time('email_report_of (the period and the previous span)', format($q$
  with r as materialized (select * from cma.email_report_of(%1$L::uuid, %2$L::date, %3$L::date, 'day', null, null, null, %4$L::timestamptz))
  select (select count(*) from r) || ' rows; ' ||
         (select string_agg(r.period || ' received ' || r.received || ', logged replies ' || r.logged_replies || ', sent ' || r.sent_agent
                            || ', automated ' || r.sent_automated || ', bounced/failed ' || r.bounced_failed || ', opened ' || r.threads_opened
                            || ', closed ' || r.threads_closed || ', replied ' || r.replied, '; ' order by r.period)
          from r where r.dimension = 'total')
$q$, current_setting('perf.tenant'), current_setting('perf.from'), current_setting('perf.to'), current_setting('perf.now')));
select pg_temp.perf_time('email_by_dimension_of (the filter lists, unfiltered)', format($q$
  select count(*) || ' rows' from cma.email_by_dimension_of(%1$L::uuid, %2$L::date, %3$L::date, null, null, null)
$q$, current_setting('perf.tenant'), current_setting('perf.from'), current_setting('perf.to')));
select pg_temp.perf_time('email_per_person_of (Email per agent)', format($q$
  select count(*) || ' rows; total sent ' || max(x.sent) filter (where x.row_kind = 'total') || ', replies ' || max(x.replies) filter (where x.row_kind = 'total')
         || ', closed ' || max(x.threads_closed) filter (where x.row_kind = 'total')
  from cma.email_per_person_of(%1$L::uuid, %2$L::date, %3$L::date, null, null, null) x
$q$, current_setting('perf.tenant'), current_setting('perf.from'), current_setting('perf.to')));
select pg_temp.perf_time('email_waiting_of', format($q$
  select count(*) || ' rows' from cma.email_waiting_of(%1$L::uuid, %2$L::timestamptz)
$q$, current_setting('perf.tenant'), current_setting('perf.now')));
select pg_temp.perf_time('email_not_responding_of', format($q$
  select count(*) || ' rows' from cma.email_not_responding_of(%1$L::uuid, %2$L::timestamptz)
$q$, current_setting('perf.tenant'), current_setting('perf.now')));
select pg_temp.perf_time('email_history_start_of', format($q$
  select coalesce(cma.email_history_start_of(%1$L::uuid)::text, '-')
$q$, current_setting('perf.tenant')));
select pg_temp.perf_time('callbacks_kept_report_of', format($q$
  select count(*) || ' rows' from cma.callbacks_kept_report_of(%1$L::uuid, %2$L::date, %3$L::date, %4$L::timestamptz)
$q$, current_setting('perf.tenant'), current_setting('perf.from'), current_setting('perf.to'), current_setting('perf.now')));
select pg_temp.perf_time('first_orders_amounts_of, as cma_app', format($q$
  select count(*) || ' rows' from cma.first_orders_amounts_of(%1$L::uuid, %2$L::date, %3$L::date, null, null)
$q$, current_setting('perf.tenant'), current_setting('perf.from'), current_setting('perf.to')), true);
select pg_temp.perf_time('email_report_of, as cma_app', format($q$
  select count(*) || ' rows' from cma.email_report_of(%1$L::uuid, %2$L::date, %3$L::date, 'day', null, null, null, %4$L::timestamptz)
$q$, current_setting('perf.tenant'), current_setting('perf.from'), current_setting('perf.to'), current_setting('perf.now')), true);

-- 8. The plan of cma.first_orders_of's body, inlined, over the bounds the reads give it
select pg_temp.perf_explain('8. EXPLAIN (ANALYZE, BUFFERS, SETTINGS) cma.first_orders_of body, inlined',
  pg_temp.perf_first_orders_sql(t.id, (current_setting('perf.from')::date - 1)::timestamp at time zone t.timezone,
                                (current_setting('perf.to')::date + 2)::timestamp at time zone t.timezone))
from (select 1) d
left join cma.tenant t on t.id::text = current_setting('perf.tenant');

-- 9. The plan of cma.email_report_of's body, inlined, per day, without filters
select pg_temp.perf_explain('9. EXPLAIN (ANALYZE, BUFFERS, SETTINGS) cma.email_report_of body, inlined',
  pg_temp.perf_email_report_sql(nullif(current_setting('perf.tenant'), '')::uuid, current_setting('perf.from')::date,
                                current_setting('perf.to')::date, current_setting('perf.now')::timestamptz));

-- 10 and 11. The same two plans as cma_app, as the application reads them (row-level security on)
select pg_temp.perf_explain('10. EXPLAIN (ANALYZE, BUFFERS, SETTINGS) cma.first_orders_of body, inlined, as cma_app',
  pg_temp.perf_first_orders_sql(t.id, (current_setting('perf.from')::date - 1)::timestamp at time zone t.timezone,
                                (current_setting('perf.to')::date + 2)::timestamp at time zone t.timezone), true)
from (select 1) d
left join cma.tenant t on t.id::text = current_setting('perf.tenant');
select pg_temp.perf_explain('11. EXPLAIN (ANALYZE, BUFFERS, SETTINGS) cma.email_report_of body, inlined, as cma_app',
  pg_temp.perf_email_report_sql(nullif(current_setting('perf.tenant'), '')::uuid, current_setting('perf.from')::date,
                                current_setting('perf.to')::date, current_setting('perf.now')::timestamptz), true);

-- The output: every line in order (this is the result to copy); the session's statement timeout back
-- to its default first
reset statement_timeout;
select n, line from perf_diag order by n;
