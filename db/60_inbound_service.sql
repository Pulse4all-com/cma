-- =============================================================================================
-- 60_inbound_service.sql: addition 0008i, inbound service level and missed calls not called back
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 54_uncounted_lines.sql (0008f). Rerunnable, forward-only, in one transaction. Run as your own IAM
-- login, dev first, then prod; then rerun 02_seed_<customer>.sql for the customer's reasons and
-- settings, then 61_verify_inbound_service.sql (dev), then 35_verify_telephony.sql,
-- 41_verify_lead_metrics.sql, 53_verify_sources_configuration.sql and 55_verify_uncounted_lines.sql
-- again (unchanged).
--
-- Brief B15 (backlog CMA-056 and CMA-057; README Decision log, 14 October 2026).
--
-- What it adds
--   missed reasons     cma.telephony_missed_reason: one row per tenant, source system (the telephony
--                      connection's adapter, a data value) and missed-reason code, with a label and
--                      two flags: counts_in_service_level and needs_callback. A code without a row
--                      counts with the defaults (the code as label, both flags true), so a new
--                      vendor code never disappears; an unanswered inbound call without a reason is
--                      the code 'unknown'. Written with cma.set_telephony_missed_reason()
--                      (tenant.configure); the application never deletes a row
--   settings           telephony.service_level_seconds (20), telephony.callback_lookback_days (3),
--                      telephony.waiting_max_minutes (30)
--   inbound service    cma.inbound_service(from, to, group): per day, market, line or hour the
--                      inbound calls offered, answered and unanswered, the service level, the
--                      average and 80th percentile time to answer, and the unanswered calls per
--                      reason code, then a total row (reports.view or performance.team)
--   today              cma.inbound_today(): the same measures for today in the tenant's zone, plus
--                      the calls waiting now and the longest wait (monitoring.live)
--   callbacks          cma.missed_callbacks(): one row per caller whose latest missed inbound call
--                      that needs a callback lies within the lookback and has had no later
--                      outbound call to the caller and no later answered inbound call from them;
--                      cma.missed_callbacks_summary(): the callers listed and the anonymous missed
--                      calls, which cannot be matched (monitoring.live)
--   configuration      cma.missed_reasons() (the catalog, for the screens that label reasons) and
--                      cma.connection_missed_reasons(connection) (the reasons a telephony
--                      connection has seen plus its catalog rows, and its newest call id for the
--                      record link preview, tenant.configure)
--
-- Definitions
--   inbound            a telephony call with direction inbound, not deleted, with a start time, on
--                      a counted line (0008f stores no other; a line not yet in the catalog counts)
--   waiting            inbound, not answered, not ended, started within telephony.waiting_max_minutes:
--                      the call has no outcome yet. An unanswered, unended call older than that is
--                      not waiting (a lost ended event) and counts as unanswered
--   answered           answered_at is set; unanswered: not answered and not waiting
--   time to answer     answered_at - started_at, the menu and the ringing included, as the
--                      telephony system reports it
--   service level      answered within telephony.service_level_seconds (at most, so a call answered
--                      at exactly N seconds is within) / the inbound calls with an outcome whose
--                      reason counts in the service level; an answered call always counts
--   zone               a call's business date and hour are in its line's market zone, else the
--                      tenant's zone (a line without a market, a call without a line)
--   called back        any later outbound call to the same caller (connected or not), or any later
--                      answered inbound call from them, on any telephony connection of the tenant
--
-- counterpart_hash gets its third purpose here: callback matching, inside one tenant only. The hash
-- is never shown and no function of this addition returns it.
--
-- How the rows are made once (as 0007d): each read is a function of an explicit tenant (cma.*_of)
-- in the caller's rights; the application's functions check the permission and call it for the
-- current tenant under row-level security. Everything here is SECURITY INVOKER and executable by
-- the application only. The reporting reader gets the catalog's view; the measures have none.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted.
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008f') then
    raise exception 'addition 0008f (54_uncounted_lines.sql) must run before 0008i';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The missed-reason catalog
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.telephony_missed_reason (
  tenant_id                uuid not null default cma.current_tenant_id() references cma.tenant (id),
  source_system            text not null check (source_system ~ '^[a-z0-9_]+$'),
  code                     text not null check (length(code) between 1 and 60 and code = btrim(code)),
  label                    text not null check (length(label) between 1 and 100 and label = btrim(label)),
  counts_in_service_level  boolean not null default true,
  needs_callback           boolean not null default true,
  updated_at               timestamptz not null default now(),
  primary key (tenant_id, source_system, code)
);
comment on table cma.telephony_missed_reason is 'Missed-reason codes of a telephony system per tenant: label, whether an unanswered call with the code counts in the service level, whether it needs a callback. A code without a row counts with the defaults (label = code, both true); a missing reason is the code unknown (0008i)';
comment on column cma.telephony_missed_reason.source_system is 'The telephony connection''s adapter, a data value (the source_system of cma.telephony_call)';
create or replace trigger set_updated_at before update on cma.telephony_missed_reason
  for each row execute function cma.set_updated_at();

select cma.setup_tenant_table('cma.telephony_missed_reason');
-- The application writes the catalog through cma.set_telephony_missed_reason() and never deletes
revoke delete on cma.telephony_missed_reason from cma_app;

-- The keyed hash's three purposes (README, Data model: telephony and inbound service and callbacks)
comment on column cma.telephony_call.counterpart_hash is 'HMAC-SHA256(tenant pepper, E.164 number of the other party) in hex, made by the ingest service; never shown and never returned by a function. Three purposes, each inside one tenant: the link to the CRM call that logged the call (0007a), matching commerce orders to earlier calls (0008g) and matching missed inbound calls to later callbacks (0008i)';

-- ---------------------------------------------------------------------------------------------
-- 2. Settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('telephony.service_level_seconds',   'integer', null, '20',
     'An inbound call answered within this many seconds (the menu and ringing included) counts as answered within the service level'),
  ('telephony.callback_lookback_days',  'integer', null, '3',
     'Missed inbound calls of the last this many days are listed until the caller is called back'),
  ('telephony.waiting_max_minutes',     'integer', null, '30',
     'An unanswered inbound call that has not ended is waiting for at most this many minutes; older, it counts as unanswered (a lost end event)')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 3. The inbound calls of a tenant, one row each (no hash)
-- ---------------------------------------------------------------------------------------------
-- Inbound calls started in [p_from, p_to) (null: unbounded) with their line, market, zone,
-- business date and hour, outcome, time to answer and, for an unanswered call, its reason with
-- the catalog's label and flags or the defaults. in_service_level: the call is in the service
-- level's denominator (answered, or unanswered with a reason that counts). Negative settings count
-- as 0.
create or replace function cma.inbound_calls_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  call_id                  uuid,
  connection_id            uuid,
  source_system            text,
  source_id                text,
  line_key                 text,
  line_ref                 text,
  line_name                text,
  market                   text,
  zone                     text,
  started_at               timestamptz,
  business_date            date,
  local_hour               integer,
  is_answered              boolean,
  is_waiting               boolean,
  answer_seconds           numeric,
  reason_code              text,
  reason_label             text,
  needs_callback           boolean,
  in_service_level         boolean
)
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
      and (p_from is null or tc.started_at >= p_from)
      and (p_to is null or tc.started_at < p_to)
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

-- ---------------------------------------------------------------------------------------------
-- 4. Inbound service per group (the report) and today (the Live board)
-- ---------------------------------------------------------------------------------------------
-- Per group of the business dates [p_from, p_to] (each call's date in its own zone): day (the
-- date), market (the line's market or 'unknown'), line (connection:line ref, labelled with the
-- line's name) or hour (00 to 23, the hour of day in the call's zone, all dates together); then
-- the total over every call as the last row, with group_key and group_label null (averages,
-- percentiles and the service level do not add up across groups, so the total is computed, not
-- summed; it is there even for a period without calls).
create or replace function cma.inbound_service_of(p_tenant_id uuid, p_from date, p_to date, p_group text)
returns table (
  group_key               text,
  group_label             text,
  offered                 integer,
  answered                integer,
  unanswered              integer,
  waiting                 integer,
  answered_within_target  integer,
  service_level_base      integer,
  service_level_pct       numeric,
  avg_answer_seconds      numeric,
  p80_answer_seconds      numeric,
  unanswered_by_reason    jsonb
)
language sql stable
as $$
  with s as (
    select t.timezone as zone,
           greatest(0, cma.setting_of(t.id, 'telephony.service_level_seconds')::integer) as sl
    from cma.tenant t where t.id = p_tenant_id
  ),
  c as (
    -- a day on each side, so a line in another zone than the tenant's keeps its whole dates
    select x.* from s
    cross join lateral cma.inbound_calls_of(p_tenant_id, (p_from - 1)::timestamp at time zone s.zone,
                                            (p_to + 2)::timestamp at time zone s.zone) x
    where x.business_date between p_from and p_to
  )
  select g.k, g.l,
         count(*)::integer,
         (count(*) filter (where c.is_answered))::integer,
         (count(*) filter (where not c.is_answered and not c.is_waiting))::integer,
         (count(*) filter (where c.is_waiting))::integer,
         (count(*) filter (where c.is_answered and c.answer_seconds <= s.sl))::integer,
         (count(*) filter (where c.in_service_level))::integer,
         round(100.0 * count(*) filter (where c.is_answered and c.answer_seconds <= s.sl)
               / nullif(count(*) filter (where c.in_service_level), 0), 1),
         round(avg(c.answer_seconds), 1),
         round((percentile_cont(0.8) within group (order by c.answer_seconds))::numeric, 1),
         coalesce((select jsonb_object_agg(u.code, u.n)
                   from (select x as code, count(*)::integer as n
                         from unnest(array_agg(c.reason_code) filter (where c.reason_code is not null)) x
                         group by x) u), '{}'::jsonb)
  from c
  cross join s
  cross join lateral (
    select case p_group when 'day' then c.business_date::text
                        when 'market' then c.market
                        when 'line' then c.line_key
                        else lpad(c.local_hour::text, 2, '0') end as k,
           case p_group when 'day' then c.business_date::text
                        when 'market' then c.market
                        when 'line' then coalesce(c.line_name, 'unknown')
                        else lpad(c.local_hour::text, 2, '0') end as l) g
  group by grouping sets ((g.k, g.l), ())
  order by grouping(g.k), case when p_group = 'line' then g.l end, g.k
$$;

-- Today in the tenant's zone (calls started since its midnight), the same measures, plus the calls
-- waiting now (started within telephony.waiting_max_minutes, also before midnight) and the longest
-- wait in seconds (null when nobody waits), with the two settings the screen names
create or replace function cma.inbound_today_of(p_tenant_id uuid)
returns table (
  business_date            date,
  offered                  integer,
  answered                 integer,
  unanswered               integer,
  waiting                  integer,
  answered_within_target   integer,
  service_level_base       integer,
  service_level_pct        numeric,
  avg_answer_seconds       numeric,
  p80_answer_seconds       numeric,
  unanswered_by_reason     jsonb,
  waiting_now              integer,
  longest_waiting_seconds  integer,
  service_level_seconds    integer,
  waiting_max_minutes      integer
)
language sql stable
as $$
  with s as (
    select t.timezone as zone, (now() at time zone t.timezone)::date as today,
           greatest(0, cma.setting_of(t.id, 'telephony.service_level_seconds')::integer) as sl,
           greatest(0, cma.setting_of(t.id, 'telephony.waiting_max_minutes')::integer) as waiting_max
    from cma.tenant t where t.id = p_tenant_id
  ),
  c as (
    select x.* from s
    cross join lateral cma.inbound_calls_of(p_tenant_id, s.today::timestamp at time zone s.zone,
                                            (s.today + 1)::timestamp at time zone s.zone) x
  ),
  w as (
    select count(*)::integer as n, floor(extract(epoch from now() - min(x.started_at)))::integer as longest
    from s
    cross join lateral cma.inbound_calls_of(p_tenant_id, now() - make_interval(mins => s.waiting_max), null) x
    where x.is_waiting
  )
  select s.today,
         count(c.call_id)::integer,
         (count(*) filter (where c.is_answered))::integer,
         (count(*) filter (where not c.is_answered and not c.is_waiting))::integer,
         (count(*) filter (where c.is_waiting))::integer,
         (count(*) filter (where c.is_answered and c.answer_seconds <= s.sl))::integer,
         (count(*) filter (where c.in_service_level))::integer,
         round(100.0 * count(*) filter (where c.is_answered and c.answer_seconds <= s.sl)
               / nullif(count(*) filter (where c.in_service_level), 0), 1),
         round(avg(c.answer_seconds), 1),
         round((percentile_cont(0.8) within group (order by c.answer_seconds))::numeric, 1),
         coalesce((select jsonb_object_agg(u.code, u.n)
                   from (select x as code, count(*)::integer as n
                         from unnest(array_agg(c.reason_code) filter (where c.reason_code is not null)) x
                         group by x) u), '{}'::jsonb),
         w.n, case when w.n > 0 then greatest(0, w.longest) end, s.sl, s.waiting_max
  from s
  cross join w
  left join c on true
  group by s.today, s.sl, s.waiting_max, w.n, w.longest
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Missed calls not called back
-- ---------------------------------------------------------------------------------------------
-- One row per caller (the hash, read here and never returned) whose latest missed inbound call
-- with a reason that needs a callback started within telephony.callback_lookback_days, with no
-- later outbound call to the caller and no later answered inbound call from them on any telephony
-- connection of the tenant. Missed: unanswered and not waiting. missed_count counts the caller's
-- missed calls in the lookback (every reason). Oldest first. Calls without a hash are left out
-- (cma.missed_callbacks_summary_of counts them).
create or replace function cma.missed_callbacks_of(p_tenant_id uuid)
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
  )
  select l.call_id, l.connection_id, l.source_id, l.line_ref, l.line_name, l.market, l.reason_code, l.reason_label,
         l.started_at, (select count(*)::integer from m where m.h = l.h),
         greatest(0, floor(extract(epoch from now() - l.started_at)))::integer,
         cma.business_seconds_of(p_tenant_id, nullif(l.market, 'unknown'), l.started_at, now())
  from l
  where not exists (select 1 from cma.telephony_call o
                    where o.tenant_id = p_tenant_id and o.counterpart_hash = l.h
                      and o.source_deleted_at is null and o.started_at > l.started_at
                      and (o.direction = 'outbound' or (o.direction = 'inbound' and o.answered_at is not null)))
  order by l.started_at, l.source_id
$$;

-- The callers listed, the anonymous missed calls (no hash, so never matched: missed calls of the
-- lookback whose reason needs a callback) and the lookback in days
create or replace function cma.missed_callbacks_summary_of(p_tenant_id uuid)
returns table (listed integer, anonymous_count integer, lookback_days integer)
language sql stable
as $$
  with s as (
    select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback
    from cma.tenant t where t.id = p_tenant_id
  )
  select (select count(*)::integer from cma.missed_callbacks_of(p_tenant_id)),
         (select count(*)::integer
          from cma.inbound_calls_of(p_tenant_id, now() - make_interval(days => s.lookback), null) x
          join cma.telephony_call tc on tc.tenant_id = p_tenant_id and tc.id = x.call_id
          where x.reason_code is not null and x.needs_callback and tc.counterpart_hash is null),
         s.lookback
  from s
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The application's reads (permission checked, current tenant, row-level security)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.inbound_service(p_from date, p_to date, p_group text)
returns table (
  group_key               text,
  group_label             text,
  offered                 integer,
  answered                integer,
  unanswered              integer,
  waiting                 integer,
  answered_within_target  integer,
  service_level_base      integer,
  service_level_pct       numeric,
  avg_answer_seconds      numeric,
  p80_answer_seconds      numeric,
  unanswered_by_reason    jsonb
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'market', 'line', 'hour') then
    raise exception 'group by day, market, line or hour, not %', p_group using errcode = 'CMA04';
  end if;
  perform cma.report_range(v_tenant, p_from, p_to);
  return query select * from cma.inbound_service_of(v_tenant, p_from, p_to, p_group);
end
$$;

create or replace function cma.inbound_today()
returns table (
  business_date            date,
  offered                  integer,
  answered                 integer,
  unanswered               integer,
  waiting                  integer,
  answered_within_target   integer,
  service_level_base       integer,
  service_level_pct        numeric,
  avg_answer_seconds       numeric,
  p80_answer_seconds       numeric,
  unanswered_by_reason     jsonb,
  waiting_now              integer,
  longest_waiting_seconds  integer,
  service_level_seconds    integer,
  waiting_max_minutes      integer
)
language plpgsql stable
as $$
begin
  perform cma.assert_permission('monitoring.live');
  return query select * from cma.inbound_today_of(cma.current_tenant_id());
end
$$;

create or replace function cma.missed_callbacks()
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
language plpgsql stable
as $$
begin
  perform cma.assert_permission('monitoring.live');
  return query select * from cma.missed_callbacks_of(cma.current_tenant_id());
end
$$;

create or replace function cma.missed_callbacks_summary()
returns table (listed integer, anonymous_count integer, lookback_days integer)
language plpgsql stable
as $$
begin
  perform cma.assert_permission('monitoring.live');
  return query select * from cma.missed_callbacks_summary_of(cma.current_tenant_id());
end
$$;

-- The catalog, for the screens that label reasons (the report, the Live board, Sources)
create or replace function cma.missed_reasons()
returns table (source_system text, code text, label text, counts_in_service_level boolean, needs_callback boolean)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team', 'monitoring.live', 'tenant.configure']);
  return query
    select r.source_system, r.code, r.label, r.counts_in_service_level, r.needs_callback
    from cma.telephony_missed_reason r
    where r.tenant_id = cma.current_tenant_id()
    order by r.source_system, r.code;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Configuration (tenant.configure): the Sources page of a telephony connection
-- ---------------------------------------------------------------------------------------------
-- The reasons the connection has seen on its unanswered inbound calls (with how many and the
-- newest) plus the catalog rows of its adapter, each with the label and flags in force (the
-- catalog's or the defaults); and the newest call id, for the record link preview (ids only)
create or replace function cma.connection_missed_reasons(p_connection_id uuid)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_system  text;
  v_max     integer;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  select c.adapter into v_system from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id;
  v_max := greatest(0, cma.setting_of(v_tenant, 'telephony.waiting_max_minutes')::integer);
  return jsonb_build_object(
    'sourceSystem', v_system,
    'missedReasons', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', k.code, 'label', coalesce(r.label, k.code),
               'countsInServiceLevel', coalesce(r.counts_in_service_level, true),
               'needsCallback', coalesce(r.needs_callback, true),
               'inCatalog', r.code is not null, 'seenCalls', coalesce(seen.n, 0), 'lastSeenAt', seen.last_at)
             order by k.code)
      from (select x.code from cma.telephony_missed_reason x where x.tenant_id = v_tenant and x.source_system = v_system
            union
            select coalesce(nullif(btrim(tc.missed_reason), ''), 'unknown')
            from cma.telephony_call tc
            where tc.tenant_id = v_tenant and tc.connection_id = p_connection_id and tc.direction = 'inbound'
              and tc.answered_at is null and tc.source_deleted_at is null
              and not (tc.ended_at is null and tc.started_at >= now() - make_interval(mins => v_max))) k
      left join cma.telephony_missed_reason r
        on r.tenant_id = v_tenant and r.source_system = v_system and r.code = k.code
      left join lateral (
        select count(*)::integer as n, max(tc.started_at) as last_at
        from cma.telephony_call tc
        where tc.tenant_id = v_tenant and tc.connection_id = p_connection_id and tc.direction = 'inbound'
          and tc.answered_at is null and tc.source_deleted_at is null
          and not (tc.ended_at is null and tc.started_at >= now() - make_interval(mins => v_max))
          and coalesce(nullif(btrim(tc.missed_reason), ''), 'unknown') = k.code) seen on true), '[]'::jsonb),
    'sampleCallId', (select tc.source_id from cma.telephony_call tc
                     where tc.tenant_id = v_tenant and tc.connection_id = p_connection_id and tc.source_deleted_at is null
                     order by tc.started_at desc nulls last, tc.source_id desc limit 1));
end
$$;

-- One code of the connection's adapter: its label and both flags. The code as the telephony system
-- writes it (1 to 60 characters), the label 1 to 100; refused for a connection of another kind, by its
-- kind or, while that is unset, by the rows it holds (0008e; a connection without either is accepted)
-- (CMA04)
create or replace function cma.set_telephony_missed_reason(p_connection_id uuid, p_code text, p_label text,
                                                           p_counts_in_service_level boolean, p_needs_callback boolean)
returns void
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_system  text;
  v_kinds   text[];
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  select c.adapter, case when c.kind is not null then array[c.kind] else cma.connection_held_kinds_of(v_tenant, c.id) end
    into v_system, v_kinds
  from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id;
  if cardinality(v_kinds) > 0 and not ('telephony' = any (v_kinds)) then
    raise exception 'missed reasons belong to a telephony connection; this one is %', array_to_string(v_kinds, ' and ') using errcode = 'CMA04';
  end if;
  if coalesce(length(btrim(p_code)), 0) not between 1 and 60 then
    raise exception 'a missed-reason code has 1 to 60 characters' using errcode = 'CMA04';
  end if;
  if coalesce(length(btrim(p_label)), 0) not between 1 and 100 then
    raise exception 'a missed-reason label has 1 to 100 characters' using errcode = 'CMA04';
  end if;
  if p_counts_in_service_level is null or p_needs_callback is null then
    raise exception 'both switches must be true or false' using errcode = 'CMA04';
  end if;
  insert into cma.telephony_missed_reason (tenant_id, source_system, code, label, counts_in_service_level, needs_callback)
  values (v_tenant, v_system, btrim(p_code), btrim(p_label), p_counts_in_service_level, p_needs_callback)
  on conflict (tenant_id, source_system, code) do update
    set label = excluded.label, counts_in_service_level = excluded.counts_in_service_level,
        needs_callback = excluded.needs_callback
    where (cma.telephony_missed_reason.label, cma.telephony_missed_reason.counts_in_service_level, cma.telephony_missed_reason.needs_callback)
          is distinct from (excluded.label, excluded.counts_in_service_level, excluded.needs_callback);
exception when check_violation or not_null_violation then
  raise exception 'invalid missed reason: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.inbound_service(date,date,text)',
    'cma.inbound_today()',
    'cma.missed_callbacks()',
    'cma.missed_callbacks_summary()',
    'cma.missed_reasons()',
    'cma.connection_missed_reasons(uuid)',
    'cma.set_telephony_missed_reason(uuid,text,text,boolean,boolean)',
    -- the reads of an explicit tenant, which the functions above call in the caller's rights
    -- (row-level security keeps them to the current tenant whatever tenant they are given)
    'cma.inbound_calls_of(uuid,timestamptz,timestamptz)',
    'cma.inbound_service_of(uuid,date,date,text)',
    'cma.inbound_today_of(uuid)',
    'cma.missed_callbacks_of(uuid)',
    'cma.missed_callbacks_summary_of(uuid)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Reporting view: the catalog (configuration, no personal data)
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.telephony_missed_reason as
  select tenant_id, source_system, code, label, counts_in_service_level, needs_callback, updated_at
  from cma.telephony_missed_reason
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 10. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008i', 'Inbound service and callbacks: the missed-reason catalog, three telephony settings, inbound service per day, market, line and hour, today''s inbound with the calls waiting, missed calls not called back (the hash matched inside the tenant, never returned)')
on conflict (version) do nothing;

commit;
reset role;
