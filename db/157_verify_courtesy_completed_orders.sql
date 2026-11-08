-- =============================================================================================
-- 157_verify_courtesy_completed_orders.sql: verifies addition 0009d, Courtesy counts completed courtesy orders; Of which
-- due; the completed tags
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure and privileges; block B
-- works on two throwaway tenants inside a subtransaction that is always rolled back, so nothing stays. Universal
-- otherwise: nothing of the seed is used; adapters, contacts, calls, lines, tags, stores, orders and people are invented
-- data values, and no row carries a name of a customer, an address or a phone number. Every check writes one row, PASS
-- or FAIL, and the last row is the verdict (OK when every check passes), because Cloud SQL Studio shows no notices. Run as
-- your own IAM login in dev, after 156_courtesy_completed_orders.sql; then 151, 155, 103, 81 and 73 again (156's header
-- says why).
--   A  structure and privileges: the addition row after 0009c (A1); cma.courtesy_page_of and cma.courtesy_page the
--      application's only and in the caller's rights, the page with JIT off and custom plans (A2)
--   B  on a throwaway tenant (Europe/Amsterdam) with markets BE (Europe/Brussels), GB (Europe/London) and NL
--      (Europe/Amsterdam), a shop each, courtesy.start_date 7 September 2026 and the other settings at their defaults, the
--      three completed meanings on the tags Completed positive, Completed neutral and Completed negative, as of Friday 20
--      November 2026 12:00 UTC (Zed is the telephony user tu-1, Anna tu-2):
--        kS   GB, an order of 14 September, completed by Zed on 4 November (positive)
--        kN   NL, an order of 1 October, completed by Zed on 12 October (positive)
--        kO   NL, an order of 20 October, completed by Zed on 3 November (positive)
--        kX   one contact with two open orders, BE (5 October) and NL (10 October), both completed by one call of Anna's on
--             22 October (neutral)
--        kR   NL, an order of 2 October, three unanswered attempts since due: Unreachable
--        kN1  NL, an order of 12 November, due 22 November: not due yet; nc an NL order of 11 November without a contact
--        kB   BE, an order of 14 November, due 24 November: not due yet, so BE has nothing due in November
--        kE   NL, an order of 15 November, due 25 November, completed by Zed on 16 November (negative): before its due date
--      B1  the four totals are equal: the tile = the markets' completed in the period = the outcomes = per person (and
--          markets_total's), for October and November, unfiltered and with each filter
--      B2  one call completing a contact's two open orders counts 2 in the tile and in per person, each order in its own
--          market (BE and NL); with the market filter NL only NL's
--      B3  an order placed in the period with nothing due gives due 0 and a null share (BE in November, and its week)
--      B4  an order completed before its due date counts in due and in completed (kE's in November)
--      B5  completed_tags lists the mapped names in name order, and is empty without a mapping (tenant two, whose tags
--          mean an attempt and not reached); once tenant two maps a tag to completed, each tenant lists only its own
--      B6  every other answer of cma.courtesy_page_of equals 154's definition (its text kept below), markets_total's
--          orders, completed, unreachable and no contact included, for every period, group, cohort and filter tried, here
--          and in every tenant of the database for the last 30 days
--      B7  the previous period counts orders too, as the tile does (1 to 20 November's previous, 12 to 31 October: 3 orders
--          from 2 calls), and not set up keeps every figure null
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 157 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0009d;
create temp table verify_0009d (ord int, check_name text, result text, detail text);

-- The previous definition, 0009c's (154_courtesy_bases.sql), verbatim under pg_temp.old_ (the two functions it reads,
-- cma.courtesy_orders_of and cma.courtesy_state_matches, are 0009c's and unchanged)
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
      'previous_partial', false, 'markets', '[]'::jsonb, 'markets_total', null, 'groups', '[]'::jsonb, 'cohorts', '[]'::jsonb,
      'per_person', null, 'list', jsonb_build_object('total', 0, 'rows', '[]'::jsonb), 'filter_markets', '[]'::jsonb);
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
      from cma.courtesy_orders_of(p_tenant_id, null, null, p_now) x
    ), f as materialized (
      select * from a
      where (p_market is null or a.market = p_market) and (p_segment is null or a.segment = p_segment)
    ), p as materialized (
      select * from f where f.created_in
    ), cm as materialized (
      -- each completed courtesy call of the period once (as the tile counts it), in the market of the earliest courtesy
      -- order it completed among the filtered orders whose completion falls in the period (0009c)
      select distinct on (f.completed_call_id) f.completed_call_id, f.market
      from f where f.done_in
      order by f.completed_call_id, f.created_at, f.order_id
    ), mm as materialized (
      -- per market: the period's orders (by order date) beside the period's calls (by call date); a market with either
      select coalesce(o.market, c.market) as market, coalesce(o.orders, 0) as orders, coalesce(o.completed, 0) as completed,
             coalesce(c.calls, 0) as calls, coalesce(o.unreachable, 0) as unreachable, coalesce(o.no_contact, 0) as no_contact
      from (select p.market, count(*) filter (where p.has_contact) as orders, count(*) filter (where p.state = 'completed') as completed,
                   count(*) filter (where p.state = 'unreachable') as unreachable, count(*) filter (where not p.has_contact) as no_contact
            from p group by p.market) o
      full join (select cm.market, count(*) as calls from cm group by cm.market) c on c.market = o.market
    ), l as materialized (
      -- the list's order on the narrow keys alone (the rows' details are joined for the first p_rows only)
      select f.order_id, row_number() over (order by case f.state when 'unreachable' then 1 when 'due_no_attempt' then 2 when 'attempted' then 3
                                                                  when 'not_due' then 4 when 'completed' then 6 else 5 end,
                                                     f.due_date, f.created_at, f.order_id) as n
      from f where cma.courtesy_state_matches(f.state, p_state)
    )
    select jsonb_build_object(
      'now', (select jsonb_build_object(
                'orders', count(*) filter (where f.has_contact),
                'due_open', count(*) filter (where f.state in ('due_no_attempt', 'attempted', 'unreachable')),
                'not_due', count(*) filter (where f.state = 'not_due'),
                'due_no_attempt', count(*) filter (where f.state = 'due_no_attempt'),
                'attempted', count(*) filter (where f.state = 'attempted'),
                'unreachable', count(*) filter (where f.state = 'unreachable'),
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
                                                               'calls', m.calls, 'unreachable', m.unreachable, 'no_contact', m.no_contact)
                                            order by (m.market = 'unknown'), mk.sort_order, m.market), '[]'::jsonb)
                  from mm m
                  left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = m.market),
      'markets_total', (select jsonb_build_object('orders', coalesce(sum(m.orders), 0), 'completed', coalesce(sum(m.completed), 0),
                                                  'calls', coalesce(sum(m.calls), 0), 'unreachable', coalesce(sum(m.unreachable), 0),
                                                  'no_contact', coalesce(sum(m.no_contact), 0))
                        from mm m),
      'groups', (select jsonb_agg(jsonb_build_object('key', g.key, 'orders', coalesce(t.orders, 0), 'completed', coalesce(t.completed, 0),
                                                     'unreachable', coalesce(t.unreachable, 0), 'no_contact', coalesce(t.no_contact, 0),
                                                     'markets', coalesce(t.markets, '[]'::jsonb))
                                  order by g.key)
                 from (select k::date as key
                       from generate_series(case p_group when 'day' then p_from when 'month' then date_trunc('month', p_from)::date
                                                 else date_trunc('week', p_from)::date end, p_to,
                                            case p_group when 'day' then interval '1 day' when 'month' then interval '1 month'
                                                 else interval '7 days' end) k) g
                 left join (select gm.group_key, sum(gm.orders) as orders, sum(gm.completed) as completed, sum(gm.unreachable) as unreachable,
                                   sum(gm.no_contact) as no_contact,
                                   jsonb_agg(jsonb_build_object('market', gm.market, 'orders', gm.orders, 'completed', gm.completed,
                                                                'unreachable', gm.unreachable, 'no_contact', gm.no_contact)
                                             order by (gm.market = 'unknown'), gm.sort_order, gm.market) as markets
                            from (select p.group_key, p.market, coalesce(mk.sort_order, 2147483647) as sort_order,
                                         count(*) filter (where p.has_contact) as orders, count(*) filter (where p.state = 'completed') as completed,
                                         count(*) filter (where p.state = 'unreachable') as unreachable, count(*) filter (where not p.has_contact) as no_contact
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
                                   'days_past_due', case when r.state in ('due_no_attempt', 'attempted', 'unreachable')
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

-- Per market as text: market:orders/due/completed/completed in the period/unreachable/no contact per row, the total, the
-- tile, the outcomes (positive/neutral/negative) and per person (name:orders/positive/neutral/negative)
create or replace function pg_temp.v0009d_page(j jsonb)
returns text
language sql immutable
as $$
  select concat_ws(' | ',
           nullif((select string_agg(format('%s:%s/%s/%s/%s/%s/%s', m ->> 'market', m ->> 'orders', m ->> 'due', m ->> 'completed',
                                            m ->> 'completed_in_period', m ->> 'unreachable', m ->> 'no_contact'), ' ' order by o)
                   from jsonb_array_elements(j -> 'markets') with ordinality as x(m, o)), ''),
           format('total %s/%s/%s/%s/%s/%s', j -> 'markets_total' ->> 'orders', j -> 'markets_total' ->> 'due',
                  j -> 'markets_total' ->> 'completed', j -> 'markets_total' ->> 'completed_in_period',
                  j -> 'markets_total' ->> 'unreachable', j -> 'markets_total' ->> 'no_contact'),
           format('tile %s', j -> 'completed' ->> 'orders'),
           format('outcomes %s/%s/%s', j -> 'completed' ->> 'positive', j -> 'completed' ->> 'neutral', j -> 'completed' ->> 'negative'),
           'people ' || coalesce((select string_agg(format('%s:%s/%s/%s/%s', coalesce(p ->> 'name', 'none'), p ->> 'orders', p ->> 'positive',
                                                          p ->> 'neutral', p ->> 'negative'), ' ' order by o)
                                  from jsonb_array_elements(j -> 'per_person') with ordinality as y(p, o)), '-'))
$$;

-- Empty when the four totals agree (the tile, the markets' completed in the period and markets_total's, the outcomes, per
-- person) and the markets' order columns add up to markets_total; the page as text otherwise
create or replace function pg_temp.v0009d_totals(j jsonb)
returns text
language sql immutable
as $$
  select case when (j -> 'completed' ->> 'orders')::int = s.cip
                   and s.cip = (j -> 'markets_total' ->> 'completed_in_period')::int
                   and (j -> 'completed' ->> 'orders')::int = (j -> 'completed' ->> 'positive')::int + (j -> 'completed' ->> 'neutral')::int
                                                              + (j -> 'completed' ->> 'negative')::int
                   and (j -> 'per_person' is null or jsonb_typeof(j -> 'per_person') <> 'array'
                        or (select coalesce(sum((p ->> 'orders')::int), 0) from jsonb_array_elements(j -> 'per_person') p) = (j -> 'completed' ->> 'orders')::int)
                   and s.o = (j -> 'markets_total' ->> 'orders')::int and s.d = (j -> 'markets_total' ->> 'due')::int
                   and s.c = (j -> 'markets_total' ->> 'completed')::int and s.c <= s.d and s.d <= s.o
              then '' else pg_temp.v0009d_page(j) end
  from (select coalesce(sum((m ->> 'completed_in_period')::int), 0) as cip, coalesce(sum((m ->> 'orders')::int), 0) as o,
               coalesce(sum((m ->> 'due')::int), 0) as d, coalesce(sum((m ->> 'completed')::int), 0) as c
        from jsonb_array_elements(j -> 'markets') m) s
$$;

-- 0009d's page equals 0009c's but for what 0009d changes: without settings.completed_tags, the tile, the previous period and
-- per person; markets_total without due, completed_in_period and 0009c's calls; the markets that hold an order of the period
-- (0009c's rows) without the same three; the groups and their markets without due
create or replace function pg_temp.v0009d_same(p_new jsonb, p_old jsonb)
returns boolean
language sql immutable
as $$
  select (n.j - 'markets' - 'groups') = (o.j - 'markets' - 'groups')
     and coalesce((select jsonb_agg(m - 'due' - 'completed_in_period' order by k) from jsonb_array_elements(p_new -> 'markets') with ordinality as x(m, k)
                   where (m ->> 'orders')::int + (m ->> 'no_contact')::int > 0), '[]'::jsonb)
         = coalesce((select jsonb_agg(m - 'calls' order by k) from jsonb_array_elements(p_old -> 'markets') with ordinality as x(m, k)
                     where (m ->> 'orders')::int + (m ->> 'no_contact')::int > 0), '[]'::jsonb)
     and coalesce((select jsonb_agg((g - 'due') || jsonb_build_object('markets', coalesce((select jsonb_agg(gm - 'due' order by gk)
                                                                                        from jsonb_array_elements(g -> 'markets') with ordinality as z(gm, gk)), '[]'::jsonb))
                                    order by k)
                   from jsonb_array_elements(p_new -> 'groups') with ordinality as y(g, k)), '[]'::jsonb)
         = coalesce(p_old -> 'groups', '[]'::jsonb)
     and (case when jsonb_typeof(p_new -> 'markets_total') = 'object' then (p_new -> 'markets_total') - 'due' - 'completed_in_period'
               else p_new -> 'markets_total' end)
         is not distinct from
         (case when jsonb_typeof(p_old -> 'markets_total') = 'object' then (p_old -> 'markets_total') - 'calls'
               else p_old -> 'markets_total' end)
  from (select (p_new - 'completed' - 'previous' - 'per_person' - 'markets_total') #- '{settings,completed_tags}' as j) n,
       (select (p_old - 'completed' - 'previous' - 'per_person' - 'markets_total') as j) o
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text;
  v_cfg     text;
  v_bad     text := '';
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0009c
  insert into verify_0009d values (1, 'A1 addition 0009d recorded, after 0009c',
    case when exists (select 1 from cma.schema_migration where version = '0009d')
              and exists (select 1 from cma.schema_migration where version = '0009c') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the two functions made again the application's only and in the caller's rights; the page with JIT off and custom plans
  foreach v_fn in array array['cma.courtesy_page_of(uuid,date,date,text,text,text,text,text,integer,boolean,timestamptz)',
                              'cma.courtesy_page(date,date,text,text,text,text,text,integer)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or has_function_privilege('public', v_fn, 'execute') or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' not the application''s only or not in the caller''s rights; ';
    end if;
  end loop;
  select array_to_string(proconfig, ',') into v_cfg from pg_proc
  where oid = to_regprocedure('cma.courtesy_page_of(uuid,date,date,text,text,text,text,text,integer,boolean,timestamptz)');
  if coalesce(v_cfg, '') not like '%jit=off%' or coalesce(v_cfg, '') not like '%plan_cache_mode=force_custom_plan%' then
    v_bad := v_bad || 'courtesy_page_of settings ' || coalesce(v_cfg, 'none') || '; ';
  end if;
  insert into verify_0009d values (2, 'A2 the page and its entry the application''s only and invoker; the page with JIT off and custom plans',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Completed courtesy orders on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_zed uuid; v_anna uuid; v_ing1 uuid; v_analyst2 uuid; v_admin2 uuid;
  v_crm uuid; v_tel uuid; v_nl uuid; v_be uuid; v_gb uuid; v_tel2 uuid; v_ing2 uuid;
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
    -- tenants, people and roles (as the owner, as 0009c's verify)
    v_t1 := cma.create_tenant('verify-0009d-one', 'Verify 0009d one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0009d-two', 'Verify 0009d two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-zed@example.invalid', 'Zed') returning id into v_zed;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-anna@example.invalid', 'Anna') returning id into v_anna;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_zed, 'agent'), (v_t1, v_anna, 'agent'),
                 (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id, settings)
    values (v_t1, 'verifycrm', 'crm', 'Verify orders CRM', 'portal-1', '{"record_url_contact": "https://crm.example.invalid/{account}/contact/{id}"}')
    returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifytel', 'telephony', 'Verify orders telephony', 'tel-1') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t2, 'verifytel', 'telephony', 'Verify orders telephony two', 'tel-2') returning id into v_tel2;
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifyshop', 'commerce', 'Verify orders shop NL', 'shop-nl.example.invalid') returning id into v_nl;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifyshop', 'commerce', 'Verify orders shop BE', 'shop-be.example.invalid') returning id into v_be;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifyshop', 'commerce', 'Verify orders shop GB', 'shop-gb.example.invalid') returning id into v_gb;
    insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
    values (v_t1, v_zed, 'verifytel_user', 'tu-1'), (v_t1, v_anna, 'verifytel_user', 'tu-2');
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
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "t-pos", "name": "Completed positive"}, {"tagRef": "t-neu", "name": "Completed neutral"},
      {"tagRef": "t-neg", "name": "Completed negative"}, {"tagRef": "t-att", "name": "Follow up"}]');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_number(v_tel, 'n-1', 'NL', true);
    perform cma.set_telephony_tag_meaning(v_tel, 't-pos', 'courtesy_completed_positive');
    perform cma.set_telephony_tag_meaning(v_tel, 't-neu', 'courtesy_completed_neutral');
    perform cma.set_telephony_tag_meaning(v_tel, 't-neg', 'courtesy_completed_negative');
    perform cma.set_telephony_tag_meaning(v_tel, 't-att', 'courtesy_attempt');

    -- the store customers (kX has one in NL and one in BE, both linked to the contact kX; c-no linked to none), the orders,
    -- the links and the contacts (UTC)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_commerce_customers(v_nl, (
      select jsonb_agg(jsonb_build_object('sourceId', 'c-' || k, 'updatedAt', '2026-09-01T00:00:00Z'))
      from unnest(array['kN', 'kO', 'kXn', 'kR', 'kN1', 'kE', 'no']) k));
    perform cma.ingest_upsert_commerce_customers(v_be, '[{"sourceId": "c-kXb", "updatedAt": "2026-09-01T00:00:00Z"},
      {"sourceId": "c-kB", "updatedAt": "2026-09-01T00:00:00Z"}]');
    perform cma.ingest_upsert_commerce_customers(v_gb, '[{"sourceId": "c-kS", "updatedAt": "2026-09-01T00:00:00Z"}]');
    perform cma.ingest_upsert_commerce_orders(v_nl, '[
      {"sourceId": "oN",   "customerId": "c-kN",  "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oR",   "customerId": "c-kR",  "createdAt": "2026-10-02T10:00:00Z", "updatedAt": "2026-10-02T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oXnl", "customerId": "c-kXn", "createdAt": "2026-10-10T10:00:00Z", "updatedAt": "2026-10-10T10:00:00Z", "priorOrdersCount": 1},
      {"sourceId": "oO",   "customerId": "c-kO",  "createdAt": "2026-10-20T10:00:00Z", "updatedAt": "2026-10-20T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oNc",  "customerId": "c-no",  "createdAt": "2026-11-11T10:00:00Z", "updatedAt": "2026-11-11T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oN1",  "customerId": "c-kN1", "createdAt": "2026-11-12T10:00:00Z", "updatedAt": "2026-11-12T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oE",   "customerId": "c-kE",  "createdAt": "2026-11-15T10:00:00Z", "updatedAt": "2026-11-15T10:00:00Z", "priorOrdersCount": 0}]');
    perform cma.ingest_upsert_commerce_orders(v_be, '[
      {"sourceId": "oXbe", "customerId": "c-kXb", "createdAt": "2026-10-05T10:00:00Z", "updatedAt": "2026-10-05T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oB",   "customerId": "c-kB",  "createdAt": "2026-11-14T10:00:00Z", "updatedAt": "2026-11-14T10:00:00Z", "priorOrdersCount": 0}]');
    perform cma.ingest_upsert_commerce_orders(v_gb, '[
      {"sourceId": "oS",   "customerId": "c-kS",  "createdAt": "2026-09-14T10:00:00Z", "updatedAt": "2026-09-14T10:00:00Z", "priorOrdersCount": 0}]');
    perform cma.set_commerce_customer_contact(v_nl, 'c-' || k, v_crm, k) from unnest(array['kN', 'kO', 'kR', 'kN1', 'kE']) k;
    perform cma.set_commerce_customer_contact(v_nl, 'c-kXn', v_crm, 'kX');
    perform cma.set_commerce_customer_contact(v_be, 'c-kXb', v_crm, 'kX');
    perform cma.set_commerce_customer_contact(v_be, 'c-kB', v_crm, 'kB');
    perform cma.set_commerce_customer_contact(v_gb, 'c-kS', v_crm, 'kS');
    perform cma.ingest_upsert_contacts(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', k, 'country', 'NL', 'updatedAt', '2026-09-01T00:00:00Z'))
      from unnest(array['kN', 'kO', 'kX', 'kR', 'kN1', 'kE', 'kB', 'kS']) k));

    -- the calls: each a CRM call on its contact logged by a telephony call with the same hash, 10 seconds earlier
    create temp table v0009d_calls (id text, contact text, at timestamptz, talk integer, usr text, tags text[]) on commit drop;
    insert into v0009d_calls values
      ('cS',  'kS', '2026-11-04T10:00:00Z', 60,   'tu-1', '{t-pos}'),
      ('cN',  'kN', '2026-10-12T10:00:00Z', 60,   'tu-1', '{t-pos}'),
      ('cO',  'kO', '2026-11-03T10:00:00Z', 60,   'tu-1', '{t-pos}'),
      ('cX',  'kX', '2026-10-22T10:00:00Z', 90,   'tu-2', '{t-neu}'),
      ('cR1', 'kR', '2026-10-13T10:00:00Z', null, 'tu-1', '{}'),
      ('cR2', 'kR', '2026-10-14T10:00:00Z', null, 'tu-1', '{}'),
      ('cR3', 'kR', '2026-10-15T10:00:00Z', null, 'tu-1', '{}'),
      ('cE',  'kE', '2026-11-16T10:00:00Z', 70,   'tu-1', '{t-neg}');
    perform cma.ingest_upsert_calls(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', c.id, 'occurredAt', c.at, 'direction', 'outbound', 'counterpartHash', md5(c.id) || md5(c.id || 'x'),
                                          'updatedAt', c.at))
      from v0009d_calls c));
    perform cma.ingest_upsert_associations(v_crm, (
      select jsonb_agg(jsonb_build_object('fromType', 'crm_call', 'fromId', c.id, 'toType', 'contact', 'toId', c.contact, 'removed', false,
                                          'changedAt', '2026-09-01T00:00:00Z'))
      from v0009d_calls c));
    perform cma.ingest_upsert_telephony_calls(v_tel, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'sourceId', 't' || c.id, 'direction', 'outbound', 'startedAt', c.at - interval '10 seconds',
               'answeredAt', case when c.talk is not null then c.at end,
               'endedAt', c.at + make_interval(secs => coalesce(c.talk, 20)), 'numberRef', 'n-1', 'userRef', c.usr,
               'counterpartHash', md5(c.id) || md5(c.id || 'x'), 'versionAt', c.at + interval '1 hour', 'tags', to_jsonb(c.tags))))
      from v0009d_calls c));
    perform cma.link_calls('2026-09-01T00:00:00Z');
    -- the segments (the CRM's mapped property, as the ingest would keep them): kS B2B, every other contact B2C
    perform set_config('role', 'cma_owner', true);
    update cma.crm_contact set segment = case source_id when 'kS' then 'B2B' else 'B2C' end
    where tenant_id = v_t1 and source_id in ('kS', 'kN', 'kO', 'kX', 'kR', 'kN1', 'kE', 'kB');
    perform set_config('role', 'cma_app', true);

    -- B7 (first part). Not set up: every figure null, markets_total null, the completed tags there already
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.courtesy_page_of(v_t1, v_oct_from, v_oct_to, 'week', 'week', null, null, null, 100, true, v_now);
    v_unset := format('set_up %s; completed %s; previous %s; per_person %s; markets_total %s; markets %s; tags %s', j ->> 'set_up',
                      coalesce(j ->> 'completed', 'null'), coalesce(j ->> 'previous', 'null'), coalesce(j ->> 'per_person', 'null'),
                      coalesce(j ->> 'markets_total', 'null'), j -> 'markets', j -> 'settings' -> 'completed_tags');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('courtesy.start_date', '2026-09-07');
    perform set_config('app.user_id', v_analyst1::text, true);

    -- B1. the four totals are equal (the tile, the markets' completed in the period and markets_total's, the outcomes, per
    --     person), and the markets' order columns add up, for October and November, unfiltered and with each filter
    v_txt2 := '';
    v_n := 0;
    for f in select * from (values (null::text, null::text, null::text), ('NL', null, null), ('BE', null, null), ('GB', null, null),
                                   (null, 'B2C', null), (null, null, 'unreachable')) as x(market, segment, state) loop
      for t in select * from (values (v_oct_from, v_oct_to), (v_nov_from, v_nov_to)) as y(pfrom, pto) loop
        j := cma.courtesy_page_of(v_t1, t.pfrom, t.pto, 'week', 'week', f.market, f.segment, f.state, 100, true, v_now);
        v_n := v_n + 1;
        if pg_temp.v0009d_totals(j) <> '' then
          v_txt2 := v_txt2 || format('%s %s/%s/%s: %s; ', to_char(t.pfrom, 'Mon'), coalesce(f.market, '-'), coalesce(f.segment, '-'),
                                     coalesce(f.state, '-'), pg_temp.v0009d_totals(j));
        end if;
      end loop;
    end loop;
    v_rows := v_rows || array['11', 'B1 the tile = the markets'' completed in the period = the outcomes = per person, with every filter',
      case when v_txt2 = '' and v_n = 12 and not v_provoke then 'PASS' else 'FAIL' end,
      case when v_txt2 = '' then format('%s pages, every one adds up', v_n) else v_txt2 end];

    -- B2. Anna's one call completes kX's two open orders: 2 in the tile and in per person, BE's in BE and NL's in NL;
    --     with the market filter NL only NL's
    j := cma.courtesy_page_of(v_t1, v_oct_from, v_oct_to, 'week', 'week', null, null, null, 100, true, v_now);
    v_txt2 := pg_temp.v0009d_page(j);
    j2 := cma.courtesy_page_of(v_t1, v_oct_from, v_oct_to, 'week', 'week', 'NL', null, null, 100, true, v_now);
    v_txt2 := v_txt2 || ' || NL ' || pg_temp.v0009d_page(j2);
    select count(distinct o.completed_call_id), count(*) into v_n, v_m
    from cma.courtesy_orders_of(v_t1, null, null, v_now) o where o.order_source_id in ('oXbe', 'oXnl');
    v_rows := v_rows || array['12', 'B2 one call completing two open orders counts 2 in the tile and per person, each in its own market',
      case when v_txt2 = 'BE:1/1/1/1/0/0 NL:4/4/3/2/1/0 | total 5/5/4/3/1/0 | tile 3 | outcomes 1/2/0 | people Anna:2/0/2/0 Zed:1/1/0/0 '
                         || '|| NL NL:4/4/3/2/1/0 | total 4/4/3/2/1/0 | tile 2 | outcomes 1/1/0 | people Anna:1/0/1/0 Zed:1/1/0/0'
                and v_n = 1 and v_m = 2
                and not v_provoke then 'PASS' else 'FAIL' end, format('%s; %s call completing %s orders', v_txt2, v_n, v_m)];

    -- B3. an order placed in the period with nothing due: BE in November holds kB's order of 14 November, due the 24th, so
    --     due 0 and the share (of which courtesy completed over of which due) null; its week (from 9 November) alike
    j := cma.courtesy_page_of(v_t1, v_nov_from, v_nov_to, 'week', 'week', null, null, null, 100, true, v_now);
    select format('BE orders %s due %s completed %s share %s', m ->> 'orders', m ->> 'due', m ->> 'completed',
                  coalesce(((m ->> 'completed')::numeric / nullif((m ->> 'due')::int, 0))::text, 'null'))
      into v_txt2 from jsonb_array_elements(j -> 'markets') m where m ->> 'market' = 'BE';
    select v_txt2 || format('; week %s BE orders %s due %s share %s', g ->> 'key', gm ->> 'orders', gm ->> 'due',
                            coalesce(((gm ->> 'completed')::numeric / nullif((gm ->> 'due')::int, 0))::text, 'null'))
      into v_txt2
    from jsonb_array_elements(j -> 'groups') g, jsonb_array_elements(g -> 'markets') gm
    where g ->> 'key' = '2026-11-09' and gm ->> 'market' = 'BE';
    v_rows := v_rows || array['13', 'B3 an order placed in the period with nothing due gives due 0 and a null share',
      case when v_txt2 = 'BE orders 1 due 0 completed 0 share null; week 2026-11-09 BE orders 1 due 0 share null'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt2, 'null')];

    -- B4. an order completed before its due date counts in due and in completed: kE's of 15 November, due the 25th,
    --     completed on the 16th; November's NL: kN1's not due yet, kE's due and completed, the order without a contact
    select format('%s:%s/%s/%s', o.order_source_id, to_char(o.due_date, 'MMDD'), o.state, to_char(o.completed_date, 'MMDD'))
      into v_txt from cma.courtesy_orders_of(v_t1, null, null, v_now) o where o.order_source_id = 'oE';
    v_txt2 := pg_temp.v0009d_page(j);
    v_rows := v_rows || array['14', 'B4 an order completed before its due date counts in due and in completed',
      case when v_txt = 'oE:1125/completed/1116'
                and v_txt2 = 'BE:1/0/0/0/0/0 GB:0/0/0/1/0/0 NL:2/1/1/2/0/1 | total 3/1/1/3/0/1 | tile 3 | outcomes 2/0/1 | people Zed:3/2/0/1'
                and not v_provoke then 'PASS' else 'FAIL' end, format('%s; %s', coalesce(v_txt, 'null'), v_txt2)];

    -- B5. completed_tags: tenant one's three mapped names in name order (the courtesy_attempt tag is not one); tenant two,
    --     whose tags mean an attempt and not reached, none completed, an empty list; once tenant two maps a tag to
    --     completed, tenant two lists that one and tenant one still its own three
    v_txt2 := (j -> 'settings' -> 'completed_tags')::text;
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel2, 'tag', '[{"tagRef": "t2-att", "name": "Follow up two"},
      {"tagRef": "t2-nr", "name": "No answer two"}, {"tagRef": "t2-done", "name": "Done two"}]');
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.set_telephony_tag_meaning(v_tel2, 't2-att', 'courtesy_attempt');
    perform cma.set_telephony_tag_meaning(v_tel2, 't2-nr', 'not_reached');
    perform cma.set_tenant_setting('courtesy.start_date', '2026-09-07');
    perform set_config('app.user_id', v_analyst2::text, true);
    j2 := cma.courtesy_page(v_oct_from, v_oct_to);
    v_txt2 := v_txt2 || ' | two ' || (j2 -> 'settings' -> 'completed_tags')::text;
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.set_telephony_tag_meaning(v_tel2, 't2-done', 'courtesy_completed_neutral');
    perform set_config('app.user_id', v_analyst2::text, true);
    v_txt2 := v_txt2 || ' | two mapped ' || (cma.courtesy_page(v_oct_from, v_oct_to) -> 'settings' -> 'completed_tags')::text;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt2 := v_txt2 || ' | one ' || (cma.courtesy_page(v_oct_from, v_oct_to) -> 'settings' -> 'completed_tags')::text;
    v_rows := v_rows || array['15', 'B5 completed_tags lists the mapped names in name order, empty without a mapping',
      case when v_txt2 = '["Completed negative", "Completed neutral", "Completed positive"] | two [] | two mapped ["Done two"]'
                         || ' | one ["Completed negative", "Completed neutral", "Completed positive"]'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt2];

    -- B6. every other answer as 0009c's definition: periods October, November and 7 September to 20 November; every group;
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
        j2 := pg_temp.old_courtesy_page_of(v_t1, t.pfrom, t.pto, f.coh, f.grp, f.market, f.segment, f.state, f.lim, f.per_person, v_now);
        v_n := v_n + 1;
        if not pg_temp.v0009d_same(j, j2) then
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
      if not pg_temp.v0009d_same(j, j2) then
        v_txt2 := v_txt2 || format('tenant %s; ', t.id);
      end if;
    end loop;
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['16', 'B6 every other answer as 0009c''s definition, for every period, group, cohort and filter tried and in every tenant',
      case when v_txt2 = '' and v_n = 144 and v_m >= 1 and not v_provoke then 'PASS' else 'FAIL' end,
      case when v_txt2 = '' then format('%s pages here and %s tenants equal', v_n, v_m) else v_txt2 end];

    -- B7. the previous period counts orders as the tile does: 1 to 20 November's previous is 12 to 31 October (cut at now's
    --     time of day), when Zed's call completed kN's order and Anna's one call kX's two (3 orders, 2 calls); and not set
    --     up, every figure stays null
    j := cma.courtesy_page_of(v_t1, v_nov_from, date '2026-11-20', 'week', 'week', null, null, null, 100, true, v_now);
    select v_unset || format(' || previous %s..%s partial %s: %s', j ->> 'previous_from', j ->> 'previous_to', j ->> 'previous_partial',
                             j -> 'previous') into v_txt2;
    v_rows := v_rows || array['17', 'B7 the previous period counts orders; not set up keeps every figure null',
      case when v_unset = 'set_up false; completed null; previous null; per_person null; markets_total null; markets []; '
                          || 'tags ["Completed negative", "Completed neutral", "Completed positive"]'
                and j ->> 'previous_from' = '2026-10-12' and j ->> 'previous_to' = '2026-10-31'
                and (j -> 'previous') = '{"orders": 3, "neutral": 2, "negative": 0, "positive": 1}'::jsonb
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt2];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then
      v_rows := v_rows || array['49', 'B ran to the end', case when not v_provoke then 'PASS' else 'FAIL' end, ''];
    when others then
      v_rows := v_rows || array['49', 'B ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0009d (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009d values (49, 'B ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009d_same(jsonb, jsonb);
drop function if exists pg_temp.v0009d_totals(jsonb);
drop function if exists pg_temp.v0009d_page(jsonb);
drop function if exists pg_temp.old_courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz);

-- Verdict: one row per check, then the verdict: OK when all 10 checks pass
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009d
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT OK'
                  when (select count(*) from verify_0009d where result = 'PASS') = 10
                       and not exists (select 1 from verify_0009d where result <> 'PASS') then 'OK'
                  else 'FAIL' end,
             format('157_verify_courtesy_completed_orders: %s PASS, %s FAIL', (select count(*) from verify_0009d where result = 'PASS'),
                                                                            (select count(*) from verify_0009d where result <> 'PASS'))) x
order by ord;
reset role;
