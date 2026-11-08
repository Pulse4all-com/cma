-- =============================================================================================
-- 156_courtesy_completed_orders.sql: addition 0009d, Customers → Courtesy counts completed courtesy orders, never
-- completed calls; Of which due
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 154_courtesy_bases.sql
-- (0009c). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- prod. The verifies that read a function this script makes again (CLAUDE.md, Database), run after it in dev:
--   157_verify_courtesy_completed_orders.sql  this change's own
--   151_verify_courtesy.sql                   reads cma.courtesy_page_of and cma.courtesy_page; edited by this change
--                                             (B8, B9, B13 and B14 count completed courtesy orders, no longer calls)
--   155_verify_courtesy_bases.sql             reads both; edited by this change (B1 to B4: the markets' completed orders
--                                             each in their own market, no longer a call in the earliest order's market;
--                                             B4 leaves 0009d's figures out of its comparison with 150's text, 157
--                                             compares them with 154's)
--   103_verify_tag_meaning_incorrect_data.sql its A3 reads the source of every function (no 'not_reached' here); not edited
-- and, though they read neither function, 81_verify_follow_up_snapshot.sql and 73_verify_follow_up.sql (the follow-up
-- snapshot's courtesy count, unchanged); then in prod 131_time_all.sql part b (the courtesy read over the previous month
-- and 92 days). No table, view or column changes, no seed need run again, and the data map's schema does not change: the
-- page is computed when read.
--
-- Prod order, as 0009c's: this script runs in prod right after the merge, before the build finishes; the web of this
-- change reads the new keys. Between this script and the deploy, main's web (0009c's) reads keys that are gone: the tile
-- "Courtesy calls completed in the period", its previous period, the outcome bar, Per market's last column and its total,
-- and Per person read completed.calls, previous.calls, markets[].calls, markets_total.calls and per_person[].calls, so for
-- those minutes they show "NaN" (a missing number formatted) and the outcome bar's segments and shares lose their widths
-- and values; every other figure, the order list and Welcome stay as they are.
--
-- Why (Martin, 8 November 2026; Decision log, brief B34): "Courtesy calls completed in the period" and "Calls completed in
-- the period" read as any finished call (a follow-up call is also completed), and "Of which completed" reads as delivery.
-- For November the page showed 80 orders, 0 completed, 0% beside 17 completed calls, which a reader takes as 0% done
-- while no order was due yet. "Completed" means only that a courtesy order got its completing call: the first call on its
-- contact, from the order on, with a tag meaning courtesy completed positive, neutral or negative.
--   unit       the period figures count courtesy orders, not calls: an order counts in the period of its completion
--              (completed_at, by its day in the order's market zone), placed on any date. The tile, its outcomes, the
--              previous period, Per market's last column (completed_in_period, each order in its own market) and Per
--              person; one call that completes several orders counts once per order. So the tile = the sum of Per
--              market's last column = the sum of the outcomes = the sum of Per person
--   due        each order block (Per market, its total, Per day, week or month) gains due: the orders placed in the span
--              whose due date is today or earlier, plus those completed before their due date (every state but not_due).
--              The web's Completion share is of which courtesy completed over of which due, so at most 100%; a dash at 0 due
--   the tags   settings.completed_tags: the names of the tenant's telephony tags whose meaning completes an order, in name
--              order, empty without one; the hints name them
--
-- What it changes (functions only, each made again from its latest definition, 154's, with its based-on line):
--   cma.courtesy_page_of   completed {orders, positive, neutral, negative} and previous {...} count orders (0009c's calls);
--                          markets[] gains due and completed_in_period (0009c's calls); markets_total gains due and
--                          completed_in_period; groups[] and groups[].markets[] gain due; per_person[].orders (0009c's
--                          calls); settings.completed_tags. now, the list, the cohorts and the filters are unchanged (157
--                          compares them with 154's text, kept inside it)
--   cma.courtesy_page      unchanged in its checks and arguments; made again as the page's entry
-- SQLSTATEs as before.
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
  if not exists (select 1 from cma.schema_migration where version = '0009c') then
    raise exception 'addition 0009c (154_courtesy_bases.sql) must run before 0009d';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Customers → Courtesy in one read: completed courtesy orders, of which due, the completed tags
-- ---------------------------------------------------------------------------------------------
-- The page of an explicit tenant as of p_now, as one JSON object. Every figure counts courtesy orders (0009d), on one of
-- three bases, each block saying which:
--   now               every courtesy order since courtesy.start_date as of p_now, narrowed by market and segment: the
--                     orders due without completion, Unreachable, No contact and the states (the tiles), and the order list
--                     (also by state, the first p_rows with the filtered total; Unreachable first, then due without an
--                     attempt, attempted, not due, no contact, completed; then by due date)
--   completion date   the courtesy orders completed in the period by their completion date (completed_at, its day in the
--                     order's market zone), placed on any date: the tile and its outcomes, the previous period like for
--                     like (cma.forms_previous_of, the last day cut at p_now's time of day in the order's zone), per
--                     market (completed_in_period, each order in its own market) and per person (only with p_per_person,
--                     by the person of the completing call's user, by name, the orders without one last). One call that
--                     completes several orders counts once per order, so the tile = the markets' completed_in_period =
--                     the outcomes = per person
--   order date        the courtesy orders created on the period's business dates [p_from, p_to] with their state now: per
--                     market (and their total) and per day, ISO week or month (p_group) the orders with a contact, of
--                     which due (the due date today or earlier, or completed before it), of which courtesy completed,
--                     Unreachable and No contact; the order cohorts per ISO week or month (p_period) at the ages of
--                     courtesy.ages_days
-- settings.completed_tags names the tenant's tags that complete an order, for the hints. Not set up
-- (courtesy.start_date empty): set_up false and every figure null
-- based on: 154_courtesy_bases.sql
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
      'ages', to_jsonb(v_ages), 'order_kinds', to_jsonb(cma.courtesy_kinds_of(p_tenant_id)),
      -- the names of the tenant's telephony tags whose meaning completes a courtesy order (cma.courtesy_outcome_of names
      -- the three meanings), in name order; empty while none is mapped (0009d)
      'completed_tags', coalesce((select jsonb_agg(t.name order by t.name)
                                  from (select distinct tg.name from cma.telephony_tag tg
                                        where tg.tenant_id = p_tenant_id and cma.courtesy_outcome_of(tg.meaning) is not null) t),
                                 '[]'::jsonb)),
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
    ), mm as materialized (
      -- per market: the period's orders by order date (with a contact, of which due, of which courtesy completed, Unreachable,
      -- no contact) beside the courtesy orders completed in the period by completion date, placed on any date, each in its
      -- own market (0009d; 0009c's call in the earliest order's market is gone); a market with either has a row. Due: the
      -- due date is today or earlier, or the order was completed before it (every state but not_due)
      select coalesce(o.market, c.market) as market, coalesce(o.orders, 0) as orders, coalesce(o.due, 0) as due,
             coalesce(o.completed, 0) as completed, coalesce(c.completed_in_period, 0) as completed_in_period,
             coalesce(o.unreachable, 0) as unreachable, coalesce(o.no_contact, 0) as no_contact
      from (select p.market, count(*) filter (where p.has_contact) as orders,
                   count(*) filter (where p.has_contact and p.state <> 'not_due') as due,
                   count(*) filter (where p.state = 'completed') as completed,
                   count(*) filter (where p.state = 'unreachable') as unreachable, count(*) filter (where not p.has_contact) as no_contact
            from p group by p.market) o
      full join (select f.market, count(*) as completed_in_period from f where f.done_in group by f.market) c on c.market = o.market
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
      -- the courtesy orders completed in the period by their completion date, placed on any date; one call completing two
      -- orders counts twice (0009d); and the previous period like for like
      'completed', (select jsonb_build_object(
                      'orders', count(*) filter (where f.done_in),
                      'positive', count(*) filter (where f.done_in and f.outcome = 'positive'),
                      'neutral', count(*) filter (where f.done_in and f.outcome = 'neutral'),
                      'negative', count(*) filter (where f.done_in and f.outcome = 'negative')) from f),
      'previous', (select jsonb_build_object(
                     'orders', count(*) filter (where f.done_prev),
                     'positive', count(*) filter (where f.done_prev and f.outcome = 'positive'),
                     'neutral', count(*) filter (where f.done_prev and f.outcome = 'neutral'),
                     'negative', count(*) filter (where f.done_prev and f.outcome = 'negative')) from f),
      'previous_from', v_prev.prev_from, 'previous_to', v_prev.prev_to, 'previous_partial', v_prev.until is not null,
      'markets', (select coalesce(jsonb_agg(jsonb_build_object('market', m.market, 'name', mk.name, 'orders', m.orders, 'due', m.due,
                                                               'completed', m.completed, 'completed_in_period', m.completed_in_period,
                                                               'unreachable', m.unreachable, 'no_contact', m.no_contact)
                                            order by (m.market = 'unknown'), mk.sort_order, m.market), '[]'::jsonb)
                  from mm m
                  left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = m.market),
      'markets_total', (select jsonb_build_object('orders', coalesce(sum(m.orders), 0), 'due', coalesce(sum(m.due), 0),
                                                  'completed', coalesce(sum(m.completed), 0),
                                                  'completed_in_period', coalesce(sum(m.completed_in_period), 0),
                                                  'unreachable', coalesce(sum(m.unreachable), 0), 'no_contact', coalesce(sum(m.no_contact), 0))
                        from mm m),
      'groups', (select jsonb_agg(jsonb_build_object('key', g.key, 'orders', coalesce(t.orders, 0), 'due', coalesce(t.due, 0),
                                                     'completed', coalesce(t.completed, 0),
                                                     'unreachable', coalesce(t.unreachable, 0), 'no_contact', coalesce(t.no_contact, 0),
                                                     'markets', coalesce(t.markets, '[]'::jsonb))
                                  order by g.key)
                 from (select k::date as key
                       from generate_series(case p_group when 'day' then p_from when 'month' then date_trunc('month', p_from)::date
                                                 else date_trunc('week', p_from)::date end, p_to,
                                            case p_group when 'day' then interval '1 day' when 'month' then interval '1 month'
                                                 else interval '7 days' end) k) g
                 left join (select gm.group_key, sum(gm.orders) as orders, sum(gm.due) as due, sum(gm.completed) as completed,
                                   sum(gm.unreachable) as unreachable,
                                   sum(gm.no_contact) as no_contact,
                                   jsonb_agg(jsonb_build_object('market', gm.market, 'orders', gm.orders, 'due', gm.due, 'completed', gm.completed,
                                                                'unreachable', gm.unreachable, 'no_contact', gm.no_contact)
                                             order by (gm.market = 'unknown'), gm.sort_order, gm.market) as markets
                            from (select p.group_key, p.market, coalesce(mk.sort_order, 2147483647) as sort_order,
                                         count(*) filter (where p.has_contact) as orders,
                                         count(*) filter (where p.has_contact and p.state <> 'not_due') as due,
                                         count(*) filter (where p.state = 'completed') as completed,
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
                      (select coalesce(jsonb_agg(jsonb_build_object('user_id', pp.uid, 'name', u.display_name, 'orders', pp.orders,
                                                                    'positive', pp.positive, 'neutral', pp.neutral, 'negative', pp.negative)
                                                 order by (pp.uid is null), u.display_name, pp.uid), '[]'::jsonb)
                       from (select f.completed_by as uid, count(*) as orders,
                                    count(*) filter (where f.outcome = 'positive') as positive,
                                    count(*) filter (where f.outcome = 'neutral') as neutral,
                                    count(*) filter (where f.outcome = 'negative') as negative
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
-- A create or replace drops a function's settings (CLAUDE.md, Performance), so 0009a's two are set again: JIT off as the
-- other large reads (132), and custom plans always
alter function cma.courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz) set jit = off;
alter function cma.courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz) set plan_cache_mode = force_custom_plan;

-- ---------------------------------------------------------------------------------------------
-- 2. The page's entry
-- ---------------------------------------------------------------------------------------------
-- Customers → Courtesy in one read (reports.view or performance.team, CMA06; a period of at most 92 days, cma.report_range).
-- p_period week or month (the order cohorts), p_group day, week or month (per market and period), p_market a market's code
-- or unknown, p_segment a segment code or unknown, p_state one of not_due, due_no_attempt, attempted, unreachable,
-- completed, due or no_contact; anything else CMA04. p_rows defaults to follow_up.list_rows and is held within 1 to 500.
-- Per person only for performance.team (null otherwise). 0009d makes it again with its checks and arguments unchanged: it is
-- the page's entry, and the page it returns counts orders where 0009c's counted calls
-- based on: 154_courtesy_bases.sql
create or replace function cma.courtesy_page(p_from date, p_to date, p_period text default 'week', p_group text default 'week',
                                             p_market text default null, p_segment text default null, p_state text default null,
                                             p_rows integer default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid;
begin
  v_user := cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  if p_period is null or p_period not in ('week', 'month') then
    raise exception 'period is week or month, not %', coalesce(p_period, 'none') using errcode = 'CMA04';
  end if;
  if p_group is null or p_group not in ('day', 'week', 'month') then
    raise exception 'group by day, week or month, not %', coalesce(p_group, 'none') using errcode = 'CMA04';
  end if;
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'a market filter is a two-letter code or unknown' using errcode = 'CMA04';
  end if;
  if p_segment is not null and p_segment !~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$' then
    raise exception 'a segment filter is a segment''s code or unknown' using errcode = 'CMA04';
  end if;
  if p_state is not null and p_state not in ('not_due', 'due_no_attempt', 'attempted', 'unreachable', 'completed', 'due', 'no_contact') then
    raise exception 'a state filter is not_due, due_no_attempt, attempted, unreachable, completed, due or no_contact' using errcode = 'CMA04';
  end if;
  return cma.courtesy_page_of(v_tenant, p_from, p_to, p_period, p_group, p_market, p_segment, p_state,
                              least(500, greatest(1, coalesce(p_rows, cma.setting_of(v_tenant, 'follow_up.list_rows')::integer))),
                              cma.has_permission(v_user, 'performance.team'), now());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Grants: the application only (a function made again keeps its grants; said again so the script stands alone)
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz) from public;
grant execute on function cma.courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz) to cma_app;
revoke execute on function cma.courtesy_page(date, date, text, text, text, text, text, integer) from public;
grant execute on function cma.courtesy_page(date, date, text, text, text, text, text, integer) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 4. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009d', 'Customers → Courtesy counts completed courtesy orders, never completed calls: cma.courtesy_page_of (0009c''s definition) counts the tile, its outcomes, the previous period and per person as courtesy orders by their completion date (one call completing two orders counts twice), per market completed_in_period each order in its own market (0009c''s earliest-order rule gone), and adds due (of which due: the due date today or earlier, or completed before it) per market, per group and in markets_total, and settings.completed_tags (the tenant''s tags that complete an order); cma.courtesy_page made again unchanged; the web''s Completion share is of which courtesy completed over of which due')
on conflict (version) do nothing;

commit;
reset role;
