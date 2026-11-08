-- =============================================================================================
-- 154_courtesy_bases.sql: addition 0009c, Customers → Courtesy per market adds the calls completed in the period, and
-- the courtesy state Not reached is Unreachable
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 150_courtesy.sql (0009a),
-- and does not depend on 152_calls_of_restore.sql (0009b): neither reads what the other changes. Rerunnable,
-- forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then prod. The verifies
-- that read a function this script makes again (CLAUDE.md, Database), run after it in dev:
--   155_verify_courtesy_bases.sql            this change's own
--   151_verify_courtesy.sql                  reads every courtesy function and the follow-up summary; edited by this
--                                            change for the state unreachable and the column courtesy_unreachable
--   103_verify_tag_meaning_incorrect_data.sql  its A3 holds that no function but the setter and the helper names the tag
--                                            meaning key not_reached: since 0009a the courtesy functions named it as a
--                                            state; not edited
--   81_verify_follow_up_snapshot.sql         reads cma.refresh_follow_up_of and cma.follow_up_summary(); edited by this
--                                            change (its B2 and B11 leave courtesy_unreachable out, as they left 0009a's
--                                            courtesy_not_reached out)
--   73_verify_follow_up.sql                  reads cma.refresh_follow_up_of and cma.follow_up_summary(); not edited
-- then in prod 131_time_all.sql part b (the courtesy read over the previous month and 92 days). No table, view or
-- column of a table changes, no seed need run again, and the data map's schema does not change: the page is computed
-- when read; the follow-up snapshot's summary is jsonb, whose courtesy key is renamed in place (below).
-- The web of main reads cma.follow_up_summary()'s courtesy column as optional, so between this script in prod and the
-- deploy of this change Welcome's courtesy line is missing for a few minutes, and main's Courtesy page shows no
-- Unreachable count (it reads the old key). The web of this change reads the new fields and names, so in prod this
-- script runs right after the merge, before the build finishes, as 0009a did.
--
-- Why (Martin, 6 November 2026; Decision log, brief B33):
--   the bases  on Customers → Courtesy the tile counted the completed courtesy calls made in the period (by call date,
--              for orders of any date), while Per market and Per week counted the orders placed in the period with
--              their state now (by order date). Side by side they read as a contradiction: in a month whose orders are
--              not due yet the tile reads 17 and every market 0. Each block now says its basis, and Per market gains the
--              calls completed in the period, so its rows add up to the tile.
--   the state  "not reached" is a tag meaning (docs/definitions.md, Tag; it keeps a call from being a Conversation), and
--              103's A3 rightly flags every function but the setter and the helper that names 'not_reached'. The
--              courtesy state that 0009a called not_reached is unreachable (Unreachable, nl Onbereikbaar), so the tag
--              meaning keeps one meaning. The tag meaning not_reached, its label and cma.call_not_reached_of are untouched;
--              courtesy.alert_attempts keeps its name.
--
-- What it changes (functions, one setting's description and the snapshot's jsonb key; every function made again from
-- its latest definition, 150's, with its based-on line):
--   cma.courtesy_page_of      0009a's definition with two additions (the arguments and every other answer the same;
--                             155 compares it with 150's text, kept inside it, field for field, with the state renamed):
--     markets[].calls         per market, the completed courtesy calls of the period (by their completion date in the
--                             order's zone, as the tile), each call once, in the market of the earliest courtesy order
--                             it completed among the orders the filters keep (by creation, then id). The column's total
--                             is the tile's calls for the same period and filters. A market with calls of the period
--                             and no order placed in it has a row of its own, its order counts 0
--     markets_total           under Per market: orders, completed, calls, unreachable and no contact over every row
--                             (null while courtesy is not set up)
--                             Per week (groups) keeps its order counts alone: its rows are order dates
--   the state                 not_reached is unreachable in cma.courtesy_orders_of (the state), cma.courtesy_state_matches
--                             (due), cma.courtesy_page_of (the JSON keys now.unreachable, markets[].unreachable,
--                             groups[].unreachable, markets_total.unreachable, the list's order and its rows' state) and
--                             cma.courtesy_page (the state filter takes unreachable; not_reached is CMA04)
--   cma.courtesy_unreachable_of(tenant, now)  0009a's cma.courtesy_not_reached_of under its new name, which is dropped
--   cma.refresh_follow_up_of  keeps courtesy_unreachable in the snapshot's summary; the snapshots already written have
--                             courtesy_not_reached renamed in place
--   cma.follow_up_summary()   its column courtesy_unreachable (dropped and created: the result type changes)
--   courtesy.alert_attempts   its description says Unreachable
--   cma_read.courtesy_order   unchanged; its state column says unreachable through cma.courtesy_orders_of
-- Not made again: cma.check_tenant_setting() (0009a's), whose comment still says "flagged Not reached"; it names no state.
-- SQLSTATEs as before: CMA04 for a state filter not known.
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
-- 1. The setting's description names the state
-- ---------------------------------------------------------------------------------------------
update cma.setting
   set description = 'The attempts since due after which a courtesy order without a conversation is flagged Unreachable, 1 to 20'
 where key = 'courtesy.alert_attempts';

-- ---------------------------------------------------------------------------------------------
-- 2. The courtesy orders, with the state Unreachable
-- ---------------------------------------------------------------------------------------------
-- The courtesy orders of a tenant created on the business dates [p_from, p_to) (each in its market's zone), as of p_now.
-- 0009c: the state an order is flagged in is unreachable (0009a's not_reached; the tag meaning not_reached is untouched)
-- p_from and p_to given: at most 92 days (cma.report_range); null: from courtesy.start_date, up to any date. None while
-- courtesy.start_date is empty. Calls are attributed to the contact as Attempts per deal attributes them (cma.deal_calls_of:
-- a CRM call of the contact's connection, not deleted, currently associated with the contact, its current call link, the
-- linked telephony call not deleted, with a start, on a counted line), up to p_now. Ids, codes, counts and times only
-- based on: 150_courtesy.sql
create or replace function cma.courtesy_orders_of(p_tenant_id uuid, p_from date, p_to date, p_now timestamptz default now())
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
                when att.attempts >= v_alert and not att.conversation then 'unreachable'
                else 'attempted' end
    from ord
    left join done d on d.order_id = ord.id
    left join att on att.order_id = ord.id
    left join cma.crm_contact kc
      on kc.tenant_id = p_tenant_id and kc.connection_id = ord.crm_connection_id and kc.source_id = ord.crm_contact_source_id
    order by ord.source_created_at, ord.id;
end
$$;
-- JIT off as the other large reads (132); custom plans always: after five calls on a connection a plpgsql statement turns to
-- its generic plan (CLAUDE.md, Performance), which at three times prod's volume took the page from 1.2 to 1.7 s
alter function cma.courtesy_orders_of(uuid, date, date, timestamptz) set jit = off;
alter function cma.courtesy_orders_of(uuid, date, date, timestamptz) set plan_cache_mode = force_custom_plan;

-- The courtesy orders Unreachable as of p_now, over every courtesy order since courtesy.start_date; null while it is empty.
-- (0009c: 0009a's cma.courtesy_not_reached_of under its new name; the old one is dropped below.) The follow-up snapshot keeps it, so Welcome's Needs attention reads it without a read of its own
-- based on: 150_courtesy.sql
create or replace function cma.courtesy_unreachable_of(p_tenant_id uuid, p_now timestamptz)
returns integer
language sql stable
as $$
  select case when cma.courtesy_start_of(p_tenant_id) is not null
              then (select count(*)::integer from cma.courtesy_orders_of(p_tenant_id, null, null, p_now) x where x.state = 'unreachable') end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The state filter's values
-- ---------------------------------------------------------------------------------------------
-- The state filter's values: every state, due (the three states of an order due without completion) and no_contact
-- based on: 150_courtesy.sql
create or replace function cma.courtesy_state_matches(p_state text, p_filter text)
returns boolean
language sql immutable
as $$
  select case when p_filter is null then true
              when p_filter = 'no_contact' then p_state is null
              when p_filter = 'due' then p_state in ('due_no_attempt', 'attempted', 'unreachable')
              else p_state = p_filter end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Customers → Courtesy in one read, with the calls of the period per market and the state Unreachable
-- ---------------------------------------------------------------------------------------------
-- The page of an explicit tenant as of p_now, as one JSON object. Two kinds of figure:
--   now     every courtesy order since courtesy.start_date as of p_now, narrowed by market and segment: the orders due
--           without completion, Unreachable, No contact and the states (the tiles), and the order list (also by state,
--           the first p_rows with the filtered total; Unreachable first, then due without an attempt, attempted, not due,
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
--                          contact, completed, Unreachable and No contact; the order cohorts per ISO week or month
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
-- A create or replace drops a function's settings (CLAUDE.md, Performance), so 0009a's two are set again: JIT off as the
-- other large reads (132), and custom plans always (the generic plan took the page from 1.2 to 1.7 s at three times prod's
-- volume)
alter function cma.courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz) set jit = off;
alter function cma.courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz) set plan_cache_mode = force_custom_plan;

-- ---------------------------------------------------------------------------------------------
-- 5. The page's entry: the state filter takes unreachable
-- ---------------------------------------------------------------------------------------------
-- Customers → Courtesy in one read (reports.view or performance.team, CMA06; a period of at most 92 days, cma.report_range).
-- p_period week or month (the order cohorts), p_group day, week or month (per market and period), p_market a market's code
-- or unknown, p_segment a segment code or unknown, p_state one of not_due, due_no_attempt, attempted, unreachable,
-- completed, due or no_contact; anything else CMA04. p_rows defaults to follow_up.list_rows and is held within 1 to 500.
-- Per person only for performance.team (null otherwise)
-- based on: 150_courtesy.sql
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
-- 6. The follow-up snapshot keeps courtesy_unreachable
-- ---------------------------------------------------------------------------------------------
-- As 0009a (150): the courtesy orders Unreachable kept as courtesy_unreachable (0009a's courtesy_not_reached) beside
-- courtesy_alert_attempts in the summary (both null while courtesy is not set up)
-- based on: 150_courtesy.sql
create or replace function cma.refresh_follow_up_of(p_tenant_id uuid, p_wait boolean default false)
returns jsonb
language plpgsql
as $$
declare
  v_t0      timestamptz := clock_timestamp();
  v_leads   integer;
  v_tickets integer;
  v_tasks   integer;
  v_ms      integer;
  v_summary jsonb;
  v_owners  jsonb;
  v_courtesy integer;
begin
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'the follow-up snapshot is refreshed for the current tenant only' using errcode = 'CMA06';
  end if;
  if coalesce(p_wait, false) then
    perform pg_advisory_xact_lock(cma.follow_up_lock_key(p_tenant_id));
    if exists (select 1 from cma.follow_up_snapshot s where s.tenant_id = p_tenant_id) then
      return jsonb_build_object('refreshed', false, 'reason', 'present');
    end if;
  elsif not pg_try_advisory_xact_lock(cma.follow_up_lock_key(p_tenant_id)) then
    return jsonb_build_object('refreshed', false, 'reason', 'running');
  end if;

  delete from cma.follow_up_item i where i.tenant_id = p_tenant_id;
  insert into cma.follow_up_item (tenant_id, kind, sort_key, item_id, market, owner_user_id, state, row)
  select p_tenant_id, 'lead', o.ordinality, o.deal_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id,
         case when o.past_target then 'past_target' when o.past_target is false then 'within_target' else 'no_hours' end,
         to_jsonb(o) - 'tenant_id' - 'ordinality'
  from cma.open_leads_of(p_tenant_id) with ordinality o;
  get diagnostics v_leads = row_count;
  insert into cma.follow_up_item (tenant_id, kind, sort_key, item_id, market, owner_user_id, state, row)
  select p_tenant_id, 'ticket', o.ordinality, o.ticket_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.sla_state,
         to_jsonb(o) - 'tenant_id' - 'ordinality'
  from cma.open_tickets_of(p_tenant_id) with ordinality o;
  get diagnostics v_tickets = row_count;
  insert into cma.follow_up_item (tenant_id, kind, sort_key, item_id, market, owner_user_id, state, row)
  select p_tenant_id, 'task', o.ordinality, o.task_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.due_state,
         to_jsonb(o) - 'tenant_id' - 'ordinality'
  from cma.open_tasks_of(p_tenant_id) with ordinality o;
  get diagnostics v_tasks = row_count;

  -- The counts and the figures per person from the items just written, as follow_up_summary_of and
  -- follow_up_by_owner_of compute them from the live sets (a person with only later tasks has a row of zeros)
  select jsonb_build_object(
           'leads_open_not_called', count(*) filter (where i.kind = 'lead'),
           'leads_past_target', count(*) filter (where i.kind = 'lead' and i.state = 'past_target'),
           'tickets_at_risk', count(*) filter (where i.kind = 'ticket' and i.state = 'at_risk'),
           'tickets_breached', count(*) filter (where i.kind = 'ticket' and i.state = 'breached'),
           'tickets_without_owner', count(*) filter (where i.kind = 'ticket' and i.row ->> 'owner_ref' is null),
           'tasks_overdue', count(*) filter (where i.kind = 'task' and i.state = 'overdue'),
           'tasks_due_today', count(*) filter (where i.kind = 'task' and i.state = 'today'),
           'tasks_unmapped_owner', count(*) filter (where i.kind = 'task' and i.row ->> 'owner_ref' is not null and i.owner_user_id is null))
    into v_summary
  from cma.follow_up_item i where i.tenant_id = p_tenant_id;
  -- the courtesy flag (0009a, renamed in 0009c): the courtesy orders Unreachable now and the attempts since due that flag one, both null while
  -- courtesy.start_date is unset, so Welcome's Needs attention reads them with the summary
  v_courtesy := cma.courtesy_unreachable_of(p_tenant_id, now());
  v_summary := v_summary || jsonb_build_object(
    'courtesy_unreachable', v_courtesy,
    'courtesy_alert_attempts', case when v_courtesy is not null then cma.setting_of(p_tenant_id, 'courtesy.alert_attempts')::integer end);
  select coalesce(jsonb_agg(jsonb_build_object(
           'owner_user_id', g.uid, 'open_leads', g.leads, 'leads_past_target', g.past, 'open_tickets', g.tickets,
           'tickets_at_risk_or_breached', g.risk, 'tasks_overdue', g.overdue, 'tasks_due_today', g.today) order by g.uid nulls last), '[]'::jsonb)
    into v_owners
  from (select i.owner_user_id as uid,
               count(*) filter (where i.kind = 'lead') as leads,
               count(*) filter (where i.kind = 'lead' and i.state = 'past_target') as past,
               count(*) filter (where i.kind = 'ticket') as tickets,
               count(*) filter (where i.kind = 'ticket' and i.state in ('at_risk', 'breached')) as risk,
               count(*) filter (where i.kind = 'task' and i.state = 'overdue') as overdue,
               count(*) filter (where i.kind = 'task' and i.state = 'today') as today
        from cma.follow_up_item i where i.tenant_id = p_tenant_id
        group by i.owner_user_id) g;

  v_ms := floor(extract(epoch from clock_timestamp() - v_t0) * 1000)::integer;
  insert into cma.follow_up_snapshot (tenant_id, computed_at, duration_ms, summary, by_owner)
  values (p_tenant_id, now(), v_ms, v_summary, v_owners)
  on conflict (tenant_id) do update
    set computed_at = excluded.computed_at, duration_ms = excluded.duration_ms, summary = excluded.summary, by_owner = excluded.by_owner;
  return jsonb_build_object('refreshed', true, 'leads', v_leads, 'tickets', v_tickets, 'tasks', v_tasks,
                            'rows', v_leads + v_tickets + v_tasks, 'duration_ms', v_ms, 'computed_at', now());
end
$$;

-- The counts, when they were computed, and the courtesy orders Unreachable with the attempts since due that flag one: the
-- column courtesy_unreachable (0009a's courtesy_not_reached) changes the result type, so the function is dropped and created again
drop function if exists cma.follow_up_summary();
-- based on: 150_courtesy.sql
create function cma.follow_up_summary()
returns table(tenant_id uuid, leads_open_not_called integer, leads_past_target integer, tickets_at_risk integer, tickets_breached integer,
              tickets_without_owner integer, tasks_overdue integer, tasks_due_today integer, tasks_unmapped_owner integer, computed_at timestamptz,
              courtesy_unreachable integer, courtesy_alert_attempts integer)
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  s        cma.follow_up_snapshot;
begin
  perform cma.assert_any_permission(array['monitoring.live', 'performance.team', 'workday.team']);
  s := cma.follow_up_snapshot_of(v_tenant);
  return query select v_tenant, (s.summary ->> 'leads_open_not_called')::integer, (s.summary ->> 'leads_past_target')::integer,
                      (s.summary ->> 'tickets_at_risk')::integer, (s.summary ->> 'tickets_breached')::integer,
                      (s.summary ->> 'tickets_without_owner')::integer, (s.summary ->> 'tasks_overdue')::integer,
                      (s.summary ->> 'tasks_due_today')::integer, (s.summary ->> 'tasks_unmapped_owner')::integer, s.computed_at,
                      (s.summary ->> 'courtesy_unreachable')::integer, (s.summary ->> 'courtesy_alert_attempts')::integer;
end
$$;

-- The snapshots already written keep their count under the new key until the next refresh (within a minute) rewrites them
update cma.follow_up_snapshot
   set summary = (summary - 'courtesy_not_reached') || jsonb_build_object('courtesy_unreachable', summary -> 'courtesy_not_reached')
 where summary ? 'courtesy_not_reached';

-- 0009a's name for the count goes: cma.courtesy_unreachable_of replaces it and nothing calls it any more
drop function if exists cma.courtesy_not_reached_of(uuid, timestamptz);

-- ---------------------------------------------------------------------------------------------
-- 7. Grants: the application only (a function made again keeps its grants; said again so the script stands alone)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.courtesy_orders_of(uuid,date,date,timestamptz)', 'cma.courtesy_unreachable_of(uuid,timestamptz)',
    'cma.courtesy_state_matches(text,text)',
    'cma.courtesy_page_of(uuid,date,date,text,text,text,text,text,integer,boolean,timestamptz)',
    'cma.courtesy_page(date,date,text,text,text,text,text,integer)',
    'cma.refresh_follow_up_of(uuid,boolean)', 'cma.follow_up_summary()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009c', 'Customers → Courtesy: the two bases unmistakable, and the state Unreachable. cma.courtesy_page_of (0009a''s definition, every other answer the same) adds per market the courtesy calls completed in the period (by call date, as the tile), each call once in the market of the earliest courtesy order it completed among the filtered orders, so the markets'' calls add up to the tile, and markets_total (orders, completed, calls, unreachable, no contact); the courtesy state not_reached is unreachable in cma.courtesy_orders_of, cma.courtesy_state_matches, cma.courtesy_page_of and cma.courtesy_page, cma.courtesy_not_reached_of is cma.courtesy_unreachable_of, and the follow-up snapshot''s summary and cma.follow_up_summary() say courtesy_unreachable; the tag meaning not_reached is untouched; the web labels the tile by call date and the order blocks by order date')
on conflict (version) do nothing;

commit;
reset role;
