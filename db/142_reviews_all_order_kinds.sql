-- =============================================================================================
-- 142_reviews_all_order_kinds.sql: addition 0008zw, Reviews' period All and Flash's Orders split by order kind
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 140_live_per_organisation.sql (0008zv). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your
-- own IAM login, away from minute 20 (the hourly snapshot job): dev first, then 143_verify_reviews_all_order_kinds.sql
-- there, then 105_verify_reviews.sql and 139_verify_flash_totals.sql again (their expected figures hold unchanged); then
-- prod in the same order, before the merge: the web of this change asks cma.reviews_page for the period All (p_from
-- null, grouped by month), which main's functions refuse (CMA04: Reviews would show the error page for All). The web of
-- main runs unchanged on it: its periods and groups answer as before, the reviews page only gains the keys from, to and
-- all, and the Orders card only gains a split main does not show. No table, view or column changes, and no setting:
-- seed 02 need not run again, and the data map's schema does not change.
--
-- Why (Martin, 5 November 2026; Decision log):
--   Reviews    a period All (nl Alles) on Reports → Reviews only: from the tenant's first counted review's business date
--              (the report's history start, over every market, so a market's months line up with the others') to the
--              period's end, grouped by month, with no previous period to compare with. It is exempt from the 92 days
--              every other report keeps (cma.report_range): a review is a low-volume record and its history is the
--              point of the page. Day and week stay the grouping of every other period; month is All's alone
--   Orders     Flash's Orders headline is split by order kind (cma.commerce_order.order_kind: first, renewal, repeat,
--              unknown), from the rows of the set [market, store, kind] summed over the stores: first, renewal and
--              repeat always (zeros included), unknown after them only where an order holds it; the parts add up to the
--              figure, per market too. Live (the card's headline) and as of a date (the snapshots' stored rows of that
--              set; none for a period whose snapshots hold none)
--
-- What it changes (functions only):
--   Reviews    cma.reviews_page_of(tenant, from, to, market, group, now): p_from null is All (from the tenant's first
--              counted review submitted by p_now, else p_to; no previous period: previous_from, previous_to null and
--              previous_partial false, the previous figures 0); the group month (every month's first day of the period,
--              empty ones too); the page answers its own from, to and all. cma.reviews_page(from, to, market, group):
--              from null is All, which runs to a date and is grouped by month, with no cap; a period keeps the 92 days
--              and day or week (month with a period is refused, CMA04)
--   Flash      cma.flash_split_dim_of: orders → kind; cma.flash_split_set_of (new): the set a headline's split reads
--              ([market, status], [market, store, kind]); cma.flash_split_order_of (new): the keys every split shows
--              first (the tenant's device-holding statuses; first, renewal, repeat); cma.flash_headline_split_of (new):
--              an overview's headline split from rows (cma.flash_split_of's rule over the set's rows: the order's keys
--              with 0 where no row holds one, then any other key a row holds above 0, by name); cma.flash_stored_split_of and
--              cma.flash_headline read the set through them. cma.flash_page is unchanged: it asks for a stored split
--              wherever cma.flash_split_dim_of names a dim, which now includes the orders. Subscriptions' split is the
--              same as 0008zu's, value for value (143 compares it with cma.flash_split_of). The orders' definition
--              version stays 0008zn: the figure does not change, only its split is shown
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
  if not exists (select 1 from cma.schema_migration where version = '0008zv') then
    raise exception 'addition 0008zv (140_live_per_organisation.sql) must run before 0008zw';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Reviews: the period All and the group month
-- ---------------------------------------------------------------------------------------------
-- As 0008ze (104), with the period All (p_from null: from the tenant's first counted review submitted by p_now, over
-- every market, else p_to; no previous period) and the group month. The period's from and to and whether it is All are
-- part of the answer, so the page shows the period it was given
create or replace function cma.reviews_page_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_group text, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone       text;
  v_all        boolean := p_from is null;
  v_from       date;
  v_prev       record;
  v_prev_from  date;
  v_prev_to    date;
  v_prev_until timestamptz;
  v_until      time;
begin
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  if v_all then
    -- the report's history start over every market (the first counted review by p_now), never after the period's end
    select min(x.business_date) into v_from from cma.reviews_of(p_tenant_id) x where x.submitted_at <= p_now;
    v_from := least(coalesce(v_from, p_to), p_to);
  else
    v_from := p_from;
    select * into v_prev from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now);
    v_prev_from := v_prev.prev_from;
    v_prev_to := v_prev.prev_to;
    v_prev_until := v_prev.until;
    v_until := (v_prev.until at time zone v_zone)::time;
  end if;
  return (
    with a as materialized (
      select x.*,
             cma.in_period(x.business_date, x.local_time, v_from, p_to, null) as cur,
             case when v_all then false else cma.in_period(x.business_date, x.local_time, v_prev_from, v_prev_to, v_until) end as pre,
             case p_group when 'day' then x.business_date when 'month' then date_trunc('month', x.business_date)::date else x.week_start end as group_key
      from cma.reviews_of(p_tenant_id) x
      where (p_market is null or x.market = p_market) and x.submitted_at <= p_now
    ), r as materialized (
      select * from a where cur or pre
    )
    select jsonb_build_object(
      'from', v_from, 'to', p_to, 'all', v_all,
      'figures', (select cma.review_figures(count(*) filter (where cur), avg(rating) filter (where cur), count(*) filter (where cur and is_negative),
                                            count(*) filter (where cur and link_level = 'order'), count(*) filter (where cur and link_level = 'contact'),
                                            count(*) filter (where cur and link_level = 'none')) from r),
      'previous', (select cma.review_figures(count(*) filter (where pre), avg(rating) filter (where pre), count(*) filter (where pre and is_negative),
                                             count(*) filter (where pre and link_level = 'order'), count(*) filter (where pre and link_level = 'contact'),
                                             count(*) filter (where pre and link_level = 'none')) from r),
      'previous_from', v_prev_from, 'previous_to', v_prev_to, 'previous_partial', v_prev_until is not null,
      'distribution', (select jsonb_agg(jsonb_build_object('stars', s, 'reviews', coalesce(d.reviews, 0), 'previous', coalesce(d.previous, 0)) order by s)
                       from generate_series(1, 5) s
                       left join (select stars, count(*) filter (where cur) as reviews, count(*) filter (where pre) as previous
                                  from r group by stars) d on d.stars = s),
      'groups', (select jsonb_agg(jsonb_build_object('key', g.key)
                                  || cma.review_figures(d.reviews, d.average, d.negative, d.linked_order, d.linked_contact, d.unlinked)
                                  order by g.key)
                 from (select k::date as key
                       from generate_series(case p_group when 'day' then v_from when 'month' then date_trunc('month', v_from)::date
                                                 else date_trunc('week', v_from)::date end, p_to,
                                            case p_group when 'day' then interval '1 day' when 'month' then interval '1 month'
                                                 else interval '7 days' end) k) g
                 left join (select group_key, count(*) as reviews, avg(rating) as average, count(*) filter (where is_negative) as negative,
                                   count(*) filter (where link_level = 'order') as linked_order,
                                   count(*) filter (where link_level = 'contact') as linked_contact,
                                   count(*) filter (where link_level = 'none') as unlinked
                            from r where cur group by group_key) d on d.group_key = g.key),
      'markets', (select coalesce(jsonb_agg(jsonb_build_object('market', m.market, 'name', mk.name, 'current', m.c, 'previous', m.p)
                                            order by (m.market = 'unknown'), mk.sort_order, m.market), '[]'::jsonb)
                  from (select market,
                               cma.review_figures(count(*) filter (where cur), avg(rating) filter (where cur), count(*) filter (where cur and is_negative),
                                                  count(*) filter (where cur and link_level = 'order'), count(*) filter (where cur and link_level = 'contact'),
                                                  count(*) filter (where cur and link_level = 'none')) as c,
                               cma.review_figures(count(*) filter (where pre), avg(rating) filter (where pre), count(*) filter (where pre and is_negative),
                                                  count(*) filter (where pre and link_level = 'order'), count(*) filter (where pre and link_level = 'contact'),
                                                  count(*) filter (where pre and link_level = 'none')) as p
                        from r group by market) m
                  left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = m.market),
      'channels', (select coalesce(jsonb_agg(jsonb_build_object('channel', c.channel_source_id, 'name', c.channel_name, 'market', c.market,
                                                                'current', c.c, 'previous', c.p)
                                             order by c.channel_name, c.channel_source_id), '[]'::jsonb)
                   from (select channel_source_id, channel_name, market,
                                cma.review_figures(count(*) filter (where cur), avg(rating) filter (where cur), count(*) filter (where cur and is_negative),
                                                   count(*) filter (where cur and link_level = 'order'), count(*) filter (where cur and link_level = 'contact'),
                                                   count(*) filter (where cur and link_level = 'none')) as c,
                                cma.review_figures(count(*) filter (where pre), avg(rating) filter (where pre), count(*) filter (where pre and is_negative),
                                                   count(*) filter (where pre and link_level = 'order'), count(*) filter (where pre and link_level = 'contact'),
                                                   count(*) filter (where pre and link_level = 'none')) as p
                         from r group by channel_source_id, channel_name, market) c),
      'link_levels', (select jsonb_agg(jsonb_build_object('level', l, 'reviews', coalesce(d.reviews, 0), 'previous', coalesce(d.previous, 0)) order by o)
                      from unnest(array['order', 'contact', 'none']) with ordinality u(l, o)
                      left join (select link_level, count(*) filter (where cur) as reviews, count(*) filter (where pre) as previous
                                 from r group by link_level) d on d.link_level = u.l),
      'invite_events', (select coalesce(jsonb_agg(jsonb_build_object('event_type', e.invite_event_type, 'reviews', e.reviews, 'previous', e.previous)
                                                  order by e.reviews desc, e.invite_event_type nulls last), '[]'::jsonb)
                        from (select invite_event_type, count(*) filter (where cur) as reviews, count(*) filter (where pre) as previous
                              from r group by invite_event_type) e),
      'market_states', (select coalesce(jsonb_agg(jsonb_build_object('market', s.market, 'name', s.name, 'state', s.state,
                                                                     'channels', s.channels, 'reviews', s.reviews)), '[]'::jsonb)
                        from cma.review_market_states_of(p_tenant_id) s),
      'history_start', (select min(business_date) from a),
      'negative_max_rating', cma.setting_of(p_tenant_id, 'reviews.negative_max_rating')::integer,
      'is_set_up', cma.reviews_set_up_of(p_tenant_id),
      'filter_markets', (select coalesce(jsonb_agg(f.market order by (f.market = 'unknown'), f.sort_order, f.market), '[]'::jsonb)
                         from (select distinct coalesce(ch.market, 'unknown') as market, coalesce(mk.sort_order, 2147483647) as sort_order
                               from cma.review_channel ch
                               left join cma.market mk on mk.tenant_id = ch.tenant_id and mk.code = ch.market
                               where ch.tenant_id = p_tenant_id and ch.is_counted) f))
  );
end
$$;

-- Reports, Reviews in one read (reports.view or performance.team; a market's code or unknown). A period (p_from and p_to)
-- covers at most 92 days and is grouped by day or week; All (p_from null, 0008zw) runs from the tenant's first counted
-- review to p_to, is grouped by month and has no cap. Team figures only: no figure per person exists
create or replace function cma.reviews_page(p_from date, p_to date, p_market text default null, p_group text default 'week')
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_from is null then
    -- All (0008zw): exempt from the 92 days every other report keeps
    if p_to is null then
      raise exception 'the period All runs to a date' using errcode = 'CMA04';
    end if;
  else
    perform cma.report_range(v_tenant, p_from, p_to);
  end if;
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'a market filter is a two-letter code or unknown' using errcode = 'CMA04';
  end if;
  if p_from is null and p_group is distinct from 'month' then
    raise exception 'the period All is grouped by month' using errcode = 'CMA04';
  end if;
  if p_from is not null and (p_group is null or p_group not in ('day', 'week')) then
    raise exception 'group by day or week' using errcode = 'CMA04';
  end if;
  return cma.reviews_page_of(v_tenant, p_from, p_to, p_market, p_group, now());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Flash: the Orders headline split by order kind
-- ---------------------------------------------------------------------------------------------
-- The dim a headline is split by: the subscriptions' Total subscriptions per device-holding status (0008zu), the orders
-- per order kind (0008zw); none for another overview
create or replace function cma.flash_split_dim_of(p_overview text)
returns text
language sql immutable
as $$
  select case when p_overview = 'subscriptions' then 'status' when p_overview = 'orders' then 'kind' end
$$;

-- The grouping set whose rows a headline's split reads: [market, status] for the subscriptions, [market, store, kind]
-- for the orders (summed over the stores); none for another overview
create or replace function cma.flash_split_set_of(p_overview text)
returns text[]
language sql immutable
as $$
  select case when p_overview = 'subscriptions' then array['market', 'status']
              when p_overview = 'orders' then array['market', 'store', 'kind'] end
$$;

-- The keys a headline's split shows first, in order, 0 where no row holds one: the tenant's device-holding statuses in the
-- setting's order (the subscriptions); the order kinds first, renewal and repeat (the orders: cma.commerce_order's
-- order_kind, whose fourth value unknown follows only where an order holds it); none for another overview
create or replace function cma.flash_split_order_of(p_tenant_id uuid, p_overview text)
returns text[]
language sql stable
as $$
  select case when p_overview = 'subscriptions' then cma.flash_holding_statuses_of(p_tenant_id)
              when p_overview = 'orders' then array['first', 'renewal', 'repeat'] end
$$;

-- An overview's headline split from the rows given (0008zu's cma.flash_split_of over the split set's rows): of the rows
-- whose dims are exactly the set, the market's or summed over every market (and over the stores), as [{key, value}]:
-- every key of cma.flash_split_order_of with 0 where no row holds it, then any other key a row holds with a figure above
-- 0, by name (the orders' unknown; a row of a set always counts one at least, so 0008zu's split is unchanged). Null for
-- an overview without a split
create or replace function cma.flash_headline_split_of(p_tenant_id uuid, p_overview text, p_rows jsonb, p_market text)
returns jsonb
language sql stable
as $$
  with s as (
    select cma.flash_split_set_of(p_overview) as dims, cma.flash_split_dim_of(p_overview) as dim, o.headline as measure,
           coalesce(cma.flash_split_order_of(p_tenant_id, p_overview), '{}'::text[]) as ord
    from cma.flash_overviews() o
    where o.key = p_overview and cma.flash_split_set_of(p_overview) is not null
  ), f as (
    select r -> 'dims' ->> s.dim as k, sum((r -> 'measures' ->> s.measure)::numeric) as v
    from s cross join jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
    where r -> 'dims' ?& s.dims and (select count(*) from jsonb_object_keys(r -> 'dims')) = cardinality(s.dims)
      and (p_market is null or r -> 'dims' ->> 'market' = p_market)
      and jsonb_typeof(r -> 'measures' -> s.measure) = 'number'
    group by 1
  ), k as (
    select x as k from s cross join unnest(s.ord) x
    union
    select f.k from f where f.v > 0
  )
  select case when exists (select 1 from s)
              then (select coalesce(jsonb_agg(jsonb_build_object('key', k.k, 'value', coalesce(f.v, 0))
                                              order by array_position((select s.ord from s), k.k) nulls last, k.k), '[]'::jsonb)
                    from k left join f on f.k = k.k) end
$$;

-- As 0008zu (138), over the split set's rows (the orders' [market, store, kind] too): a stored headline's split over a set
-- of snapshot dates (a stock overview's one date, a flow's period), the market's or summed over every market; null when
-- they hold none (a snapshot taken before the split was stored, or no row of the set those days)
create or replace function cma.flash_stored_split_of(p_tenant_id uuid, p_overview text, p_market text, p_dates date[])
returns jsonb
language sql stable
as $$
  with r as (
    select jsonb_agg(jsonb_build_object('dims', s.dims, 'measures', s.measures)) as rows
    from cma.flash_snapshot s
    where s.tenant_id = p_tenant_id and s.overview = p_overview and s.snapshot_date = any (coalesce(p_dates, '{}'::date[]))
      and cma.flash_split_set_of(p_overview) is not null and s.dims ?& cma.flash_split_set_of(p_overview)
      and (select count(*) from jsonb_object_keys(s.dims)) = cardinality(cma.flash_split_set_of(p_overview))
  )
  select case when r.rows is not null then cma.flash_headline_split_of(p_tenant_id, p_overview, r.rows, p_market) end
  from r
$$;

-- As 0008zu (138), with the split set's rows (the orders' [market, store, kind] too) and cma.flash_headline_split_of. One
-- overview's live headline (reports.view or performance.team): the totals' (or the market's) headline figure of
-- cma.flash_compute_of, now or over a period for a flow, its split and its definition; null when its source is not set up
create or replace function cma.flash_headline(p_overview text, p_market text default null, p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable
set jit = off
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_today  date;
  o        record;
  v_rows   jsonb;
  -- the set whose rows the headline's split reads (Total subscriptions per device-holding status, 0008zu; the orders
  -- per order kind, 0008zw), none for another overview
  v_set    text[] := cma.flash_split_set_of(p_overview);
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_flash_overview(p_overview);
  v_today := cma.tenant_today_of(v_tenant);
  perform cma.assert_flash_params(p_market, null, p_from, p_to, v_today);
  select * into o from cma.flash_overviews() x where x.key = p_overview;
  select jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures)) into v_rows
  from cma.flash_compute_of(v_tenant, p_overview, case when o.kind = 'flow' then coalesce(p_from, v_today) end,
                            case when o.kind = 'flow' then coalesce(p_to, v_today) end) c
  where c.dims = '{}'::jsonb or c.dims = jsonb_build_object('market', p_market)
     or (v_set is not null and c.dims ?& v_set and (select count(*) from jsonb_object_keys(c.dims)) = cardinality(v_set)
         and (p_market is null or c.dims ->> 'market' = p_market));
  return jsonb_build_object('overview', p_overview, 'headline', o.headline, 'market', p_market, 'as_of', now(),
    'from', case when o.kind = 'flow' then coalesce(p_from, v_today) end, 'to', case when o.kind = 'flow' then coalesce(p_to, v_today) end,
    'set_up', v_rows is not null,
    'value', coalesce(cma.flash_pick_of(v_rows, p_market, o.headline),
                      case when cma.flash_pick_of(v_rows, null, o.headline) is not null then '0'::jsonb end),
    'split', case when v_set is not null and v_rows is not null then cma.flash_headline_split_of(v_tenant, p_overview, v_rows, p_market) end,
    'definition_version', cma.flash_definition_version(p_overview));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Grants: the application only (a function made again keeps its grants; the new ones get theirs here)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.reviews_page_of(uuid,date,date,text,text,timestamptz)', 'cma.reviews_page(date,date,text,text)',
    'cma.flash_split_dim_of(text)', 'cma.flash_split_set_of(text)', 'cma.flash_split_order_of(uuid,text)',
    'cma.flash_headline_split_of(uuid,text,jsonb,text)', 'cma.flash_stored_split_of(uuid,text,text,date[])',
    'cma.flash_headline(text,text,date,date)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zw', 'Reviews'' period All and Flash''s Orders split by order kind: cma.reviews_page takes All (p_from null: from the tenant''s first counted review to p_to, grouped by month, no previous period, exempt from the 92 days every other report keeps; a period keeps 92 days and day or week) and answers its from, to and all; Flash''s Orders headline split per order kind from the set [market, store, kind] summed over the stores (first, renewal, repeat with zeros, unknown only where an order holds it), live and as of a date (cma.flash_split_set_of, cma.flash_split_order_of, cma.flash_headline_split_of; cma.flash_split_dim_of, cma.flash_stored_split_of and cma.flash_headline made again); the Assets rail group and its Installed base page are web only')
on conflict (version) do nothing;

commit;
reset role;
