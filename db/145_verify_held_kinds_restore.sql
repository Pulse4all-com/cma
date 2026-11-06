-- =============================================================================================
-- 145_verify_held_kinds_restore.sql: verifies addition 0008zx, the kinds a connection holds restored and the Live
-- board's inbound poll at volume
-- =============================================================================================
-- Universal: no seed is assumed. Block S checks structure, privileges, the body of the kinds and the two indexes; block A
-- works on throwaway tenants inside subtransactions that are always rolled back, so nothing stays and the script runs in
-- dev and in prod; block E compares, on the database it runs in (the volume fixture locally, the seeds, dev's and prod's
-- own data), each changed read with its previous definition, kept here verbatim as a temporary function (the calls inside
-- it to a function 144 makes again pointed at that function's kept definition, so the before side runs only old code):
-- connection_held_kinds_of as 0008zl (118, the latest before 0008zr) and as 0008zr (132, for the timing);
-- inbound_calls_of, missed_callbacks_of and inbound_now() as 0008zr (132); missed_callbacks_summary_of and
-- inbound_today_of as 0008i (60). Every check writes one row, ok, FAIL or skip, and the last row is the verdict, because
-- Cloud SQL Studio shows no notices. Run as your own IAM login after 144_held_kinds_restore.sql, dev first, then prod.
-- Expected verdict, in dev and in prod: "0008zx verified | 145_verify_held_kinds_restore: <n> ok, 0 FAIL, <k> skip" (the
-- skips are active tenants without a person holding tenant.configure, or monitoring.live, whose E rows cannot run as the
-- application); provoked (verify.provoke true at the top): every row reads FAIL (block E's comparisons lose the previous
-- definition's first row, or say the set was empty) and the verdict PROVOKED, NOT A PASS. E7's times are the database's
-- own: in prod they are 131 part a's four inbound polls; locally on web/verify/perf-volume-fixture.sql at three times
-- prod's volume they are the measure of 144's header.
--   S  S1 the addition row after 0008zw; S2 one held-kinds function, its signature, result, language, volatility,
--      invoker, no setting, owner; S3 execute for the application only; S4 the body reads every table 0008zl's reads,
--      answers the six kinds in 0008zl's order, splits the connection fields by entity, and asks no big table with
--      exists(); S5 the two indexes on cma.telephony_call valid, with their columns and conditions; S6 the poll's
--      functions with their results as before, jit off on cma.inbound_calls_of, the new cma.missed_inbound_calls_of the
--      application's only
--   A  a throwaway tenant, its connections' kind not set: A1 per kind, a connection holding only that kind's rows answers
--      exactly it; A2 each table of the three kinds 0008zr lost answers its kind alone, a contact field answers crm; A3 a
--      connection holding none answers {}; A4 a connection holding all six answers them in 0008zl's order; A5 0008zl's
--      definition answers the same for every connection, and 0008zr's does not (it differs on the eleven connections
--      that hold reviews, assets or subscriptions); A6 the device-field guard takes a second device field on a connection
--      whose kind is not set (0008zr refused it); A7 cma.set_connection_kind refuses crm for a connection holding
--      subscriptions (CMA03) and takes subscriptions
--      a second throwaway tenant, its callers made for every edge of the list (missed twice; called back; called back and
--      missed again; a callback before the lookback; a callback at the same instant; a deleted callback; an answered
--      inbound call as the callback; a reason that needs no callback, alone and before one that does; waiting; ringing
--      past the waiting time; an uncounted line; a line without a market; a market on '*''s hours, one with split hours
--      and a holiday; older than the lookback; two missed calls at one instant; anonymous): A8 the list, A9 the
--      summary, A10 cma.inbound_now() and A11 cma.inbound_calls_of answer exactly what the previous definitions answer;
--      A12 the list is the one expected (who, how many missed, the market, the record link)
--   E  E1 every connection in the database (every tenant, as the owner): the same answer as 0008zl's definition, row for
--      row, and how many 0008zr's definition answered differently; E2 per active tenant, as the application acting as
--      the tenant's first person holding tenant.configure (133's E check): the same answer as 0008zl's, and no slower
--      than 0008zr's: the best of verify.timing_runs runs over every connection of the tenant, alternating, at most
--      verify.max_ratio times 0008zr's best plus verify.slack_ms (144 asks seven more questions per connection than
--      0008zr, each one index step; an exists() scan over a big table, the cost 0008zr removed, is a hundred times more);
--      per active tenant, as the application acting as its first person holding monitoring.live (131's choice): E3
--      cma.inbound_calls_of over the last 92 days, E4 cma.missed_callbacks_of in order, E5 the summary and E6
--      cma.inbound_now() the same as the previous definitions'; E7 131 part a's four inbound polls (inbound today, the
--      missed callbacks with their record links, the summary, inbound now, 131's own statements), each the best of
--      verify.timing_runs, under verify.max_poll_ms
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
select set_config('verify.timing_runs', '5', false);                 -- E2: runs of each definition, the best counts
select set_config('verify.max_ratio', '1.5', false);                 -- E2: 144's best at most this times 0008zr's best
select set_config('verify.slack_ms', '2', false);                    -- E2: plus this many milliseconds (the clock's noise)
select set_config('verify.max_poll_ms', '20', false);                -- E7: a poll's budget, as 131's (Decision log, 5 November 2026)

drop table if exists pg_temp.verify_0008zx;
create temporary table verify_0008zx (ord integer, check_name text, result text, detail text);
-- blocks A and E write their rows while acting as the application
grant select, insert on pg_temp.verify_0008zx to cma_app;

-- The previous definitions, verbatim, under pg_temp
-- connection_held_kinds_of as 0008zl (118_subscriptions.sql) defined it: the latest before 0008zr, the answer 0008zx restores
create function pg_temp.kinds_0008zl(p_tenant_id uuid, p_connection_id uuid)
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

-- connection_held_kinds_of as 0008zr (132_perf.sql) defined it: the one 144 replaces, for E2's timing and A5's contrast
create function pg_temp.kinds_0008zr(p_tenant_id uuid, p_connection_id uuid)
returns text[]
language sql stable
as $$
  select array_remove(array[
    case when (select min(x.record_type) from cma.crm_record x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.crm_contact x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.crm_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or exists (select 1 from cma.connection_pipeline x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_form x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_call_outcome x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.writeback_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox_channel x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_email_rule x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or (select min(x.source_kind) from cma.email_message x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.email_thread x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.crm_task x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or exists (select 1 from cma.connection_task_status x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_task_type x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'crm' end,
    case when (select min(x.source_id) from cma.telephony_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or exists (select 1 from cma.telephony_tag x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_number x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'telephony' end,
    case when exists (select 1 from cma.commerce_store x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or (select min(x.source_id) from cma.commerce_customer x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.commerce_order x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
         then 'commerce' end], null)
$$;

-- cma.inbound_calls_of as 0008zr (132_perf.sql) defined it
create function pg_temp.inbound_calls_of_0008zr(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
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
    select tc.*, n.name as n_name, m.code as m_code, coalesce(m.time_zone, (select s.tenant_zone from s)) as z,
           (tc.answered_at is null and tc.ended_at is null
            and tc.started_at >= now() - make_interval(mins => (select s.waiting_max from s))) as waiting
    from cma.telephony_call tc
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

-- cma.inbound_today_of as 0008i (60_inbound_service.sql) defined it (unchanged since; kept so the before side calls 0008zr's inbound_calls_of)
create function pg_temp.inbound_today_of_0008i(p_tenant_id uuid)
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
    cross join lateral pg_temp.inbound_calls_of_0008zr(p_tenant_id, s.today::timestamp at time zone s.zone,
                                            (s.today + 1)::timestamp at time zone s.zone) x
  ),
  w as (
    select count(*)::integer as n, floor(extract(epoch from now() - min(x.started_at)))::integer as longest
    from s
    cross join lateral pg_temp.inbound_calls_of_0008zr(p_tenant_id, now() - make_interval(mins => s.waiting_max), null) x
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

-- cma.missed_callbacks_of as 0008zr defined it
create function pg_temp.missed_callbacks_of_0008zr(p_tenant_id uuid)
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
    from pg_temp.inbound_calls_of_0008zr(p_tenant_id, now() - make_interval(days => (select s.lookback from s)), null) x
    join cma.telephony_call tc on tc.tenant_id = p_tenant_id and tc.id = x.call_id
    where x.reason_code is not null and tc.counterpart_hash is not null
  ),
  l as (
    select distinct on (m.h) m.*
    from m where m.needs_callback
    order by m.h, m.started_at desc, m.call_id desc
  ),
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
    where cb.next_callback_at is null
  ),
  n as (
    select k.call_id, count(m.call_id)::integer as missed
    from k
    left join m on m.h = k.h and (k.last_callback_at is null or m.started_at > k.last_callback_at)
    group by k.call_id
  )
  select k.call_id, k.connection_id, k.source_id, k.line_ref, k.line_name, k.market, k.reason_code, k.reason_label,
         k.started_at,
         n.missed,
         greatest(0, floor(extract(epoch from now() - k.started_at)))::integer,
         cma.business_seconds_of(p_tenant_id, nullif(k.market, 'unknown'), k.started_at, now())
  from k
  join n on n.call_id = k.call_id
  order by k.started_at, k.source_id
$$;

-- cma.missed_callbacks_summary_of as 0008i (60) defined it, the latest before 0008zx
create function pg_temp.missed_callbacks_summary_of_0008i(p_tenant_id uuid)
returns table (listed integer, anonymous_count integer, lookback_days integer)
language sql stable
as $$
  with s as (
    select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback
    from cma.tenant t where t.id = p_tenant_id
  )
  select (select count(*)::integer from pg_temp.missed_callbacks_of_0008zr(p_tenant_id)),
         (select count(*)::integer
          from pg_temp.inbound_calls_of_0008zr(p_tenant_id, now() - make_interval(days => s.lookback), null) x
          join cma.telephony_call tc on tc.tenant_id = p_tenant_id and tc.id = x.call_id
          where x.reason_code is not null and x.needs_callback and tc.counterpart_hash is null),
         s.lookback
  from s
$$;

-- cma.inbound_now() as 0008zr defined it
create function pg_temp.inbound_now_0008zr()
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_list   jsonb;
begin
  perform cma.assert_permission('monitoring.live');
  select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object('record_url', cma.record_url(m.connection_id, 'call', m.source_id)) order by m.started_at, m.source_id), '[]'::jsonb)
    into v_list
  from pg_temp.missed_callbacks_of_0008zr(v_tenant) m;
  return jsonb_build_object(
    'today', (select to_jsonb(x) from pg_temp.inbound_today_of_0008i(v_tenant) x),
    'callbacks', v_list,
    'summary', (select jsonb_build_object('listed', jsonb_array_length(v_list),
                                          'anonymous_count', (select count(*)::integer
                                                              from pg_temp.inbound_calls_of_0008zr(v_tenant, now() - make_interval(days => s.lookback), null) x
                                                              join cma.telephony_call tc on tc.tenant_id = v_tenant and tc.id = x.call_id
                                                              where x.reason_code is not null and x.needs_callback and tc.counterpart_hash is null),
                                          'lookback_days', s.lookback)
                from (select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback
                      from cma.tenant t where t.id = v_tenant) s));
end
$$;

-- Two set-returning statements compared: null when they answer the same rows (the same multiset; the same sequence when
-- p_ordered), else what differs; in provoke mode the old side loses its first row, so the comparison must fail (133's
-- v0008zr_diff)
create or replace function pg_temp.v0008zx_diff(p_new text, p_old text, p_ordered boolean default false)
returns text
language plpgsql
as $$
declare
  v_old text := p_old;
  v_n_new bigint; v_n_old bigint; v_only_new bigint; v_only_old bigint; v_same boolean := true;
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

-- A check row kept as four texts, for the block whose subtransaction is rolled back (its rows must outlive it)
create or replace function pg_temp.v0008zx_row(p_ord integer, p_name text, p_result text, p_detail text)
returns text[] language sql immutable as $$ select array[p_ord::text, p_name, p_result, p_detail] $$;

-- The tenant's first active person (the oldest) holding a permission, as 133 picks it
create or replace function pg_temp.v0008zx_user(p_tenant uuid, p_perm text)
returns uuid
language sql
as $$
  select u.id from cma.app_user u
  where u.tenant_id = p_tenant and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, p_perm)
  order by u.created_at, u.id limit 1
$$;

-- The SQLSTATE a statement raises, or ok
create or replace function pg_temp.v0008zx_code(p_sql text)
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

-- A statement's best time of p_runs in milliseconds, every row fetched (131's t0131_best_ms); -1 when it raises
create or replace function pg_temp.v0008zx_best_ms(p_sql text, p_runs integer)
returns numeric
language plpgsql
as $$
declare
  v_t0 timestamptz; v_ms numeric; v_best numeric; r record;
begin
  begin
    for i in 1 .. p_runs loop
      v_t0 := clock_timestamp();
      for r in execute p_sql loop
        null;
      end loop;
      v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
      v_best := least(coalesce(v_best, v_ms), v_ms);
    end loop;
  exception when others then
    return -1;
  end;
  return v_best;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- S. Structure, privileges, the body
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_ok boolean; v_txt text; v_src text; v_bad text := ''; t text; k text; v_pos integer; v_last integer := 0;
  v_fn regprocedure := to_regprocedure('cma.connection_held_kinds_of(uuid,uuid)');
begin
  v_ok := exists (select 1 from cma.schema_migration where version = '0008zx')
          and (select applied_at from cma.schema_migration where version = '0008zx')
              >= (select applied_at from cma.schema_migration where version = '0008zw');
  insert into verify_0008zx values (1, 'S1 addition 0008zx recorded, after 0008zw', case when v_ok and not v_provoke then 'ok' else 'FAIL' end,
    case when v_ok then 'cma.schema_migration holds 0008zx' else 'no 0008zx row, or one before 0008zw' end);

  select format('%s definition(s); returns %s, %s, %s, %s, config %s, owner %s',
                (select count(*) from pg_proc p where p.pronamespace = 'cma'::regnamespace and p.proname = 'connection_held_kinds_of'),
                format_type(p.prorettype, null), l.lanname,
                case p.provolatile when 's' then 'stable' when 'i' then 'immutable' else 'volatile' end,
                case when p.prosecdef then 'definer' else 'invoker' end, coalesce(array_to_string(p.proconfig, ','), 'none'),
                pg_get_userbyid(p.proowner))
    into v_txt
  from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = v_fn;
  v_ok := v_txt = '1 definition(s); returns text[], sql, stable, invoker, config none, owner cma_owner';
  insert into verify_0008zx values (2, 'S2 one function (uuid, uuid), text[], sql, stable, invoker, no setting, owned by cma_owner (as 0008zr)',
    case when v_ok and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_txt, 'no function'));

  v_ok := v_fn is not null
          and has_function_privilege('cma_app', v_fn, 'execute')
          and not exists (select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                          where p.oid = v_fn and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          and not has_function_privilege('cma_readonly', v_fn, 'execute');
  insert into verify_0008zx values (3, 'S3 executable by the application, not by PUBLIC nor the readers', case when v_ok and not v_provoke then 'ok' else 'FAIL' end,
    'revoked from public, granted to cma_app');

  select p.prosrc into v_src from pg_proc p where p.oid = v_fn;
  -- every table 0008zl's definition reads
  foreach t in array array['crm_record', 'crm_contact', 'crm_call', 'connection_pipeline', 'connection_form', 'connection_call_outcome',
                           'connection_field', 'writeback_field', 'connection_inbox', 'connection_inbox_channel', 'connection_email_rule',
                           'email_message', 'email_thread', 'crm_task', 'connection_task_status', 'connection_task_type', 'telephony_call',
                           'telephony_tag', 'telephony_number', 'commerce_store', 'commerce_customer', 'commerce_order', 'review_channel',
                           'review', 'device', 'subscription', 'subscription_event'] loop
    if coalesce(v_src, '') !~ ('cma\.' || t || ' x ') then
      v_bad := v_bad || 'reads no ' || t || '; ';
    end if;
  end loop;
  -- the six kinds in 0008zl's order
  foreach k in array array['crm', 'telephony', 'commerce', 'reviews', 'assets', 'subscriptions'] loop
    v_pos := strpos(coalesce(v_src, ''), 'then ''' || k || ''' end');
    if v_pos = 0 or v_pos < v_last then
      v_bad := v_bad || 'kind ' || k || ' missing or out of order; ';
    end if;
    v_last := greatest(v_last, v_pos);
  end loop;
  -- the connection fields: device and device_component as assets, every other entity as crm
  if coalesce(v_src, '') !~ 'x\.entity not in \(''device'', ''device_component''\)' or coalesce(v_src, '') !~ 'x\.entity in \(''device'', ''device_component''\)' then
    v_bad := v_bad || 'the connection fields not split by entity; ';
  end if;
  -- no big table asked with exists() (0008zr's lesson: it reads the whole table when the connection holds no row)
  foreach t in array array['crm_record', 'crm_contact', 'crm_call', 'email_message', 'email_thread', 'crm_task', 'telephony_call',
                           'commerce_customer', 'commerce_order', 'review', 'device', 'subscription', 'subscription_event'] loop
    if coalesce(v_src, '') ~ ('exists \(select 1 from cma\.' || t || ' x ') then
      v_bad := v_bad || t || ' by exists(); ';
    end if;
  end loop;
  insert into verify_0008zx values (4, 'S4 the body reads 0008zl''s 27 tables, answers its six kinds in its order, splits the fields by entity, asks no big table with exists()',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, case when v_bad = '' then 'crm, telephony, commerce, reviews, assets, subscriptions' else v_bad end);

  -- S5 the two indexes, created concurrently before 144, valid and as 144's header writes them
  select string_agg(c.relname || case when i.indisvalid then '' else ' (invalid)' end, ', ' order by c.relname) into v_txt
  from pg_index i join pg_class c on c.oid = i.indexrelid
  where i.indrelid = 'cma.telephony_call'::regclass and c.relname in ('telephony_call_missed_inbound_idx', 'telephony_call_callback_idx');
  v_ok := (select count(*) from pg_index i join pg_class c on c.oid = i.indexrelid
           where i.indrelid = 'cma.telephony_call'::regclass and i.indisvalid
             and ((c.relname = 'telephony_call_missed_inbound_idx'
                   and pg_get_indexdef(c.oid) = 'CREATE INDEX telephony_call_missed_inbound_idx ON cma.telephony_call USING btree (tenant_id, started_at) WHERE ((direction = ''inbound''::text) AND (answered_at IS NULL) AND (source_deleted_at IS NULL))')
               or (c.relname = 'telephony_call_callback_idx'
                   and pg_get_indexdef(c.oid) = 'CREATE INDEX telephony_call_callback_idx ON cma.telephony_call USING btree (tenant_id, counterpart_hash, started_at) WHERE ((counterpart_hash IS NOT NULL) AND (source_deleted_at IS NULL) AND ((direction = ''outbound''::text) OR ((direction = ''inbound''::text) AND (answered_at IS NOT NULL))))'))) = 2;
  insert into verify_0008zx values (5, 'S5 the indexes telephony_call_missed_inbound_idx and telephony_call_callback_idx valid, with their columns and conditions',
    case when v_ok and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_txt, 'neither index exists: create them from the Terminal first (144''s header)'));

  -- S6 the poll's functions: their results as before, jit off kept, the new one the application's only
  v_bad := '';
  if pg_get_function_result('cma.missed_callbacks_of(uuid)'::regprocedure) <> 'TABLE(call_id uuid, connection_id uuid, source_id text, line_ref text, line_name text, market text, reason_code text, reason_label text, started_at timestamp with time zone, missed_count integer, waiting_seconds integer, waiting_business_seconds integer)' then
    v_bad := v_bad || 'missed_callbacks_of''s result; ';
  end if;
  if pg_get_function_result('cma.missed_callbacks_summary_of(uuid)'::regprocedure) <> 'TABLE(listed integer, anonymous_count integer, lookback_days integer)'
     or pg_get_function_result('cma.inbound_now()'::regprocedure) <> 'jsonb' then
    v_bad := v_bad || 'the summary''s or inbound_now''s result; ';
  end if;
  if pg_get_function_result('cma.inbound_calls_of(uuid,timestamptz,timestamptz)'::regprocedure) <> 'TABLE(call_id uuid, connection_id uuid, source_system text, source_id text, line_key text, line_ref text, line_name text, market text, zone text, started_at timestamp with time zone, business_date date, local_hour integer, is_answered boolean, is_waiting boolean, answer_seconds numeric, reason_code text, reason_label text, needs_callback boolean, in_service_level boolean)'
     or not 'jit=off' = any (coalesce((select p.proconfig from pg_proc p where p.oid = 'cma.inbound_calls_of(uuid,timestamptz,timestamptz)'::regprocedure), '{}'::text[])) then
    v_bad := v_bad || 'inbound_calls_of''s result or its jit off; ';
  end if;
  foreach t in array array['cma.missed_inbound_calls_of(uuid,timestamptz)', 'cma.missed_callbacks_of(uuid)', 'cma.missed_callbacks_summary_of(uuid)',
                           'cma.inbound_now()', 'cma.inbound_calls_of(uuid,timestamptz,timestamptz)'] loop
    if to_regprocedure(t) is null
       or not has_function_privilege('cma_app', to_regprocedure(t), 'execute')
       or has_function_privilege('cma_readonly', to_regprocedure(t), 'execute')
       or exists (select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = to_regprocedure(t) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
       or (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(t)) then
      v_bad := v_bad || t || ' privileges; ';
    end if;
  end loop;
  insert into verify_0008zx values (6, 'S6 the poll''s functions answer the same columns as before, inbound_calls_of keeps jit off, all five the application''s only and invoker',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, case when v_bad = '' then 'missed_inbound_calls_of new; the four others as before' else v_bad end);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- A. Behaviour on a throwaway tenant, rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t uuid; v_admin uuid;
  c_none uuid; c_crm uuid; c_tel uuid; c_com uuid; c_rev uuid; c_ast uuid; c_sub uuid;
  c_rch uuid; c_rrv uuid; c_dev uuid; c_dfl uuid; c_cfl uuid; c_sbs uuid; c_sbe uuid; c_ctf uuid; c_mix uuid;
  v_ch uuid; v_txt text; v_diff text; v_n integer;
  rows_ text[] := '{}';
begin
  begin
    v_t := cma.create_tenant('verify-0008zx', 'Verify 0008zx', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-0008zx-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, v_admin, ar.id from cma.app_role ar
    where ar.tenant_id = v_t and exists (select 1 from cma.role_permission rp where rp.tenant_id = v_t and rp.role_id = ar.id and rp.permission_key = 'tenant.configure')
    order by ar.key limit 1;
    insert into cma.device_component_kind (tenant_id, key, name) values (v_t, 'pads', 'Pads');
    -- every connection's kind not set: the CMA reads it from the rows
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'None', 'zx-none') returning id into c_none;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'CRM', 'zx-crm') returning id into c_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'Telephony', 'zx-tel') returning id into c_tel;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'Commerce', 'zx-com') returning id into c_com;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'Reviews', 'zx-rev') returning id into c_rev;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'Assets', 'zx-ast') returning id into c_ast;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'Subscriptions', 'zx-sub') returning id into c_sub;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'Review channel', 'zx-rch') returning id into c_rch;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'Review', 'zx-rrv') returning id into c_rrv;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'Device', 'zx-dev') returning id into c_dev;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'Device field', 'zx-dfl') returning id into c_dfl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'Component field', 'zx-cfl') returning id into c_cfl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'Subscription', 'zx-sbs') returning id into c_sbs;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'Subscription event', 'zx-sbe') returning id into c_sbe;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'Contact field', 'zx-ctf') returning id into c_ctf;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyx', 'All six', 'zx-mix') returning id into c_mix;

    -- one kind per connection, each from its own tables
    insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id) values (v_t, c_crm, 'verifyx', 'c-1');
    insert into cma.telephony_tag (tenant_id, connection_id, tag_ref, name) values (v_t, c_tel, 't-1', 'Tag');
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id) values (v_t, c_com, 'verifyx', 'cu-1');
    insert into cma.review_channel (tenant_id, connection_id, source_id, name) values (v_t, c_rev, 'ch-1', 'Channel') returning id into v_ch;
    insert into cma.review (tenant_id, connection_id, review_channel_id, source_system, source_id, review_type, state, is_published, rating, submitted_at)
    values (v_t, c_rev, v_ch, 'verifyx', 'r-1', 'service', 'active', true, 5, now());
    insert into cma.device (tenant_id, connection_id, source_system, source_id) values (v_t, c_ast, 'verifyx', 'd-1');
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, status) values (v_t, c_sub, 'verifyx', 's-1', 'active');
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at)
    values (v_t, c_sub, 'verifyx', 'e-1', 's-1', 'renewed', now());
    -- each table of the three kinds 0008zr lost, alone on its connection; a contact field for crm
    insert into cma.review_channel (tenant_id, connection_id, source_id, name) values (v_t, c_rch, 'ch-2', 'Channel 2');
    insert into cma.review (tenant_id, connection_id, review_channel_id, source_system, source_id, review_type, state, is_published, rating, submitted_at)
    values (v_t, c_rrv, v_ch, 'verifyx', 'r-2', 'service', 'active', true, 4, now());
    insert into cma.device (tenant_id, connection_id, source_system, source_id) values (v_t, c_dev, 'verifyx', 'd-2');
    insert into cma.connection_field (tenant_id, connection_id, entity, field, ref_system, source_property) values (v_t, c_dfl, 'device', 'serial', '', 'aed_sn');
    insert into cma.connection_field (tenant_id, connection_id, entity, field, ref_system, source_property) values (v_t, c_cfl, 'device_component', 'serial', 'pads', 'pads_sn');
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, status) values (v_t, c_sbs, 'verifyx', 's-2', 'paused');
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at)
    values (v_t, c_sbe, 'verifyx', 'e-2', 's-9', 'canceled', now());
    insert into cma.connection_field (tenant_id, connection_id, entity, field, ref_system, source_property) values (v_t, c_ctf, 'contact', 'country', '', 'country');
    -- all six on one connection (no device field: the guard keeps those to an asset register)
    insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id) values (v_t, c_mix, 'verifyx', 'c-9');
    insert into cma.telephony_tag (tenant_id, connection_id, tag_ref, name) values (v_t, c_mix, 't-9', 'Tag 9');
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id) values (v_t, c_mix, 'verifyx', 'cu-9');
    insert into cma.review_channel (tenant_id, connection_id, source_id, name) values (v_t, c_mix, 'ch-9', 'Channel 9');
    insert into cma.device (tenant_id, connection_id, source_system, source_id) values (v_t, c_mix, 'verifyx', 'd-9');
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, status) values (v_t, c_mix, 'verifyx', 's-9', 'active');

    -- read as the application, acting as the tenant's admin
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_admin::text, true);

    -- A1 per kind: exactly its kind
    v_txt := array_to_string(cma.connection_held_kinds_of(v_t, c_crm), ',') || ' ' || array_to_string(cma.connection_held_kinds_of(v_t, c_tel), ',')
             || ' ' || array_to_string(cma.connection_held_kinds_of(v_t, c_com), ',') || ' ' || array_to_string(cma.connection_held_kinds_of(v_t, c_rev), ',')
             || ' ' || array_to_string(cma.connection_held_kinds_of(v_t, c_ast), ',') || ' ' || array_to_string(cma.connection_held_kinds_of(v_t, c_sub), ',');
    rows_ := rows_ || pg_temp.v0008zx_row(201, 'A1 a connection holding only one kind''s rows answers exactly that kind, for each of the six',
      case when v_txt = 'crm telephony commerce reviews assets subscriptions' and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_txt, 'null'));

    -- A2 each table of the three kinds 0008zr lost, alone; a contact field
    v_txt := 'review_channel:' || array_to_string(cma.connection_held_kinds_of(v_t, c_rch), ',')
             || ' review:' || array_to_string(cma.connection_held_kinds_of(v_t, c_rrv), ',')
             || ' device:' || array_to_string(cma.connection_held_kinds_of(v_t, c_dev), ',')
             || ' device_field:' || array_to_string(cma.connection_held_kinds_of(v_t, c_dfl), ',')
             || ' component_field:' || array_to_string(cma.connection_held_kinds_of(v_t, c_cfl), ',')
             || ' subscription:' || array_to_string(cma.connection_held_kinds_of(v_t, c_sbs), ',')
             || ' subscription_event:' || array_to_string(cma.connection_held_kinds_of(v_t, c_sbe), ',')
             || ' contact_field:' || array_to_string(cma.connection_held_kinds_of(v_t, c_ctf), ',');
    rows_ := rows_ || pg_temp.v0008zx_row(202, 'A2 each table of reviews, assets and subscriptions answers its kind alone; a device field is assets, a contact field crm',
      case when v_txt = 'review_channel:reviews review:reviews device:assets device_field:assets component_field:assets subscription:subscriptions '
                        || 'subscription_event:subscriptions contact_field:crm'
                and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_txt, 'null'));

    -- A3 none
    v_txt := coalesce(cma.connection_held_kinds_of(v_t, c_none)::text, 'null');
    rows_ := rows_ || pg_temp.v0008zx_row(203, 'A3 a connection holding none answers {} (not null)',
      case when v_txt = '{}' and not v_provoke then 'ok' else 'FAIL' end, v_txt);

    -- A4 all six, in 0008zl's order
    v_txt := array_to_string(cma.connection_held_kinds_of(v_t, c_mix), ',');
    rows_ := rows_ || pg_temp.v0008zx_row(204, 'A4 a connection holding all six answers them in 0008zl''s order',
      case when v_txt = 'crm,telephony,commerce,reviews,assets,subscriptions' and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_txt, 'null'));

    -- A5 0008zl's answer for every connection of the tenant; 0008zr's differs where reviews, assets or subscriptions are held
    v_diff := pg_temp.v0008zx_diff(format('select c.id, cma.connection_held_kinds_of(c.tenant_id, c.id) from cma.integration_connection c where c.tenant_id = %L', v_t),
                                   format('select c.id, pg_temp.kinds_0008zl(c.tenant_id, c.id) from cma.integration_connection c where c.tenant_id = %L', v_t));
    select count(*) into v_n from cma.integration_connection c
    where c.tenant_id = v_t and pg_temp.kinds_0008zr(c.tenant_id, c.id) is distinct from pg_temp.kinds_0008zl(c.tenant_id, c.id);
    rows_ := rows_ || pg_temp.v0008zx_row(205, 'A5 the same answer as 0008zl''s definition for the 16 connections; 0008zr''s differs on the 11 that hold reviews, assets or subscriptions',
      case when v_diff is null and v_n = 11 and not v_provoke then 'ok' else 'FAIL' end,
      coalesce(v_diff, '16 connections the same as 0008zl''s') || format('; 0008zr''s definition differs on %s', v_n));

    -- A6 the device-field guard: a second device field on the connection holding one, its kind not set (0008zr counted the
    --    first field as crm and refused the second, CMA04)
    perform set_config('role', 'cma_owner', true);
    v_txt := pg_temp.v0008zx_code(format('insert into cma.connection_field (tenant_id, connection_id, entity, field, ref_system, source_property) values (%L, %L, ''device'', ''model'', '''', ''aed_model'')', v_t, c_dfl))
             || ' ' || pg_temp.v0008zx_code(format('insert into cma.connection_field (tenant_id, connection_id, entity, field, ref_system, source_property) values (%L, %L, ''contact'', ''country'', '''', ''country'')', v_t, c_dfl));
    perform set_config('role', 'cma_app', true);
    rows_ := rows_ || pg_temp.v0008zx_row(206, 'A6 a connection holding a device field, its kind not set, takes a second device field and refuses a contact field (CMA04)',
      case when v_txt = 'ok CMA04' and not v_provoke then 'ok' else 'FAIL' end, v_txt);

    -- A7 the kind: crm refused for a connection holding subscriptions (CMA03), subscriptions taken
    v_txt := pg_temp.v0008zx_code(format('select cma.set_connection_kind(%L, ''crm'')', c_sub))
             || ' ' || pg_temp.v0008zx_code(format('select cma.set_connection_kind(%L, ''subscriptions'')', c_sub));
    v_txt := v_txt || ' ' || coalesce((select c.kind from cma.integration_connection c where c.tenant_id = v_t and c.id = c_sub), '-');
    rows_ := rows_ || pg_temp.v0008zx_row(207, 'A7 set_connection_kind refuses crm for a connection holding subscriptions (CMA03) and takes subscriptions',
      case when v_txt = 'CMA03 ok subscriptions' and not v_provoke then 'ok' else 'FAIL' end, v_txt);

    raise exception using errcode = 'CMAOK';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || pg_temp.v0008zx_row(299, 'A block ended early', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 160));
  end;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0008zx (ord, check_name, result, detail)
  select rows_[4 * i - 3]::integer, rows_[4 * i - 2], rows_[4 * i - 1], rows_[4 * i] from generate_series(1, cardinality(rows_) / 4) i;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- A (the poll). A throwaway tenant whose callers cover every edge of the missed-callbacks list, rolled back
-- ---------------------------------------------------------------------------------------------
-- Each caller (an invented 64-hex hash, never made from a number) in minutes before now; NL on split hours with a
-- holiday yesterday, GB on '*''s hours; lookback 3 days and waiting 30 minutes (the defaults):
--   c01 c02  missed twice                                           listed, 2 missed
--   c03 c04  missed, then called back                               not listed
--   c05-c07  missed, called back, missed again (GB)                  listed, 1 missed (the call back resets the count)
--   c08      anonymous, missed                                      the summary's anonymous count
--   c09      ringing now                                            not listed (waiting)
--   c10      missed with a reason that needs no callback            not listed
--   c11 c12  that reason, then a missed call needing one            listed, 2 missed (every missed call counts)
--   c13      missed on a line that does not count                   not listed
--   c14 c15  missed, then an answered inbound call                  not listed (the answered call is the callback)
--   c16-c18  called before the lookback, missed twice in it         listed, 2 missed
--   c19 c20  missed and called at the same instant                  listed, 1 missed (neither before nor after)
--   c21 c22  missed, then a callback deleted at the source          listed, 1 missed
--   c23      missed on a line without a market                      listed, the market unknown, no office seconds
--   c24      missed before the lookback                             not listed
--   c25-c27  missed, called back, then missed with a no-callback reason  not listed
--   c28 c29  missed twice at one instant                            listed once (the greater id), 2 missed
--   c30      not answered, not ended, past the waiting time (GB)    listed, 1 missed
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t uuid; v_sup uuid; v_tel uuid; v_txt text; v_diff text;
  rows_ text[] := '{}';
begin
  begin
    v_t := cma.create_tenant('verify-0008zx-poll', 'Verify 0008zx poll', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-0008zx-supervisor@example.invalid', 'supervisor') returning id into v_sup;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, v_sup, ar.id from cma.app_role ar
    where ar.tenant_id = v_t and exists (select 1 from cma.role_permission rp where rp.tenant_id = v_t and rp.role_id = ar.id and rp.permission_key = 'monitoring.live')
    order by ar.key limit 1;
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency) values
      (v_t, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR'), (v_t, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    insert into cma.business_hours (tenant_id, market, weekday, opens_at, closes_at)
    select v_t, x.market, d, x.opens::time, x.closes::time
    from generate_series(1, 7) d
    cross join (values ('NL', '09:00', '12:00'), ('NL', '13:00', '17:00'), ('*', '08:00', '20:00')) x(market, opens, closes);
    insert into cma.business_holiday (tenant_id, market, day, name) values (v_t, 'NL', (now() at time zone 'Europe/Amsterdam')::date - 1, 'Holiday');
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, settings)
    values (v_t, 'verifytel', 'Telephony', 'acct-zx', 'telephony', '{"record_url_call": "https://example.invalid/{account}/call/{id}"}')
    returning id into v_tel;
    insert into cma.telephony_number (tenant_id, connection_id, number_ref, name, market, is_counted) values
      (v_t, v_tel, 'line-nl', 'Line NL', 'NL', true), (v_t, v_tel, 'line-gb', 'Line GB', 'GB', true),
      (v_t, v_tel, 'line-off', 'Line off', 'NL', false), (v_t, v_tel, 'line-x', 'Line X', null, true);
    insert into cma.telephony_missed_reason (tenant_id, source_system, code, label, counts_in_service_level, needs_callback)
    values (v_t, 'verifytel', 'ivr', 'Menu', false, false);
    -- source id, direction, minutes ago, answered, ended, line, caller (null: anonymous), reason, deleted at the source, id
    insert into cma.telephony_call (id, tenant_id, connection_id, source_system, source_id, direction, status, missed_reason, started_at,
                                    answered_at, ended_at, number_ref, counterpart_hash, source_version_at, source_deleted_at)
    select coalesce(c.id, uuidv7()), v_t, v_tel, 'verifytel', c.src, c.dir, case when c.ans then 'done' else 'missed' end,
           case when c.dir = 'inbound' and not c.ans and c.ended then c.reason end,
           now() - make_interval(mins => c.ago),
           case when c.ans then now() - make_interval(mins => c.ago) + interval '10 seconds' end,
           case when c.ended then now() - make_interval(mins => c.ago) + interval '60 seconds' end,
           c.line, case when c.caller is not null then encode(sha256(('verify-0008zx-' || c.caller)::bytea), 'hex') end,
           now() - make_interval(mins => c.ago), case when c.deleted then now() end
    from (values
      ('c01', 'inbound',  120,  false, true,  'line-nl',  'h1',  'no_answer', false, null::uuid),
      ('c02', 'inbound',  60,   false, true,  'line-nl',  'h1',  'no_answer', false, null),
      ('c03', 'inbound',  120,  false, true,  'line-nl',  'h2',  'no_answer', false, null),
      ('c04', 'outbound', 90,   true,  true,  'line-nl',  'h2',  null,        false, null),
      ('c05', 'inbound',  300,  false, true,  'line-gb',  'h3',  'no_answer', false, null),
      ('c06', 'outbound', 240,  true,  true,  'line-gb',  'h3',  null,        false, null),
      ('c07', 'inbound',  60,   false, true,  'line-gb',  'h3',  'no_answer', false, null),
      ('c08', 'inbound',  60,   false, true,  'line-nl',  null,  'no_answer', false, null),
      ('c09', 'inbound',  2,    false, false, 'line-nl',  'h5',  null,        false, null),
      ('c10', 'inbound',  60,   false, true,  'line-nl',  'h6',  'ivr',       false, null),
      ('c11', 'inbound',  120,  false, true,  'line-nl',  'h7',  'ivr',       false, null),
      ('c12', 'inbound',  60,   false, true,  'line-nl',  'h7',  'no_answer', false, null),
      ('c13', 'inbound',  60,   false, true,  'line-off', 'h8',  'no_answer', false, null),
      ('c14', 'inbound',  60,   false, true,  'line-nl',  'h9',  'no_answer', false, null),
      ('c15', 'inbound',  30,   true,  true,  'line-nl',  'h9',  null,        false, null),
      ('c16', 'outbound', 7200, true,  true,  'line-nl',  'h10', null,        false, null),
      ('c17', 'inbound',  120,  false, true,  'line-nl',  'h10', 'no_answer', false, null),
      ('c18', 'inbound',  60,   false, true,  'line-nl',  'h10', 'no_answer', false, null),
      ('c19', 'inbound',  120,  false, true,  'line-nl',  'h11', 'no_answer', false, null),
      ('c20', 'outbound', 120,  true,  true,  'line-nl',  'h11', null,        false, null),
      ('c21', 'inbound',  60,   false, true,  'line-nl',  'h12', 'no_answer', false, null),
      ('c22', 'outbound', 30,   true,  true,  'line-nl',  'h12', null,        true,  null),
      ('c23', 'inbound',  60,   false, true,  'line-x',   'h13', 'no_answer', false, null),
      ('c24', 'inbound',  5760, false, true,  'line-nl',  'h14', 'no_answer', false, null),
      ('c25', 'inbound',  120,  false, true,  'line-nl',  'h15', 'no_answer', false, null),
      ('c26', 'outbound', 60,   true,  true,  'line-nl',  'h15', null,        false, null),
      ('c27', 'inbound',  30,   false, true,  'line-nl',  'h15', 'ivr',       false, null),
      ('c28', 'inbound',  90,   false, true,  'line-nl',  'h16', 'no_answer', false, '00000000-0000-7000-8000-000000000028'::uuid),
      ('c29', 'inbound',  90,   false, true,  'line-nl',  'h16', 'no_answer', false, '00000000-0000-7000-8000-000000000029'::uuid),
      ('c30', 'inbound',  40,   false, false, 'line-gb',  'h19', null,        false, null)
    ) c(src, dir, ago, ans, ended, line, caller, reason, deleted, id);

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_sup::text, true);

    -- A8 the list, in order
    v_diff := pg_temp.v0008zx_diff(format('select * from cma.missed_callbacks_of(%L)', v_t), format('select * from pg_temp.missed_callbacks_of_0008zr(%L)', v_t), true);
    rows_ := rows_ || pg_temp.v0008zx_row(251, 'A8 the missed callbacks of the made callers, in order: the same as 0008zr''s',
      case when v_diff is null and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_diff, 'the same rows in the same order'));
    -- A9 the summary
    v_diff := pg_temp.v0008zx_diff(format('select * from cma.missed_callbacks_summary_of(%L)', v_t), format('select * from pg_temp.missed_callbacks_summary_of_0008i(%L)', v_t));
    rows_ := rows_ || pg_temp.v0008zx_row(252, 'A9 the summary of the made callers: the same as 0008i''s',
      case when v_diff is null and not v_provoke then 'ok' else 'FAIL' end,
      coalesce(v_diff, (select format('listed %s, anonymous %s, lookback %s days', x.listed, x.anonymous_count, x.lookback_days) from cma.missed_callbacks_summary_of(v_t) x)));
    -- A10 inbound now, the board's one statement
    v_diff := pg_temp.v0008zx_diff('select cma.inbound_now()', 'select pg_temp.inbound_now_0008zr()');
    rows_ := rows_ || pg_temp.v0008zx_row(253, 'A10 inbound_now() for the made callers: the same JSON as 0008zr''s',
      case when v_diff is null and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_diff, 'the same today, callbacks and summary'));
    -- A11 inbound_calls_of over the last 92 days and over the lookback
    v_diff := coalesce(pg_temp.v0008zx_diff(format('select * from cma.inbound_calls_of(%L, now() - interval ''92 days'', null)', v_t),
                                            format('select * from pg_temp.inbound_calls_of_0008zr(%L, now() - interval ''92 days'', null)', v_t)),
                       pg_temp.v0008zx_diff(format('select * from cma.inbound_calls_of(%L, now() - interval ''3 days'', now())', v_t),
                                            format('select * from pg_temp.inbound_calls_of_0008zr(%L, now() - interval ''3 days'', now())', v_t)));
    rows_ := rows_ || pg_temp.v0008zx_row(254, 'A11 inbound_calls_of for the made calls over 92 days and over the lookback: the same as 0008zr''s',
      case when v_diff is null and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_diff, 'the same rows'));
    -- A12 the list expected: who, how many missed, the market, office seconds or none, the record link
    select string_agg(e ->> 'source_id' || ':' || (e ->> 'missed_count') || ':' || (e ->> 'market') || ':'
                      || case when e ->> 'waiting_business_seconds' is null then '-' else 'n' end || ':'
                      || case when e ->> 'record_url' = 'https://example.invalid/acct-zx/call/' || (e ->> 'source_id') then 'u' else '-' end,
                      ' ' order by e ->> 'source_id')
           || ' | ' || (j -> 'summary' ->> 'listed') || '/' || (j -> 'summary' ->> 'anonymous_count') || '/' || (j -> 'summary' ->> 'lookback_days')
      into v_txt
    from (select cma.inbound_now() as j) q
    cross join lateral jsonb_array_elements(q.j -> 'callbacks') e
    group by q.j;
    rows_ := rows_ || pg_temp.v0008zx_row(255, 'A12 the list is the one expected: nine callers, their missed counts, markets, office seconds and record links; one anonymous',
      case when v_txt = 'c02:2:NL:n:u c07:1:GB:n:u c12:2:NL:n:u c18:2:NL:n:u c19:1:NL:n:u c21:1:NL:n:u c23:1:unknown:-:u c29:2:NL:n:u c30:1:GB:n:u | 9/1/3'
                and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_txt, 'no list'));

    raise exception using errcode = 'CMAOK';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || pg_temp.v0008zx_row(299, 'A (the poll) block ended early', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 160));
  end;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0008zx (ord, check_name, result, detail)
  select rows_[4 * i - 3]::integer, rows_[4 * i - 2], rows_[4 * i - 1], rows_[4 * i] from generate_series(1, cardinality(rows_) / 4) i;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- E. Every connection in the database: 0008zl's answer, and no slower than 0008zr's
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_runs integer := greatest(1, current_setting('verify.timing_runs')::integer);
  v_ratio numeric := current_setting('verify.max_ratio')::numeric;
  v_slack numeric := current_setting('verify.slack_ms')::numeric;
  t record;
  v_user uuid; v_diff text; v_n integer; v_k integer; v_tenants integer; v_ord integer := 300; v_err text;
  v_sql_new text; v_sql_old text; v_t0 timestamptz; v_ms numeric; v_best_new numeric; v_best_old numeric; v_sum bigint; i integer;
  v_poll numeric := current_setting('verify.max_poll_ms')::numeric;
  v_checks text[]; v_news text[]; v_olds text[];
begin
  -- E1 every connection of every tenant, as the owner (it reads every row): the same answer as 0008zl's definition
  v_ord := v_ord + 1;
  begin
    v_diff := pg_temp.v0008zx_diff('select c.id, cma.connection_held_kinds_of(c.tenant_id, c.id) from cma.integration_connection c',
                                   'select c.id, pg_temp.kinds_0008zl(c.tenant_id, c.id) from cma.integration_connection c');
    select count(*), count(distinct c.tenant_id), count(*) filter (where pg_temp.kinds_0008zr(c.tenant_id, c.id) is distinct from pg_temp.kinds_0008zl(c.tenant_id, c.id))
      into v_n, v_tenants, v_k
    from cma.integration_connection c;
    insert into verify_0008zx values (v_ord, 'E1 every connection in the database: the same answer as 0008zl''s definition',
      case when v_diff is null then 'ok' else 'FAIL' end,
      coalesce(v_diff, format('%s connection(s) of %s tenant(s), the same', v_n, v_tenants))
      || format('; 0008zr''s definition answered %s of them differently', v_k));
  exception when others then
    insert into verify_0008zx values (v_ord, 'E1 every connection in the database: the same answer as 0008zl''s definition', 'FAIL',
      'error ' || sqlstate || ': ' || left(sqlerrm, 120));
  end;

  -- E2 per active tenant, as the application (133's E check): the same answer, and the time against 0008zr's
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', '', true);
    v_user := pg_temp.v0008zx_user(t.id, 'tenant.configure');
    v_ord := v_ord + 1;
    if v_user is null then
      insert into verify_0008zx values (v_ord, 'E2 ' || t.slug, 'skip', 'no active person holds tenant.configure: nothing compared or timed');
      continue;
    end if;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_user::text, true);
    v_diff := null; v_err := null; v_best_new := null; v_best_old := null;
    begin
      v_diff := pg_temp.v0008zx_diff(format('select c.id, cma.connection_held_kinds_of(c.tenant_id, c.id) from cma.integration_connection c where c.tenant_id = %L', t.id),
                                     format('select c.id, pg_temp.kinds_0008zl(c.tenant_id, c.id) from cma.integration_connection c where c.tenant_id = %L', t.id));
      select count(*) into v_n from cma.integration_connection c where c.tenant_id = t.id;
      -- every connection's answer used (a sum of the lengths), so no plan can leave the call out
      v_sql_new := format('select coalesce(sum(cardinality(cma.connection_held_kinds_of(c.tenant_id, c.id))), 0) from cma.integration_connection c where c.tenant_id = %L', t.id);
      v_sql_old := format('select coalesce(sum(cardinality(pg_temp.kinds_0008zr(c.tenant_id, c.id))), 0) from cma.integration_connection c where c.tenant_id = %L', t.id);
      for i in 1 .. v_runs loop
        v_t0 := clock_timestamp();
        execute v_sql_new into v_sum;
        v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
        v_best_new := least(coalesce(v_best_new, v_ms), v_ms);
        v_t0 := clock_timestamp();
        execute v_sql_old into v_sum;
        v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
        v_best_old := least(coalesce(v_best_old, v_ms), v_ms);
      end loop;
    exception when others then
      v_err := 'error ' || sqlstate || ': ' || left(sqlerrm, 120);
    end;
    insert into verify_0008zx values (v_ord, 'E2 the same answer as 0008zl''s, no slower than 0008zr''s, as the application (' || t.slug || ')',
      case when v_err is null and v_diff is null and v_best_new <= v_best_old * v_ratio + v_slack and not v_provoke then 'ok' else 'FAIL' end,
      coalesce(v_err, v_diff, format('%s connection(s), the same; best of %s: %s ms against 0008zr''s %s ms (at most %s)', v_n, v_runs,
                                     round(v_best_new, 2), round(v_best_old, 2), round(v_best_old * v_ratio + v_slack, 2))));
  end loop;

  -- E3 to E7 per active tenant, as the application acting as its first person holding monitoring.live (131's choice)
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', '', true);
    v_user := pg_temp.v0008zx_user(t.id, 'monitoring.live');
    if v_user is null then
      v_ord := v_ord + 1;
      insert into verify_0008zx values (v_ord, 'E3-E7 ' || t.slug, 'skip', 'no active person holds monitoring.live: nothing compared or timed');
      continue;
    end if;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_user::text, true);
    v_checks := array['E3 inbound_calls_of over the last 92 days: the same as 0008zr''s', 'E4 missed_callbacks_of in order: the same as 0008zr''s',
                      'E5 the missed-callbacks summary: the same as 0008i''s', 'E6 inbound_now(): the same JSON as 0008zr''s'];
    v_news := array[format('select * from cma.inbound_calls_of(%L, %L::date::timestamptz, null)', t.id, cma.tenant_today_of(t.id) - 91),
                    format('select * from cma.missed_callbacks_of(%L)', t.id),
                    format('select * from cma.missed_callbacks_summary_of(%L)', t.id),
                    'select cma.inbound_now()'];
    v_olds := array[format('select * from pg_temp.inbound_calls_of_0008zr(%L, %L::date::timestamptz, null)', t.id, cma.tenant_today_of(t.id) - 91),
                    format('select * from pg_temp.missed_callbacks_of_0008zr(%L)', t.id),
                    format('select * from pg_temp.missed_callbacks_summary_of_0008i(%L)', t.id),
                    'select pg_temp.inbound_now_0008zr()'];
    for i in 1 .. 4 loop
      v_ord := v_ord + 1;
      begin
        v_diff := pg_temp.v0008zx_diff(v_news[i], v_olds[i], i = 2);
        execute format('select count(*) from (%s) a', v_news[i]) into v_n;
        insert into verify_0008zx values (v_ord, v_checks[i] || ' (' || t.slug || ')', case when v_diff is null then 'ok' else 'FAIL' end,
          coalesce(v_diff, format('%s row(s), the same%s', v_n, case when i = 2 then ' in the same order' else '' end)));
      exception when others then
        insert into verify_0008zx values (v_ord, v_checks[i] || ' (' || t.slug || ')', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 120));
      end;
    end loop;
    -- E7 131 part a's four inbound polls, its own statements, under the poll's budget
    v_checks := array['inbound today', 'missed callbacks', 'missed callbacks summary', 'inbound now (one statement)'];
    v_news := array['select * from cma.inbound_today()',
                    'select m.*, cma.record_url(m.connection_id, ''call'', m.source_id) as record_url from cma.missed_callbacks() m',
                    'select * from cma.missed_callbacks_summary()',
                    'select cma.inbound_now()'];
    for i in 1 .. 4 loop
      v_ord := v_ord + 1;
      v_ms := pg_temp.v0008zx_best_ms(v_news[i], v_runs);
      insert into verify_0008zx values (v_ord, 'E7 ' || v_checks[i] || ' under verify.max_poll_ms, as the application (' || t.slug || ')',
        case when v_ms >= 0 and v_ms < v_poll and not v_provoke then 'ok' else 'FAIL' end,
        case when v_ms < 0 then 'the read raised an error' else format('%s ms (best of %s) against %s ms', v_ms, v_runs, v_poll) end);
    end loop;
  end loop;
  perform set_config('role', 'cma_owner', true);
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0008zx_diff(text, text, boolean);
drop function if exists pg_temp.v0008zx_row(integer, text, text, text);
drop function if exists pg_temp.v0008zx_user(uuid, text);
drop function if exists pg_temp.v0008zx_code(text);
drop function if exists pg_temp.kinds_0008zl(uuid, uuid);
drop function if exists pg_temp.kinds_0008zr(uuid, uuid);
drop function if exists pg_temp.v0008zx_best_ms(text, integer);
drop function if exists pg_temp.inbound_now_0008zr();
drop function if exists pg_temp.missed_callbacks_summary_of_0008i(uuid);
drop function if exists pg_temp.missed_callbacks_of_0008zr(uuid);
drop function if exists pg_temp.inbound_today_of_0008i(uuid);
drop function if exists pg_temp.inbound_calls_of_0008zr(uuid, timestamptz, timestamptz);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0008zx
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0008zx where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0008zx where result = 'ok') then 'FAIL'
                  else '0008zx verified' end,
             format('145_verify_held_kinds_restore: %s ok, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0008zx where result = 'ok'),
                    (select count(*) from pg_temp.verify_0008zx where result = 'FAIL'), (select count(*) from pg_temp.verify_0008zx where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0008zx;
reset role;
