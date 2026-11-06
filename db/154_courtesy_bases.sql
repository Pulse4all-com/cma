-- =============================================================================================
-- 154_courtesy_bases.sql: addition 0009c, Customers → Courtesy per market adds the calls completed in the period
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 150_courtesy.sql (0009a).
-- It does not depend on 152_calls_of_restore.sql (0009b, brief B32): neither reads what the other changes, so either can
-- run first. Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first (this
-- script, then 155_verify_courtesy_bases.sql, then 151_verify_courtesy.sql again: it reads cma.courtesy_page_of and
-- cma.courtesy_page, and this change does not edit it), then prod, then 131_time_all.sql part b (the courtesy read over
-- the previous month and 92 days). No table, view, column or setting changes, no seed need run again, nothing stored
-- needs computing again, and the data map's schema does not change: the page is computed when read.
-- The web of main runs unchanged on it (the page keeps every field it had and gains two). The web of this change reads
-- the new fields, so in prod this script runs right after the merge, before the build finishes, as 0009a did.
--
-- Why (Martin, 6 November 2026; Decision log, brief B33): on Customers → Courtesy the tile counted the completed courtesy
-- calls made in the period (by call date, for orders of any date), while Per market and Per week counted the orders
-- placed in the period with their state now (by order date). Side by side they read as a contradiction: in a month whose
-- orders are not due yet the tile reads 17 and every market 0. Each block now says its basis, and Per market gains the
-- calls completed in the period, so its rows add up to the tile.
--
-- What it changes: cma.courtesy_page_of, 0009a's definition with two additions (the arguments, every other field and
-- every other answer the same; 155 compares it with 150's text, kept inside it, field for field):
--   markets[].calls   per market, the completed courtesy calls of the period (by their completion date in the order's
--                     zone, as the tile), each call once, in the market of the earliest courtesy order it completed
--                     among the orders the filters keep (by creation, then id). The column's total is the tile's calls
--                     for the same period and filters. A market with calls of the period and no order placed in it has
--                     a row of its own, its order counts 0
--   markets_total     under Per market: orders, completed, calls, not reached and no contact over every row (null while
--                     courtesy is not set up)
-- Per week (groups) keeps its order counts alone: its rows are order dates, and a call column there would mix the bases.
-- cma.courtesy_page (the application's entry, its checks and its arguments) is unchanged and not made again.
-- SQLSTATEs: none raised but the guards'.
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
  if not exists (select 1 from cma.schema_migration where version = '0009a') then
    raise exception 'addition 0009a (150_courtesy.sql) must run before 0009c';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Customers → Courtesy in one read, with the calls of the period per market
-- ---------------------------------------------------------------------------------------------
-- The page of an explicit tenant as of p_now, as one JSON object. Two kinds of figure:
--   now     every courtesy order since courtesy.start_date as of p_now, narrowed by market and segment: the orders due
--           without completion, Not reached, No contact and the states (the tiles), and the order list (also by state,
--           the first p_rows with the filtered total; Not reached first, then due without an attempt, attempted, not due,
--           no contact, completed; then by due date)
--   period  two bases, each block saying which:
--           by call date   the completed courtesy calls of the period by their completion date, for orders of any date
--                          (distinct calls, per outcome; the tile) and the previous period like for like
--                          (cma.forms_previous_of, the last day cut at p_now's time of day in the order's zone); per market
--                          the same calls, each once, in the market of the earliest courtesy order it completed among the
--                          filtered orders (0009c), so the markets' calls add up to the tile; per person (only with
--                          p_per_person) by the person of the completing call's user, by name, the calls without one last
--           by order date  the courtesy orders created on the period's business dates [p_from, p_to] with their state now:
--                          per market (and their total, 0009c) and per day, ISO week or month (p_group) the orders with a
--                          contact, completed, Not reached and No contact; the order cohorts per ISO week or month
--                          (p_period) at the ages of courtesy.ages_days
-- Not set up (courtesy.start_date empty): set_up false and every figure null
-- based on: 150_courtesy.sql
create or replace function cma.courtesy_page_of(p_tenant_id uuid, p_from date, p_to date, p_period text, p_group text, p_market text,
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
             coalesce(c.calls, 0) as calls, coalesce(o.not_reached, 0) as not_reached, coalesce(o.no_contact, 0) as no_contact
      from (select p.market, count(*) filter (where p.has_contact) as orders, count(*) filter (where p.state = 'completed') as completed,
                   count(*) filter (where p.state = 'not_reached') as not_reached, count(*) filter (where not p.has_contact) as no_contact
            from p group by p.market) o
      full join (select cm.market, count(*) as calls from cm group by cm.market) c on c.market = o.market
    ), l as materialized (
      -- the list's order on the narrow keys alone (the rows' details are joined for the first p_rows only)
      select f.order_id, row_number() over (order by case f.state when 'not_reached' then 1 when 'due_no_attempt' then 2 when 'attempted' then 3
                                                                  when 'not_due' then 4 when 'completed' then 6 else 5 end,
                                                     f.due_date, f.created_at, f.order_id) as n
      from f where cma.courtesy_state_matches(f.state, p_state)
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
                                                               'calls', m.calls, 'not_reached', m.not_reached, 'no_contact', m.no_contact)
                                            order by (m.market = 'unknown'), mk.sort_order, m.market), '[]'::jsonb)
                  from mm m
                  left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = m.market),
      'markets_total', (select jsonb_build_object('orders', coalesce(sum(m.orders), 0), 'completed', coalesce(sum(m.completed), 0),
                                                  'calls', coalesce(sum(m.calls), 0), 'not_reached', coalesce(sum(m.not_reached), 0),
                                                  'no_contact', coalesce(sum(m.no_contact), 0))
                        from mm m),
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
-- A create or replace drops a function's settings (CLAUDE.md, Performance), so 0009a's two are set again: JIT off as the
-- other large reads (132), and custom plans always (the generic plan took the page from 1.2 to 1.7 s at three times prod's
-- volume)
alter function cma.courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz) set jit = off;
alter function cma.courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz) set plan_cache_mode = force_custom_plan;

-- ---------------------------------------------------------------------------------------------
-- 2. Grants: the application only (a function made again keeps its grants; said again so the script stands alone)
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz) from public;
grant execute on function cma.courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 3. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009c', 'Customers → Courtesy: the two bases unmistakable. cma.courtesy_page_of (0009a''s definition, every other answer the same) adds per market the courtesy calls completed in the period (by call date, as the tile), each call once in the market of the earliest courtesy order it completed among the filtered orders, so the markets'' calls add up to the tile, and markets_total (orders, completed, calls, not reached, no contact); the web labels the tile by call date and the order blocks by order date')
on conflict (version) do nothing;

commit;
reset role;
