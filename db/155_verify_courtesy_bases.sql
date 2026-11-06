-- =============================================================================================
-- 155_verify_courtesy_bases.sql: verifies addition 0009c, Courtesy per market with the calls completed in the period,
-- and the courtesy state Unreachable
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure and privileges; block B
-- works on two throwaway tenants inside a subtransaction that is always rolled back, so nothing stays. Universal
-- otherwise: nothing of the seed is used; adapters, contacts, calls, lines, tags, stores, orders and people are invented
-- data values, and no row carries a name of a customer, an address or a phone number. Every check writes one row, PASS
-- or FAIL, and the last row is the verdict (OK when every check passes), because Cloud SQL Studio shows no notices. Run as
-- your own IAM login in dev, after 154_courtesy_bases.sql; then 151, 103, 81 and 73 again (154's header says why).
--   A  structure and privileges: the addition row after 0009a (A1); every function 154 makes again the application's
--      only and in the caller's rights, cma.courtesy_orders_of and cma.courtesy_page_of with JIT off and custom plans
--      (a create or replace drops a function's settings) (A2); the state renamed (A3): cma.courtesy_not_reached_of
--      gone and cma.courtesy_unreachable_of there, no function of cma or cma_read naming the tag meaning key
--      'not_reached' but the setter and the helper (as 103's A3), cma.follow_up_summary() ending with
--      courtesy_unreachable and courtesy_alert_attempts, no follow-up snapshot keeping courtesy_not_reached, and the
--      setting's description naming Unreachable
--   B  on a throwaway tenant (Europe/Amsterdam) with markets BE (Europe/Brussels), GB (Europe/London) and NL
--      (Europe/Amsterdam), a shop each, courtesy.start_date 7 September 2026 and the other settings at their defaults, as
--      of Friday 20 November 2026 12:00 UTC:
--        kS   GB, an order of 14 September, completed by a call of 4 November (positive)
--        kN   NL, an order of 1 October, completed by a call of 12 October (positive)
--        kO   NL, an order of 20 October, completed by a call of 3 November (positive): a November call, an October order
--        kX   one contact with an order in BE (5 October) and one in NL (10 October), both completed by one call of 22
--             October (neutral): it counts once, in BE's row (the earlier order)
--        kR   NL, an order of 2 October, three unanswered attempts since due: Unreachable
--        kN1  NL, an order of 12 November, not due yet; nc an NL order of 11 November without a contact
--      B1  per market the calls add up to the tile, and markets_total holds the rows' sums, for October and November,
--          unfiltered and with each filter (market NL, BE, GB, segment B2C, state unreachable)
--      B2  a call completing orders in two markets counts once, in the earlier order's market (BE); with the market
--          filter NL it counts in NL, the only one of its orders kept, so the row still equals the tile
--      B3  a November call completing an October order counts in November's market column, while that order is not in
--          November's Orders; November: the tile 2, every Of which completed 0, GB a row with calls and no order
--      B4  every other field equals 0009a's definition (150's text of the page, the orders and the state filter, kept
--          below, with 0009a's state not_reached read as unreachable), for every period, group, cohort and filter tried,
--          here and in every tenant of the database for the last 30 days
--      B5  not set up: no market row and markets_total null
--      B6  the state unreachable: the filter takes unreachable and refuses not_reached (CMA04); kR's order is the one
--          Unreachable order, in the list, the tile and cma.courtesy_unreachable_of; the follow-up refresh keeps it as
--          courtesy_unreachable, which cma.follow_up_summary() returns
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED instead of OK.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every check fail

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the session, so every
-- block below stops at once and the verdict says REFUSED, also where the client carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 155 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0009c;
create temp table verify_0009c (ord int, check_name text, result text, detail text);

-- The previous definitions, 0009a's (150_courtesy.sql), verbatim under pg_temp.old_: the page and the two functions it reads,
-- whose state 0009c renames (the page calls them under their pg_temp names, the only change)
create function pg_temp.old_courtesy_orders_of(p_tenant_id uuid, p_from date, p_to date, p_now timestamptz default now())
returns setof cma.courtesy_order_row
language plpgsql stable
rows 500   -- a tenant's courtesy orders of a period (CLAUDE.md, Performance: a set-returning function says its rows)
as $$
declare
  v_start     date := cma.courtesy_start_of(p_tenant_id);
  v_kinds     text[] := cma.courtesy_kinds_of(p_tenant_id);
  v_due       integer := cma.setting_of(p_tenant_id, 'courtesy.due_days')::integer;
  v_alert     integer := cma.setting_of(p_tenant_id, 'courtesy.alert_attempts')::integer;
  v_connected integer := coalesce(cma.setting_of(p_tenant_id, 'telephony.connected_min_seconds')::integer, 0);
  v_conv      integer := coalesce(cma.setting_of(p_tenant_id, 'calls.conversation_min_talk_seconds')::integer, 0);
  v_segments  text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments'));
  v_lower     text[];
  v_zone      text;
  v_from      date;
begin
  if v_start is null then
    return;
  end if;
  if p_from is not null and p_to is not null then
    perform cma.report_range(p_tenant_id, p_from, p_to - 1);
  end if;
  v_from := greatest(v_start, coalesce(p_from, v_start));
  if p_to is not null and p_to <= v_from then
    return;
  end if;
  select array_agg(lower(x) order by o) into v_lower from unnest(v_segments) with ordinality u(x, o);
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  return query
    with ord as materialized (
      -- the orders by their creation instant, a day wider than any zone each side, then by their business date in their
      -- market's zone; with the store customer's contact
      select co.id, co.connection_id, co.source_id, coalesce(co.order_name, co.source_id) as order_name, co.source_created_at,
             coalesce(st.handle, 'unknown') as store, st.name as store_name, coalesce(st.market, 'unknown') as market, z.zone, d.bdate,
             d.bdate + v_due as due_date, ((d.bdate + v_due)::timestamp at time zone z.zone) as due_at,
             cu.crm_connection_id, cu.crm_contact_source_id
      from cma.commerce_order co
      left join cma.commerce_store st on st.tenant_id = co.tenant_id and st.connection_id = co.connection_id
      left join cma.market mk on mk.tenant_id = co.tenant_id and mk.code = st.market
      cross join lateral (select coalesce(mk.time_zone, st.time_zone, v_zone) as zone) z
      cross join lateral (select (co.source_created_at at time zone z.zone)::date as bdate) d
      left join cma.commerce_customer cu
        on cu.tenant_id = co.tenant_id and cu.connection_id = co.connection_id and cu.source_id = co.customer_source_id
       and cu.source_deleted_at is null
      where co.tenant_id = p_tenant_id
        and co.source_created_at >= (v_from::timestamp at time zone 'UTC') - interval '1 day'
        and (p_to is null or co.source_created_at < (p_to::timestamp at time zone 'UTC') + interval '1 day')
        and not co.is_test and co.source_deleted_at is null and co.cancelled_at is null
        and co.order_kind = any (v_kinds)
        and d.bdate >= v_from and (p_to is null or d.bdate < p_to)
    ), k as materialized (
      select distinct ord.crm_connection_id as conn, ord.crm_contact_source_id as contact
      from ord where ord.crm_contact_source_id is not null
    ), c as materialized (
      -- the contacts' calls from the first possible creation up to p_now, each with whether it is an Attempt, a Conversation
      -- and the courtesy outcome of its current tags. Read per contact (the lateral read is kept apart by offset 0), so
      -- each contact's calls come from crm_association_to_idx, never from a scan of every call since the start date
      select k.conn, k.contact, x.*
      from k
      cross join lateral (
        select tc.id as call_id, tc.source_system as tel_system, tc.user_ref, tc.direction, tc.started_at,
               cma.is_conversation(tc.direction, tc.answered_at is not null, tc.talk_seconds, v_connected, v_conv,
                                   (select nr.not_reached from cma.call_not_reached_of(p_tenant_id, tc.connection_id, tc.source_id) nr)) as conversation,
               (select cma.courtesy_outcome_of(tg.meaning)
                from cma.telephony_call_tag ct
                join cma.telephony_tag tg on tg.tenant_id = ct.tenant_id and tg.connection_id = ct.connection_id and tg.tag_ref = ct.tag_ref
                where ct.tenant_id = p_tenant_id and ct.connection_id = tc.connection_id and ct.call_source_id = tc.source_id
                  and ct.untagged_at is null and cma.courtesy_outcome_of(tg.meaning) is not null
                order by ct.tagged_at desc, tg.meaning
                limit 1) as outcome
        from cma.crm_association a
        join cma.crm_call cc
          on cc.tenant_id = p_tenant_id and cc.connection_id = a.connection_id and cc.source_id = a.from_id and cc.source_deleted_at is null
        join cma.call_link l on l.tenant_id = p_tenant_id and l.crm_call_id = cc.id and l.unlinked_at is null
        join cma.telephony_call tc on tc.tenant_id = p_tenant_id and tc.id = l.telephony_call_id and tc.source_deleted_at is null
        left join cma.telephony_number n on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
        where a.tenant_id = p_tenant_id and a.connection_id = k.conn and a.to_type = 'contact' and a.to_id = k.contact
          and a.from_type = 'crm_call' and a.removed_at is null
          and tc.started_at is not null and tc.started_at <= p_now
          and tc.started_at >= (v_from::timestamp at time zone 'UTC') - interval '1 day'
          and tc.direction in ('inbound', 'outbound') and coalesce(n.is_counted, true)
        offset 0
      ) x
    ), j as materialized (
      select ord.id as order_id, ord.source_created_at, ord.due_at, c.*
      from ord join c on c.conn = ord.crm_connection_id and c.contact = ord.crm_contact_source_id
    ), done as (
      -- the completion: the contact's first call with a completed meaning at or after the order's creation
      select distinct on (j.order_id) j.order_id, j.call_id, j.started_at, j.outcome, j.tel_system, j.user_ref
      from j
      where j.outcome is not null and j.started_at >= j.source_created_at
      order by j.order_id, j.started_at, j.call_id
    ), att as (
      -- the attempts since due: outbound, from the start of the due date up to and including the completion
      select j.order_id, count(*)::integer as attempts, bool_or(j.conversation) as conversation, max(j.started_at) as last_at
      from j
      left join done d on d.order_id = j.order_id
      where j.direction = 'outbound' and j.started_at >= j.due_at and j.started_at <= coalesce(d.started_at, p_now)
      group by j.order_id
    )
    select ord.id, ord.connection_id, ord.source_id, ord.order_name, ord.store, ord.store_name, ord.market, ord.zone,
           case when ord.crm_contact_source_id is null then 'unknown'
                else cma.flash_segment_of(kc.segment, v_segments, v_lower) end,
           ord.source_created_at, ord.bdate, ord.due_date, ord.due_at,
           ord.crm_contact_source_id is not null, ord.crm_connection_id, ord.crm_contact_source_id,
           case when ord.crm_contact_source_id is not null then coalesce(att.attempts, 0) end,
           case when ord.crm_contact_source_id is not null then coalesce(att.conversation, false) end,
           att.last_at,
           d.started_at, (d.started_at at time zone ord.zone)::date, (d.started_at at time zone ord.zone)::time, d.call_id, d.outcome,
           case when d.call_id is not null then
             (select x.user_id from cma.app_user_external_id x
              where x.tenant_id = p_tenant_id and x.system = d.tel_system || '_user' and x.external_id = d.user_ref) end,
           case when ord.crm_contact_source_id is null then null
                when d.call_id is not null then 'completed'
                when p_now < ord.due_at then 'not_due'
                when coalesce(att.attempts, 0) = 0 then 'due_no_attempt'
                when att.attempts >= v_alert and not att.conversation then 'not_reached'
                else 'attempted' end
    from ord
    left join done d on d.order_id = ord.id
    left join att on att.order_id = ord.id
    left join cma.crm_contact kc
      on kc.tenant_id = p_tenant_id and kc.connection_id = ord.crm_connection_id and kc.source_id = ord.crm_contact_source_id
    order by ord.source_created_at, ord.id;
end
$$;

create function pg_temp.old_courtesy_state_matches(p_state text, p_filter text)
returns boolean
language sql immutable
as $$
  select case when p_filter is null then true
              when p_filter = 'no_contact' then p_state is null
              when p_filter = 'due' then p_state in ('due_no_attempt', 'attempted', 'not_reached')
              else p_state = p_filter end
$$;

create function pg_temp.old_courtesy_page_of(p_tenant_id uuid, p_from date, p_to date, p_period text, p_group text, p_market text,
                                              p_segment text, p_state text, p_rows integer, p_per_person boolean, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_start    date := cma.courtesy_start_of(p_tenant_id);
  v_ages     integer[] := cma.courtesy_ages_of(p_tenant_id);
  v_prev     record;
  v_head     jsonb;
begin
  v_head := jsonb_build_object(
    'from', p_from, 'to', p_to, 'period', p_period, 'group', p_group, 'market', p_market, 'segment', p_segment, 'state', p_state,
    'rows', p_rows, 'set_up', v_start is not null, 'start_date', v_start,
    'has_store', exists (select 1 from cma.commerce_store s where s.tenant_id = p_tenant_id),
    'settings', jsonb_build_object(
      'due_days', cma.setting_of(p_tenant_id, 'courtesy.due_days')::integer,
      'alert_attempts', cma.setting_of(p_tenant_id, 'courtesy.alert_attempts')::integer,
      'ages', to_jsonb(v_ages), 'order_kinds', to_jsonb(cma.courtesy_kinds_of(p_tenant_id))),
    'filter_segments', to_jsonb(cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments')) || array['unknown']));
  if v_start is null then
    return v_head || jsonb_build_object('now', null, 'completed', null, 'previous', null, 'previous_from', null, 'previous_to', null,
      'previous_partial', false, 'markets', '[]'::jsonb, 'groups', '[]'::jsonb, 'cohorts', '[]'::jsonb, 'per_person', null,
      'list', jsonb_build_object('total', 0, 'rows', '[]'::jsonb), 'filter_markets', '[]'::jsonb);
  end if;
  select * into v_prev from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now);
  return v_head || (
    with a as materialized (
      -- every courtesy order since the start date (the now figures), with its period's flags; the columns the page reads
      select x.order_id, x.order_name, x.store, x.store_name, x.market, x.segment, x.zone, x.created_at, x.business_date, x.due_date,
             x.has_contact, x.crm_connection_id, x.contact_source_id, x.attempts, x.last_attempt_at, x.completed_at,
             x.completed_call_id, x.outcome, x.completed_by, x.state,
             x.business_date between p_from and p_to as created_in,
             x.completed_call_id is not null and cma.in_period(x.completed_date, x.completed_time, p_from, p_to, null) as done_in,
             x.completed_call_id is not null
               and cma.in_period(x.completed_date, x.completed_time, v_prev.prev_from, v_prev.prev_to,
                                 case when v_prev.until is not null then (v_prev.until at time zone x.zone)::time end) as done_prev,
             case p_group when 'day' then x.business_date when 'month' then date_trunc('month', x.business_date)::date
                  else date_trunc('week', x.business_date)::date end as group_key,
             case p_period when 'month' then date_trunc('month', x.business_date)::date
                  else date_trunc('week', x.business_date)::date end as cohort_key
      from pg_temp.old_courtesy_orders_of(p_tenant_id, null, null, p_now) x
    ), f as materialized (
      select * from a
      where (p_market is null or a.market = p_market) and (p_segment is null or a.segment = p_segment)
    ), p as materialized (
      select * from f where f.created_in
    ), l as materialized (
      -- the list's order on the narrow keys alone (the rows' details are joined for the first p_rows only)
      select f.order_id, row_number() over (order by case f.state when 'not_reached' then 1 when 'due_no_attempt' then 2 when 'attempted' then 3
                                                                  when 'not_due' then 4 when 'completed' then 6 else 5 end,
                                                     f.due_date, f.created_at, f.order_id) as n
      from f where pg_temp.old_courtesy_state_matches(f.state, p_state)
    )
    select jsonb_build_object(
      'now', (select jsonb_build_object(
                'orders', count(*) filter (where f.has_contact),
                'due_open', count(*) filter (where f.state in ('due_no_attempt', 'attempted', 'not_reached')),
                'not_due', count(*) filter (where f.state = 'not_due'),
                'due_no_attempt', count(*) filter (where f.state = 'due_no_attempt'),
                'attempted', count(*) filter (where f.state = 'attempted'),
                'not_reached', count(*) filter (where f.state = 'not_reached'),
                'completed', count(*) filter (where f.state = 'completed'),
                'no_contact', count(*) filter (where not f.has_contact)) from f),
      'completed', (select jsonb_build_object(
                      'calls', count(distinct f.completed_call_id) filter (where f.done_in),
                      'positive', count(distinct f.completed_call_id) filter (where f.done_in and f.outcome = 'positive'),
                      'neutral', count(distinct f.completed_call_id) filter (where f.done_in and f.outcome = 'neutral'),
                      'negative', count(distinct f.completed_call_id) filter (where f.done_in and f.outcome = 'negative')) from f),
      'previous', (select jsonb_build_object(
                     'calls', count(distinct f.completed_call_id) filter (where f.done_prev),
                     'positive', count(distinct f.completed_call_id) filter (where f.done_prev and f.outcome = 'positive'),
                     'neutral', count(distinct f.completed_call_id) filter (where f.done_prev and f.outcome = 'neutral'),
                     'negative', count(distinct f.completed_call_id) filter (where f.done_prev and f.outcome = 'negative')) from f),
      'previous_from', v_prev.prev_from, 'previous_to', v_prev.prev_to, 'previous_partial', v_prev.until is not null,
      'markets', (select coalesce(jsonb_agg(jsonb_build_object('market', m.market, 'name', mk.name, 'orders', m.orders, 'completed', m.completed,
                                                               'not_reached', m.not_reached, 'no_contact', m.no_contact)
                                            order by (m.market = 'unknown'), mk.sort_order, m.market), '[]'::jsonb)
                  from (select p.market, count(*) filter (where p.has_contact) as orders, count(*) filter (where p.state = 'completed') as completed,
                               count(*) filter (where p.state = 'not_reached') as not_reached, count(*) filter (where not p.has_contact) as no_contact
                        from p group by p.market) m
                  left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = m.market),
      'groups', (select jsonb_agg(jsonb_build_object('key', g.key, 'orders', coalesce(t.orders, 0), 'completed', coalesce(t.completed, 0),
                                                     'not_reached', coalesce(t.not_reached, 0), 'no_contact', coalesce(t.no_contact, 0),
                                                     'markets', coalesce(t.markets, '[]'::jsonb))
                                  order by g.key)
                 from (select k::date as key
                       from generate_series(case p_group when 'day' then p_from when 'month' then date_trunc('month', p_from)::date
                                                 else date_trunc('week', p_from)::date end, p_to,
                                            case p_group when 'day' then interval '1 day' when 'month' then interval '1 month'
                                                 else interval '7 days' end) k) g
                 left join (select gm.group_key, sum(gm.orders) as orders, sum(gm.completed) as completed, sum(gm.not_reached) as not_reached,
                                   sum(gm.no_contact) as no_contact,
                                   jsonb_agg(jsonb_build_object('market', gm.market, 'orders', gm.orders, 'completed', gm.completed,
                                                                'not_reached', gm.not_reached, 'no_contact', gm.no_contact)
                                             order by (gm.market = 'unknown'), gm.sort_order, gm.market) as markets
                            from (select p.group_key, p.market, coalesce(mk.sort_order, 2147483647) as sort_order,
                                         count(*) filter (where p.has_contact) as orders, count(*) filter (where p.state = 'completed') as completed,
                                         count(*) filter (where p.state = 'not_reached') as not_reached, count(*) filter (where not p.has_contact) as no_contact
                                  from p
                                  left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = p.market
                                  group by p.group_key, p.market, mk.sort_order) gm
                            group by gm.group_key) t on t.group_key = g.key),
      'cohorts', (select coalesce(jsonb_agg(jsonb_build_object(
                                   'key', c.k, 'label', case when p_period = 'month' then to_char(c.k, 'YYYY-MM') else to_char(c.k, 'IYYY-"W"IW') end,
                                   'start', c.k, 'end', e.last_day, 'partial', c.k < p_from or e.last_day > p_to, 'orders', c.orders,
                                   'ages', (select coalesce(jsonb_agg(jsonb_build_object('age', ag.age, 'mature', m.mature,
                                                                                         'completed', case when m.mature then m.completed end)
                                                                      order by ag.o), '[]'::jsonb)
                                            from unnest(v_ages) with ordinality as ag(age, o)
                                            cross join lateral (
                                              select count(*) > 0 and bool_and(q.created_at + make_interval(days => ag.age) <= p_now) as mature,
                                                     count(*) filter (where q.completed_at <= q.created_at + make_interval(days => ag.age)) as completed
                                              from p q where q.has_contact and q.cohort_key = c.k) m))
                                 order by c.k desc), '[]'::jsonb)
                  from (select p.cohort_key as k, count(*) as orders from p where p.has_contact group by p.cohort_key) c
                  cross join lateral (
                    select case when p_period = 'month' then (c.k + interval '1 month' - interval '1 day')::date else c.k + 6 end as last_day) e),
      'per_person', case when p_per_person then
                      (select coalesce(jsonb_agg(jsonb_build_object('user_id', pp.uid, 'name', u.display_name, 'calls', pp.calls,
                                                                    'positive', pp.positive, 'neutral', pp.neutral, 'negative', pp.negative)
                                                 order by (pp.uid is null), u.display_name, pp.uid), '[]'::jsonb)
                       from (select f.completed_by as uid, count(distinct f.completed_call_id) as calls,
                                    count(distinct f.completed_call_id) filter (where f.outcome = 'positive') as positive,
                                    count(distinct f.completed_call_id) filter (where f.outcome = 'neutral') as neutral,
                                    count(distinct f.completed_call_id) filter (where f.outcome = 'negative') as negative
                             from f where f.done_in group by f.completed_by) pp
                       left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = pp.uid) end,
      'list', jsonb_build_object(
                'total', (select count(*) from l),
                'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                                   'order_id', r.order_id, 'order_name', r.order_name, 'store', r.store,
                                   'store_name', r.store_name, 'market', r.market, 'segment', r.segment, 'created_at', r.created_at,
                                   'business_date', r.business_date, 'due_date', r.due_date,
                                   'days_past_due', case when r.state in ('due_no_attempt', 'attempted', 'not_reached')
                                                         then (p_now at time zone r.zone)::date - r.due_date end,
                                   'attempts', r.attempts, 'last_attempt_at', r.last_attempt_at, 'state', r.state, 'outcome', r.outcome,
                                   'completed_at', r.completed_at,
                                   'record_url', case when r.has_contact then cma.record_url(r.crm_connection_id, 'contact', r.contact_source_id) end)
                                 order by l.n), '[]'::jsonb)
                         from l join f r on r.order_id = l.order_id where l.n <= p_rows)),
      'filter_markets', (select coalesce(jsonb_agg(fm.market order by (fm.market = 'unknown'), fm.sort_order, fm.market), '[]'::jsonb)
                         from (select distinct a.market, coalesce(mk.sort_order, 2147483647) as sort_order
                               from a left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = a.market) fm))
  );
end
$$;

-- Per market as text: market:orders/completed/calls/unreachable/no contact per row, the total and the tile's calls
create or replace function pg_temp.v0009c_markets(j jsonb)
returns text
language sql immutable
as $$
  select concat_ws(' | ',
           nullif((select string_agg(format('%s:%s/%s/%s/%s/%s', m ->> 'market', m ->> 'orders', m ->> 'completed', m ->> 'calls',
                                            m ->> 'unreachable', m ->> 'no_contact'), ' ' order by o)
                   from jsonb_array_elements(j -> 'markets') with ordinality as x(m, o)), ''),
           format('total %s/%s/%s/%s/%s', j -> 'markets_total' ->> 'orders', j -> 'markets_total' ->> 'completed',
                  j -> 'markets_total' ->> 'calls', j -> 'markets_total' ->> 'unreachable', j -> 'markets_total' ->> 'no_contact'),
           format('tile %s', j -> 'completed' ->> 'calls'))
$$;

-- Empty when the rows add up to markets_total in every field and its calls equal the tile's; per market as text otherwise
create or replace function pg_temp.v0009c_sums(j jsonb)
returns text
language sql immutable
as $$
  select case when s.o = (j -> 'markets_total' ->> 'orders')::int and s.c = (j -> 'markets_total' ->> 'completed')::int
                   and s.k = (j -> 'markets_total' ->> 'calls')::int and s.r = (j -> 'markets_total' ->> 'unreachable')::int
                   and s.n = (j -> 'markets_total' ->> 'no_contact')::int
                   and (j -> 'markets_total' ->> 'calls')::int = (j -> 'completed' ->> 'calls')::int
              then '' else pg_temp.v0009c_markets(j) end
  from (select coalesce(sum((m ->> 'orders')::int), 0) as o, coalesce(sum((m ->> 'completed')::int), 0) as c,
               coalesce(sum((m ->> 'calls')::int), 0) as k, coalesce(sum((m ->> 'unreachable')::int), 0) as r,
               coalesce(sum((m ->> 'no_contact')::int), 0) as n
        from jsonb_array_elements(j -> 'markets') m) s
$$;

-- 0009c's page equals 0009a's but for its two additions and the state's name: 0009a's "not_reached" (a key and a state
-- value, the page holds no other) read as "unreachable"; then without markets_total, and with the market rows that hold
-- an order of the period (0009a's rows) without their calls, the pages are equal
create or replace function pg_temp.v0009c_same(p_new jsonb, p_old jsonb)
returns boolean
language sql immutable
as $$
  select (p_new - 'markets' - 'markets_total') = (o.j - 'markets')
     and coalesce((select jsonb_agg(m - 'calls' order by n) from jsonb_array_elements(p_new -> 'markets') with ordinality as x(m, n)
                   where (m ->> 'orders')::int + (m ->> 'no_contact')::int > 0), '[]'::jsonb) = o.j -> 'markets'
  from (select replace(p_old::text, '"not_reached"', '"unreachable"')::jsonb as j) o
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text;
  v_cfg     text;
  v_bad     text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0009a
  insert into verify_0009c values (1, 'A1 addition 0009c recorded, after 0009a',
    case when exists (select 1 from cma.schema_migration where version = '0009c')
              and exists (select 1 from cma.schema_migration where version = '0009a') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. every function 154 makes again the application's only and in the caller's rights; the two large reads with JIT
  --     off and custom plans again
  v_bad := '';
  foreach v_fn in array array[
    'cma.courtesy_orders_of(uuid,date,date,timestamptz)', 'cma.courtesy_unreachable_of(uuid,timestamptz)',
    'cma.courtesy_state_matches(text,text)', 'cma.courtesy_page_of(uuid,date,date,text,text,text,text,text,integer,boolean,timestamptz)',
    'cma.courtesy_page(date,date,text,text,text,text,text,integer)', 'cma.refresh_follow_up_of(uuid,boolean)', 'cma.follow_up_summary()'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or has_function_privilege('public', v_fn, 'execute') or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' not the application''s only or not in the caller''s rights; ';
    end if;
  end loop;
  foreach v_fn in array array['cma.courtesy_orders_of(uuid,date,date,timestamptz)',
                              'cma.courtesy_page_of(uuid,date,date,text,text,text,text,text,integer,boolean,timestamptz)'] loop
    select array_to_string(proconfig, ',') into v_cfg from pg_proc where oid = to_regprocedure(v_fn);
    if coalesce(v_cfg, '') not like '%jit=off%' or coalesce(v_cfg, '') not like '%plan_cache_mode=force_custom_plan%' then
      v_bad := v_bad || v_fn || ' settings ' || coalesce(v_cfg, 'none') || '; ';
    end if;
  end loop;
  insert into verify_0009c values (2, 'A2 every remade function the application''s only and invoker; the two reads with JIT off and custom plans',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the state renamed: 0009a's count function gone and its new name there; no function of cma or cma_read names the
  --     tag meaning key 'not_reached' but the setter and the helper (as 103's A3); the follow-up summary's columns; no
  --     snapshot keeping the old key; the setting's description
  v_bad := '';
  if to_regprocedure('cma.courtesy_not_reached_of(uuid,timestamptz)') is not null then
    v_bad := v_bad || 'cma.courtesy_not_reached_of still there; ';
  end if;
  select string_agg(p.proname, ',' order by p.proname) into v_cfg
  from pg_proc p
  where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace) and p.prosrc ~ '''not_reached''';
  if v_cfg is distinct from 'set_telephony_tag_meaning,tag_meaning_excludes_conversation' then
    v_bad := v_bad || 'functions naming not_reached: ' || coalesce(v_cfg, 'none') || '; ';
  end if;
  if (select array_to_string((proargnames)[array_length(proargnames, 1) - 2:], ',') from pg_proc
      where oid = to_regprocedure('cma.follow_up_summary()')) is distinct from 'computed_at,courtesy_unreachable,courtesy_alert_attempts' then
    v_bad := v_bad || 'cma.follow_up_summary() does not end with courtesy_unreachable; ';
  end if;
  if exists (select 1 from cma.follow_up_snapshot s where s.summary ? 'courtesy_not_reached') then
    v_bad := v_bad || 'a snapshot keeps courtesy_not_reached; ';
  end if;
  if (select s.description from cma.setting s where s.key = 'courtesy.alert_attempts') not like '%flagged Unreachable%' then
    v_bad := v_bad || 'courtesy.alert_attempts does not name Unreachable; ';
  end if;
  insert into verify_0009c values (3, 'A3 the state renamed: the count function, no function naming not_reached but the two, the summary, the snapshots, the setting',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. The calls of the period per market on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_zed uuid; v_ing1 uuid; v_analyst2 uuid;
  v_crm uuid; v_tel uuid; v_nl uuid; v_be uuid; v_gb uuid;
  v_txt text; v_txt2 text; v_unset text;
  v_n integer; v_m integer;
  j jsonb; j2 jsonb;
  f record; t record;
  v_oct_from date := '2026-10-01'; v_oct_to date := '2026-10-31';
  v_nov_from date := '2026-11-01'; v_nov_to date := '2026-11-30';
  v_now  timestamptz := '2026-11-20 12:00:00+00';   -- Friday 20 November 2026, 13:00 in Amsterdam and Brussels, 12:00 in London
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people and roles (as the owner, as 0009a's verify)
    v_t1 := cma.create_tenant('verify-0009c-one', 'Verify 0009c one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0009c-two', 'Verify 0009c two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-zed@example.invalid', 'Zed') returning id into v_zed;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_zed, 'agent'), (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id, settings)
    values (v_t1, 'verifycrm', 'crm', 'Verify bases CRM', 'portal-1', '{"record_url_contact": "https://crm.example.invalid/{account}/contact/{id}"}')
    returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifytel', 'telephony', 'Verify bases telephony', 'tel-1') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifyshop', 'commerce', 'Verify bases shop NL', 'shop-nl.example.invalid') returning id into v_nl;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifyshop', 'commerce', 'Verify bases shop BE', 'shop-be.example.invalid') returning id into v_be;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifyshop', 'commerce', 'Verify bases shop GB', 'shop-gb.example.invalid') returning id into v_gb;
    insert into cma.app_user_external_id (tenant_id, user_id, system, external_id) values (v_t1, v_zed, 'verifytel_user', 'tu-1');
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): the markets, the settings, the shops, then the catalogs (the Ingest user)
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('BE', 'Belgium', 'Europe/Brussels', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.set_tenant_setting('crm.customer_segments', 'B2B,B2C');
    perform cma.upsert_commerce_store(v_nl, 'v-nl', 'Verify NL', 'NL', 'EUR', 'Europe/Amsterdam');
    perform cma.upsert_commerce_store(v_be, 'v-be', 'Verify BE', 'BE', 'EUR', 'Europe/Brussels');
    perform cma.upsert_commerce_store(v_gb, 'v-gb', 'Verify GB', 'GB', 'GBP', 'Europe/London');
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-1", "name": "Verify line", "digits": "+31000000001"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "t-pos", "name": "Completed positive"}, {"tagRef": "t-neu", "name": "Completed neutral"}]');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_number(v_tel, 'n-1', 'NL', true);
    perform cma.set_telephony_tag_meaning(v_tel, 't-pos', 'courtesy_completed_positive');
    perform cma.set_telephony_tag_meaning(v_tel, 't-neu', 'courtesy_completed_neutral');

    -- the store customers (kX has one in NL and one in BE, both linked to the contact kX; c-no linked to none), the orders,
    -- the links and the contacts (UTC)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_commerce_customers(v_nl, (
      select jsonb_agg(jsonb_build_object('sourceId', 'c-' || k, 'updatedAt', '2026-09-01T00:00:00Z'))
      from unnest(array['kN', 'kO', 'kXn', 'kR', 'kN1', 'no']) k));
    perform cma.ingest_upsert_commerce_customers(v_be, '[{"sourceId": "c-kXb", "updatedAt": "2026-09-01T00:00:00Z"}]');
    perform cma.ingest_upsert_commerce_customers(v_gb, '[{"sourceId": "c-kS", "updatedAt": "2026-09-01T00:00:00Z"}]');
    perform cma.ingest_upsert_commerce_orders(v_nl, '[
      {"sourceId": "oN",   "customerId": "c-kN",  "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oR",   "customerId": "c-kR",  "createdAt": "2026-10-02T10:00:00Z", "updatedAt": "2026-10-02T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oXnl", "customerId": "c-kXn", "createdAt": "2026-10-10T10:00:00Z", "updatedAt": "2026-10-10T10:00:00Z", "priorOrdersCount": 1},
      {"sourceId": "oO",   "customerId": "c-kO",  "createdAt": "2026-10-20T10:00:00Z", "updatedAt": "2026-10-20T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oNc",  "customerId": "c-no",  "createdAt": "2026-11-11T10:00:00Z", "updatedAt": "2026-11-11T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oN1",  "customerId": "c-kN1", "createdAt": "2026-11-12T10:00:00Z", "updatedAt": "2026-11-12T10:00:00Z", "priorOrdersCount": 0}]');
    perform cma.ingest_upsert_commerce_orders(v_be, '[
      {"sourceId": "oXbe", "customerId": "c-kXb", "createdAt": "2026-10-05T10:00:00Z", "updatedAt": "2026-10-05T10:00:00Z", "priorOrdersCount": 0}]');
    perform cma.ingest_upsert_commerce_orders(v_gb, '[
      {"sourceId": "oS",   "customerId": "c-kS",  "createdAt": "2026-09-14T10:00:00Z", "updatedAt": "2026-09-14T10:00:00Z", "priorOrdersCount": 0}]');
    perform cma.set_commerce_customer_contact(v_nl, 'c-' || k, v_crm, k) from unnest(array['kN', 'kO', 'kR', 'kN1']) k;
    perform cma.set_commerce_customer_contact(v_nl, 'c-kXn', v_crm, 'kX');
    perform cma.set_commerce_customer_contact(v_be, 'c-kXb', v_crm, 'kX');
    perform cma.set_commerce_customer_contact(v_gb, 'c-kS', v_crm, 'kS');
    perform cma.ingest_upsert_contacts(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', k, 'country', 'NL', 'updatedAt', '2026-09-01T00:00:00Z'))
      from unnest(array['kN', 'kO', 'kX', 'kR', 'kN1', 'kS']) k));

    -- the calls: each a CRM call on its contact logged by a telephony call with the same hash, 10 seconds earlier
    --   kS  4 Nov, completed positive: completes oS of 14 September (GB)
    --   kN  12 Oct, completed positive: completes oN of 1 October (NL)
    --   kO  3 Nov, completed positive: completes oO of 20 October (NL), a November call of an October order
    --   kX  22 Oct, completed neutral: completes oXbe of 5 October (BE) and oXnl of 10 October (NL), counted once, in BE
    --   kR  13, 14 and 15 Oct, unanswered: three attempts since due without a conversation, Not reached
    create temp table v0009c_calls (id text, contact text, at timestamptz, talk integer, tags text[]) on commit drop;
    insert into v0009c_calls values
      ('cS',  'kS', '2026-11-04T10:00:00Z', 60,   '{t-pos}'),
      ('cN',  'kN', '2026-10-12T10:00:00Z', 60,   '{t-pos}'),
      ('cO',  'kO', '2026-11-03T10:00:00Z', 60,   '{t-pos}'),
      ('cX',  'kX', '2026-10-22T10:00:00Z', 90,   '{t-neu}'),
      ('cR1', 'kR', '2026-10-13T10:00:00Z', null, '{}'),
      ('cR2', 'kR', '2026-10-14T10:00:00Z', null, '{}'),
      ('cR3', 'kR', '2026-10-15T10:00:00Z', null, '{}');
    perform cma.ingest_upsert_calls(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', c.id, 'occurredAt', c.at, 'direction', 'outbound', 'counterpartHash', md5(c.id) || md5(c.id || 'x'),
                                          'updatedAt', c.at))
      from v0009c_calls c));
    perform cma.ingest_upsert_associations(v_crm, (
      select jsonb_agg(jsonb_build_object('fromType', 'crm_call', 'fromId', c.id, 'toType', 'contact', 'toId', c.contact, 'removed', false,
                                          'changedAt', '2026-09-01T00:00:00Z'))
      from v0009c_calls c));
    perform cma.ingest_upsert_telephony_calls(v_tel, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'sourceId', 't' || c.id, 'direction', 'outbound', 'startedAt', c.at - interval '10 seconds',
               'answeredAt', case when c.talk is not null then c.at end,
               'endedAt', c.at + make_interval(secs => coalesce(c.talk, 20)), 'numberRef', 'n-1', 'userRef', 'tu-1',
               'counterpartHash', md5(c.id) || md5(c.id || 'x'), 'versionAt', c.at + interval '1 hour', 'tags', to_jsonb(c.tags))))
      from v0009c_calls c));
    perform cma.link_calls('2026-09-01T00:00:00Z');
    -- the segments (the CRM's mapped property, as the ingest would keep them): kS B2B, every other contact B2C
    perform set_config('role', 'cma_owner', true);
    update cma.crm_contact set segment = case source_id when 'kS' then 'B2B' else 'B2C' end
    where tenant_id = v_t1 and source_id in ('kS', 'kN', 'kO', 'kX', 'kR', 'kN1');
    perform set_config('role', 'cma_app', true);

    -- B5 (first part). Not set up: no market row and markets_total null; 0009a's page otherwise
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.courtesy_page_of(v_t1, v_oct_from, v_oct_to, 'week', 'week', null, null, null, 100, true, v_now);
    j2 := pg_temp.old_courtesy_page_of(v_t1, v_oct_from, v_oct_to, 'week', 'week', null, null, null, 100, true, v_now);
    v_unset := format('set_up %s; markets %s; markets_total %s; as 0009a %s', j ->> 'set_up', j -> 'markets', coalesce(j ->> 'markets_total', 'null'),
                      pg_temp.v0009c_same(j, j2)::text);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('courtesy.start_date', '2026-09-07');
    perform set_config('app.user_id', v_analyst1::text, true);

    -- B1. per market the calls add up to the tile, and markets_total holds the rows' sums, for October and November,
    --     unfiltered and with each filter
    v_txt2 := '';
    v_n := 0;
    for f in select * from (values (null::text, null::text, null::text), ('NL', null, null), ('BE', null, null), ('GB', null, null),
                                   (null, 'B2C', null), (null, null, 'unreachable')) as x(market, segment, state) loop
      for t in select * from (values (v_oct_from, v_oct_to), (v_nov_from, v_nov_to)) as y(pfrom, pto) loop
        j := cma.courtesy_page_of(v_t1, t.pfrom, t.pto, 'week', 'week', f.market, f.segment, f.state, 100, true, v_now);
        v_n := v_n + 1;
        if pg_temp.v0009c_sums(j) <> '' then
          v_txt2 := v_txt2 || format('%s %s/%s/%s: %s; ', to_char(t.pfrom, 'Mon'), coalesce(f.market, '-'), coalesce(f.segment, '-'),
                                     coalesce(f.state, '-'), pg_temp.v0009c_sums(j));
        end if;
      end loop;
    end loop;
    v_rows := v_rows || array['11', 'B1 per market the calls add up to the tile, and markets_total holds the rows'' sums, with every filter',
      case when v_txt2 = '' and v_n = 12 and not v_provoke then 'PASS' else 'FAIL' end,
      case when v_txt2 = '' then format('%s pages, every one adds up', v_n) else v_txt2 end];

    -- B2. one call completing orders in two markets counts once, in the earlier order's market (BE, 5 October; not NL, 10
    --     October); with the market filter NL it counts in NL, the only one of its orders kept, so the row equals the tile
    j := cma.courtesy_page_of(v_t1, v_oct_from, v_oct_to, 'week', 'week', null, null, null, 100, true, v_now);
    v_txt2 := pg_temp.v0009c_markets(j);
    j2 := cma.courtesy_page_of(v_t1, v_oct_from, v_oct_to, 'week', 'week', 'NL', null, null, 100, true, v_now);
    v_txt2 := v_txt2 || ' || NL ' || pg_temp.v0009c_markets(j2);
    j2 := cma.courtesy_page_of(v_t1, v_oct_from, v_oct_to, 'week', 'week', 'BE', null, null, 100, true, v_now);
    v_txt2 := v_txt2 || ' || BE ' || pg_temp.v0009c_markets(j2);
    select count(distinct o.completed_call_id), count(*) into v_n, v_m
    from cma.courtesy_orders_of(v_t1, null, null, v_now) o where o.order_source_id in ('oXbe', 'oXnl');
    v_rows := v_rows || array['12', 'B2 a call completing orders in two markets counts once, in the earlier order''s market',
      case when v_txt2 = 'BE:1/1/1/0/0 NL:4/3/1/1/0 | total 5/4/2/1/0 | tile 2 || NL NL:4/3/2/1/0 | total 4/3/2/1/0 | tile 2 '
                         || '|| BE BE:1/1/1/0/0 | total 1/1/1/0/0 | tile 1'
                and v_n = 1 and v_m = 2
                and not v_provoke then 'PASS' else 'FAIL' end, format('%s; %s call completing %s orders', v_txt2, v_n, v_m)];

    -- B3. a November call completing an October order (oO, NL) counts in November's NL column, while oO is not in
    --     November's Orders (NL holds oN1 and the order without a contact); GB has a row with a call and no order; the
    --     tile is 2 and every Of which completed 0; Per week has no call column
    j := cma.courtesy_page_of(v_t1, v_nov_from, v_nov_to, 'week', 'week', null, null, null, 100, true, v_now);
    v_txt2 := pg_temp.v0009c_markets(j);
    j2 := cma.courtesy_page_of(v_t1, v_nov_from, v_nov_to, 'week', 'week', null, 'B2C', null, 100, true, v_now);
    v_txt2 := v_txt2 || ' || B2C ' || pg_temp.v0009c_markets(j2);
    select string_agg(format('%s:%s/%s', o.order_source_id, to_char(o.business_date, 'MMDD'), coalesce(to_char(o.completed_date, 'MMDD'), '-')), ' '
                      order by o.order_source_id) into v_txt
    from cma.courtesy_orders_of(v_t1, null, null, v_now) o where o.order_source_id in ('oO', 'oN1');
    v_rows := v_rows || array['13', 'B3 a November call completing an October order counts in November''s market column; the order not in November''s Orders',
      case when v_txt2 = 'GB:0/0/1/0/0 NL:1/0/1/0/1 | total 1/0/2/0/1 | tile 2 || B2C NL:1/0/1/0/0 | total 1/0/1/0/0 | tile 1'
                and v_txt = 'oN1:1112/- oO:1020/1103'
                and not exists (select 1 from jsonb_array_elements(j -> 'groups') g
                                where g ? 'calls' or exists (select 1 from jsonb_array_elements(g -> 'markets') gm where gm ? 'calls'))
                and not exists (select 1 from jsonb_array_elements(j -> 'markets') m where (m ->> 'completed')::int <> 0)
                and not v_provoke then 'PASS' else 'FAIL' end, format('%s; %s', v_txt2, coalesce(v_txt, 'null'))];

    -- B4. every other field as 0009a's definition: periods October, November and 7 September to 20 November; every group;
    --     both cohorts; the filters (market, segment, state); with and without per person; the list capped at 3 and 100
    v_txt2 := '';
    v_n := 0;
    for t in select * from (values (v_oct_from, v_oct_to), (v_nov_from, v_nov_to), (date '2026-09-07', date '2026-11-20')) as y(pfrom, pto) loop
      for f in select g.grp, c.coh, x.market, x.segment, x.state, x.per_person, x.lim
               from unnest(array['day', 'week', 'month']) g(grp)
               cross join unnest(array['week', 'month']) c(coh)
               cross join (values (null::text, null::text, null::text, true, 100), ('NL', null, null, true, 3), ('BE', null, 'completed', false, 100),
                                  ('GB', null, null, true, 100), (null, 'B2C', null, false, 100), (null, 'unknown', 'no_contact', true, 100),
                                  (null, null, 'due', true, 100), (null, null, 'unreachable', true, 3)) as x(market, segment, state, per_person, lim) loop
        j := cma.courtesy_page_of(v_t1, t.pfrom, t.pto, f.coh, f.grp, f.market, f.segment, f.state, f.lim, f.per_person, v_now);
        -- 0009a's filter value for the state is not_reached
        j2 := pg_temp.old_courtesy_page_of(v_t1, t.pfrom, t.pto, f.coh, f.grp, f.market, f.segment,
                                           case when f.state = 'unreachable' then 'not_reached' else f.state end, f.lim, f.per_person, v_now);
        v_n := v_n + 1;
        if not pg_temp.v0009c_same(j, j2) then
          v_txt2 := v_txt2 || format('%s..%s %s/%s %s/%s/%s; ', t.pfrom, t.pto, f.grp, f.coh, coalesce(f.market, '-'), coalesce(f.segment, '-'),
                                     coalesce(f.state, '-'));
        end if;
      end loop;
    end loop;
    -- and every tenant of the database, the last 30 days as of now, as each tenant's own reader
    v_m := 0;
    for t in select tn.id from cma.tenant tn where tn.id not in (v_t1, v_t2) loop
      perform set_config('app.tenant_id', t.id::text, true);
      j := cma.courtesy_page_of(t.id, current_date - 29, current_date, 'week', 'week', null, null, null, 100, true, now());
      j2 := pg_temp.old_courtesy_page_of(t.id, current_date - 29, current_date, 'week', 'week', null, null, null, 100, true, now());
      v_m := v_m + 1;
      if not pg_temp.v0009c_same(j, j2) then
        v_txt2 := v_txt2 || format('tenant %s; ', t.id);
      end if;
    end loop;
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['14', 'B4 every other field as 0009a''s definition, for every period, group, cohort and filter tried and in every tenant',
      case when v_txt2 = '' and v_n = 144 and v_m >= 1 and not v_provoke then 'PASS' else 'FAIL' end,
      case when v_txt2 = '' then format('%s pages here and %s tenants equal', v_n, v_m) else v_txt2 end];

    -- B6. the state unreachable: the filter takes unreachable and refuses 0009a's not_reached (CMA04); kR's order oR is the one
    --     Unreachable order, first in the list, in the tile and in cma.courtesy_unreachable_of; the follow-up refresh keeps
    --     the count as courtesy_unreachable (never courtesy_not_reached), which cma.follow_up_summary() returns
    begin
      perform cma.courtesy_page(v_oct_from, v_oct_to, 'week', 'week', null, null, 'not_reached');
      v_txt := 'ok';
    exception when others then
      v_txt := sqlstate;
    end;
    j := cma.courtesy_page(v_oct_from, v_oct_to, 'week', 'week', null, null, 'unreachable');
    v_txt := format('not_reached %s; unreachable %s %s %s; tile %s; of %s', v_txt, j -> 'list' ->> 'total', j -> 'list' -> 'rows' -> 0 ->> 'order_name',
                    j -> 'list' -> 'rows' -> 0 ->> 'state', j -> 'now' ->> 'unreachable', cma.courtesy_unreachable_of(v_t1, v_now));
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.refresh_follow_up_of(v_t1);
    select v_txt || format('; summary %s/%s; keys %s', s.courtesy_unreachable, s.courtesy_alert_attempts,
                           (select string_agg(k, ',' order by k) from cma.follow_up_snapshot fs, jsonb_object_keys(fs.summary) k
                            where fs.tenant_id = v_t1 and k like 'courtesy%'))
      into v_txt from cma.follow_up_summary() s;
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['16', 'B6 the state unreachable: the filter, the list, the tile, the count and the follow-up summary',
      case when v_txt = 'not_reached CMA04; unreachable 1 oR unreachable; tile 1; of 1; summary 1/3; keys courtesy_alert_attempts,courtesy_unreachable'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. not set up (tenant one before its start date, above; tenant two, no store and no start date): no market row,
    --     markets_total null, and 0009a's page otherwise
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    j := cma.courtesy_page(v_oct_from, v_oct_to);
    v_rows := v_rows || array['15', 'B5 not set up: no market row and markets_total null',
      case when v_unset = 'set_up false; markets []; markets_total null; as 0009a true'
                and j ->> 'set_up' = 'false' and j -> 'markets' = '[]'::jsonb and j -> 'markets_total' = 'null'::jsonb
                and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | two: set_up %s, markets %s, markets_total %s', v_unset, j ->> 'set_up', j -> 'markets', j -> 'markets_total')];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then
      v_rows := v_rows || array['49', 'B ran to the end', case when not v_provoke then 'PASS' else 'FAIL' end, ''];
    when others then
      v_rows := v_rows || array['49', 'B ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0009c (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009c values (49, 'B ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009c_same(jsonb, jsonb);
drop function if exists pg_temp.v0009c_sums(jsonb);
drop function if exists pg_temp.v0009c_markets(jsonb);
drop function if exists pg_temp.old_courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz);
drop function if exists pg_temp.old_courtesy_state_matches(text, text);
drop function if exists pg_temp.old_courtesy_orders_of(uuid, date, date, timestamptz);

-- Verdict: one row per check, then the verdict: OK when all 10 checks pass
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009c
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT OK'
                  when (select count(*) from verify_0009c where result = 'PASS') = 10
                       and not exists (select 1 from verify_0009c where result <> 'PASS') then 'OK'
                  else 'FAIL' end,
             format('155_verify_courtesy_bases: %s PASS, %s FAIL', (select count(*) from verify_0009c where result = 'PASS'),
                                                                  (select count(*) from verify_0009c where result <> 'PASS'))) x
order by ord;
reset role;
