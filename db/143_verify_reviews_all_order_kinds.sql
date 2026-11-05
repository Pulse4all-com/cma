-- =============================================================================================
-- 143_verify_reviews_all_order_kinds.sql: verifies addition 0008zw, Reviews' period All and Flash's Orders split by
-- order kind
-- =============================================================================================
-- Blocks S check the addition and its functions (universal). Block A works on two throwaway tenants inside a
-- subtransaction that is always rolled back, so nothing stays; block D reads every active tenant's own data and writes
-- nothing. The script runs alike in dev and in prod. Every check writes one row, ok or FAIL, and the last row is the
-- verdict, because Cloud SQL Studio shows no notices: "0008zw verified | 143_verify_reviews_all_order_kinds: 13 ok, 0
-- FAIL, 0 skip" (a D check reads skip for a database without an active tenant). Run as your own IAM login after
-- 142_reviews_all_order_kinds.sql, dev first, then prod; then 105_verify_reviews.sql and 139_verify_flash_totals.sql
-- again.
--   S1  the addition 0008zw is recorded after 0008zv
--   S2  privileges: every new and remade function the application's only, in the caller's rights, nothing for the
--       readers; cma.flash_headline keeps JIT off
--   S3  the split catalog: Total subscriptions per status by [market, status] in the tenant's holding statuses' order;
--       the orders per kind by [market, store, kind] in the order first, renewal, repeat; no other overview split; the
--       orders' definition still 0008zn
--   A1  the split's helper on given rows (throwaway tenant one): the orders summed over the stores, the three kinds with
--       zeros, unknown after them only where a row holds it, one market or every market, other sets never counted; the
--       subscriptions' split equal to 0008zu's cma.flash_split_of on 139's rows, for every market and all
--   A2  Reviews' All (tenant one, as of a fixed instant): from the first counted review (2025-12-10) to the end, every
--       month's first day from December 2025 to October 2026, the counts the sum of every counted review (a review not
--       published, of a channel not counted or submitted after the instant left out), the groups adding up, no previous
--       period (previous_from and previous_to null, not partial, the previous figures 0)
--   A3  All with a market: the same period (the tenant's first review, every market's), the market's reviews only, the
--       market's own history start; a tenant without reviews: from = to, one month, zeros
--   A4  a period answers as 0008ze's definition (kept below as pg_temp.v0008zw_reviews_0008ze), key for key: four periods
--       (a day that is today and so cut, two weeks by day, a month by week, 92 days by week) by every market, unknown
--       and all; its from and to the period's, all false
--   A5  cma.reviews_page's parameters, as the application: All grouped by month to today (or the day after, for a reader
--       ahead of the tenant's zone) passes; All by week or without a group, All without an end or ending two days after
--       today or in 9999, a period by month, a period of 200 days and a bad market are refused (CMA04); without a report
--       permission the read is refused (CMA06)
--   A6  the orders' live headline (tenant one's three stores, as its reader): the split per kind summed over the GB
--       stores, unknown shown only where an order has that kind, a test order left out; the parts add up to the figure
--       in all and per market; a market without orders all zeros
--   A7  the orders' split as of a date (cma.flash_page and cma.flash_stored_split_of): the stored rows of [market, store,
--       kind] over the period's snapshot dates, per market; none for a date whose snapshot holds no row of the set
--   D1  every active tenant: the subscriptions' live split equal to 0008zu's, in all and per market
--   D2  every active tenant: the orders' split over the previous month adding up to the figure in all and per market,
--       the three kinds always, unknown only above 0, no other key
--   D3  every active tenant: All equal to the count of every counted review submitted by now, its monthly groups adding
--       up, from its first month to the current one, no previous period; and the last 92 days by week as 0008ze's
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED, NOT A PASS.
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

drop table if exists pg_temp.verify_0008zw;
create temp table verify_0008zw (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zw_code(p_sql text)
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

-- A split ([{key, value}]) as one line: "key value" pairs in order; none when there is no split (SQL or JSON null)
create or replace function pg_temp.v0008zw_split(p_split jsonb)
returns text
language sql
as $$
  select coalesce(string_agg((x ->> 'key') || ' ' || (x ->> 'value'), ', ' order by o),
                  case when p_split is null or jsonb_typeof(p_split) = 'null' then 'none' else '' end)
  from jsonb_array_elements(case when jsonb_typeof(p_split) = 'array' then p_split else '[]'::jsonb end) with ordinality u(x, o)
$$;

-- Where a split does not add up to its headline, or carries a key it should not: the orders' rows (live or stored) in
-- all and per market; empty when every one holds
create or replace function pg_temp.v0008zw_orders_unbalanced(p_tenant uuid, p_rows jsonb)
returns text
language sql
as $$
  with m as (
    select null::text as market
    union all
    select distinct r -> 'dims' ->> 'market' from jsonb_array_elements(p_rows) r where r -> 'dims' = jsonb_build_object('market', r -> 'dims' ->> 'market')
  ), c as (
    select m.market,
           coalesce((select (r -> 'measures' ->> 'orders')::numeric from jsonb_array_elements(p_rows) r
                     where r -> 'dims' = case when m.market is null then '{}'::jsonb else jsonb_build_object('market', m.market) end), 0) as figure,
           cma.flash_headline_split_of(p_tenant, 'orders', p_rows, m.market) as split
    from m
  )
  select coalesce(string_agg(coalesce(c.market, 'all') || ' ' || c.figure || ' ' || pg_temp.v0008zw_split(c.split), '; '), '')
  from c
  where c.figure <> coalesce((select sum((x ->> 'value')::numeric) from jsonb_array_elements(c.split) x), -1)
     or (select array_agg(x ->> 'key' order by o) from jsonb_array_elements(c.split) with ordinality u(x, o) where o <= 3)
        is distinct from array['first', 'renewal', 'repeat']
     or exists (select 1 from jsonb_array_elements(c.split) with ordinality u(x, o)
                where o > 3 and (x ->> 'key' <> 'unknown' or (x ->> 'value')::numeric <= 0))
$$;

-- A page without the keys 0008zw adds (from, to, all), for the comparison with 0008ze's
create or replace function pg_temp.v0008zw_strip(p jsonb)
returns jsonb
language sql
as $$
  select p - 'from' - 'to' - 'all'
$$;

-- 0008ze's cma.reviews_page_of (104), kept verbatim for the comparison of a period (A4, D3)
create or replace function pg_temp.v0008zw_reviews_0008ze(p_tenant_id uuid, p_from date, p_to date, p_market text, p_group text, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone  text;
  v_prev  record;
  v_until time;
begin
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  select * into v_prev from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now);
  v_until := (v_prev.until at time zone v_zone)::time;
  return (
    with a as materialized (
      select x.*,
             cma.in_period(x.business_date, x.local_time, p_from, p_to, null) as cur,
             cma.in_period(x.business_date, x.local_time, v_prev.prev_from, v_prev.prev_to, v_until) as pre,
             case when p_group = 'day' then x.business_date else x.week_start end as group_key
      from cma.reviews_of(p_tenant_id) x
      where (p_market is null or x.market = p_market) and x.submitted_at <= p_now
    ), r as materialized (
      select * from a where cur or pre
    )
    select jsonb_build_object(
      'figures', (select cma.review_figures(count(*) filter (where cur), avg(rating) filter (where cur), count(*) filter (where cur and is_negative),
                                            count(*) filter (where cur and link_level = 'order'), count(*) filter (where cur and link_level = 'contact'),
                                            count(*) filter (where cur and link_level = 'none')) from r),
      'previous', (select cma.review_figures(count(*) filter (where pre), avg(rating) filter (where pre), count(*) filter (where pre and is_negative),
                                             count(*) filter (where pre and link_level = 'order'), count(*) filter (where pre and link_level = 'contact'),
                                             count(*) filter (where pre and link_level = 'none')) from r),
      'previous_from', v_prev.prev_from, 'previous_to', v_prev.prev_to, 'previous_partial', v_prev.until is not null,
      'distribution', (select jsonb_agg(jsonb_build_object('stars', s, 'reviews', coalesce(d.reviews, 0), 'previous', coalesce(d.previous, 0)) order by s)
                       from generate_series(1, 5) s
                       left join (select stars, count(*) filter (where cur) as reviews, count(*) filter (where pre) as previous
                                  from r group by stars) d on d.stars = s),
      'groups', (select jsonb_agg(jsonb_build_object('key', g.key)
                                  || cma.review_figures(d.reviews, d.average, d.negative, d.linked_order, d.linked_contact, d.unlinked)
                                  order by g.key)
                 from (select k::date as key
                       from generate_series(case when p_group = 'day' then p_from else date_trunc('week', p_from)::date end, p_to,
                                            case when p_group = 'day' then interval '1 day' else interval '7 days' end) k) g
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

-- S1. The addition
do $$
begin
  insert into verify_0008zw values (1, 'S1 addition 0008zw recorded, after 0008zv',
    case when exists (select 1 from cma.schema_migration where version = '0008zw')
              and exists (select 1 from cma.schema_migration where version = '0008zv')
              and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end,
    case when current_setting('verify.provoke')::boolean then 'provoked' else '' end);
end
$$;

-- S2. Privileges: the application's only, the caller's rights, nothing for the readers; JIT off on the headline
do $$
declare
  v_bad text := '';
  v_fn  text;
begin
  foreach v_fn in array array[
    'cma.reviews_page_of(uuid,date,date,text,text,timestamptz)', 'cma.reviews_page(date,date,text,text)',
    'cma.flash_split_dim_of(text)', 'cma.flash_split_set_of(text)', 'cma.flash_split_order_of(uuid,text)',
    'cma.flash_headline_split_of(uuid,text,jsonb,text)', 'cma.flash_stored_split_of(uuid,text,text,date[])',
    'cma.flash_headline(text,text,date,date)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  if not coalesce((select 'jit=off' = any (proconfig) from pg_proc where oid = to_regprocedure('cma.flash_headline(text,text,date,date)')), false) then
    v_bad := v_bad || 'cma.flash_headline jit; ';
  end if;
  insert into verify_0008zw values (2, 'S2 privileges: the application''s only, the caller''s rights, nothing for the readers; JIT off on the headline',
    case when v_bad = '' and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end, v_bad);
end
$$;

-- S3. The split catalog
do $$
declare
  v_txt text;
begin
  select string_agg(o.key || ':' || coalesce(cma.flash_split_dim_of(o.key), '-') || ':' || coalesce(array_to_string(cma.flash_split_set_of(o.key), '/'), '-'),
                    ',' order by o.sort_order)
         || ' ' || array_to_string(cma.flash_split_order_of(null, 'orders'), '/') || ' ' || coalesce(array_to_string(cma.flash_split_order_of(null, 'reviews'), '/'), 'none')
         || ' ' || cma.flash_definition_version('orders')
    into v_txt
  from cma.flash_overviews() o;
  insert into verify_0008zw values (3, 'S3 the split catalog: subscriptions per status by [market, status], orders per kind by [market, store, kind] (first, renewal, repeat), no other; orders still 0008zn',
    case when v_txt = 'customers:-:-,subscriptions:status:market/status,installed_base:-:-,churn:-:-,orders:kind:market/store/kind,payments:-:-,'
                      || 'open_deals:-:-,open_tickets:-:-,open_tasks:-:-,reviews:-:-,data_quality:-:- first/renewal/repeat none 0008zn'
              and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end, v_txt);
end
$$;

-- A. Behaviour on two throwaway tenants, always rolled back
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_t2 uuid; v_reader uuid; v_agent uuid; v_role uuid;
  v_rev uuid; v_ch_gb uuid; v_ch_nl uuid; v_ch_x uuid; v_ch_off uuid;
  v_gb1 uuid; v_gb2 uuid; v_nl uuid; v_run uuid;
  v_now    timestamptz := '2026-10-14 10:00:00+00';   -- 12:00 in Amsterdam
  v_today  date;
  j jsonb; v_split jsonb; v_rows_json jsonb;
  v_txt text; v_bad text; v_exp text;
  p record; m text;
begin
  begin
    -- tenants, people and markets (as the owner); each tenant's Scheduler user comes with create_tenant
    v_t1 := cma.create_tenant('verify-0008zw-one', 'Verify 0008zw one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zw-two', 'Verify 0008zw two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader-0008zw@example.invalid', 'reader') returning id into v_reader;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent-0008zw@example.invalid', 'agent') returning id into v_agent;
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id) values (v_t1, v_reader, v_role);
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t1, v_agent, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'agent';
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
      (v_t1, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10), (v_t1, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 20),
      (v_t1, 'DE', 'Germany', 'Europe/Berlin', 'de', 'EUR', 30);

    -- A1. the split's helper on given rows
    v_rows_json := '[{"dims": {}, "measures": {"orders": 9}}, {"dims": {"market": "GB"}, "measures": {"orders": 6}},
      {"dims": {"market": "GB", "store": "gb-1", "kind": "first"}, "measures": {"orders": 2}},
      {"dims": {"market": "GB", "store": "gb-2", "kind": "first"}, "measures": {"orders": 1}},
      {"dims": {"market": "GB", "store": "gb-1", "kind": "renewal"}, "measures": {"orders": 2}},
      {"dims": {"market": "GB", "store": "gb-2", "kind": "repeat"}, "measures": {"orders": 1}},
      {"dims": {"market": "NL", "store": "nl-1", "kind": "first"}, "measures": {"orders": 1}},
      {"dims": {"market": "NL", "store": "nl-1", "kind": "unknown"}, "measures": {"orders": 2}},
      {"dims": {"market": "GB", "sku": "A"}, "measures": {"orders": 50}},
      {"dims": {"market": "GB", "kind": "first"}, "measures": {"orders": 60}},
      {"dims": {"market": "GB", "store": "gb-1", "kind": "first", "status": "PAID"}, "measures": {"orders": 70}}]';
    v_txt := pg_temp.v0008zw_split(cma.flash_headline_split_of(v_t1, 'orders', v_rows_json, null))
             || ' | ' || pg_temp.v0008zw_split(cma.flash_headline_split_of(v_t1, 'orders', v_rows_json, 'GB'))
             || ' | ' || pg_temp.v0008zw_split(cma.flash_headline_split_of(v_t1, 'orders', v_rows_json, 'FR'))
             || ' | ' || pg_temp.v0008zw_split(cma.flash_headline_split_of(v_t1, 'orders', '[]', null))
             || ' | ' || pg_temp.v0008zw_split(cma.flash_headline_split_of(v_t1, 'customers', v_rows_json, null));
    -- the subscriptions on 139's rows: the new helper against 0008zu's, for all and each market
    v_rows_json := '[{"dims": {}, "measures": {"holding_subscriptions": 9}}, {"dims": {"market": "GB"}, "measures": {"holding_subscriptions": 7}},
      {"dims": {"market": "GB", "status": "active"}, "measures": {"holding_subscriptions": 3}}, {"dims": {"market": "GB", "status": "failed"}, "measures": {"holding_subscriptions": 1}},
      {"dims": {"market": "NL", "status": "active"}, "measures": {"holding_subscriptions": 2}}, {"dims": {"market": "NL", "status": "zz-other"}, "measures": {"holding_subscriptions": 1}},
      {"dims": {"market": "GB", "store": "x", "status": "active", "payment_state": "paid"}, "measures": {"holding_subscriptions": 50}}]';
    v_bad := '';
    foreach m in array array['*', 'GB', 'NL', 'FR'] loop
      if cma.flash_headline_split_of(v_t1, 'subscriptions', v_rows_json, nullif(m, '*'))
         is distinct from cma.flash_split_of(v_rows_json, nullif(m, '*'), 'status', 'holding_subscriptions', cma.flash_holding_statuses_of(v_t1)) then
        v_bad := v_bad || m || ' ';
      end if;
    end loop;
    v_exp := 'first 4, renewal 2, repeat 1, unknown 2 | first 3, renewal 2, repeat 1 | first 0, renewal 0, repeat 0 | first 0, renewal 0, repeat 0 | none';
    v_rows := v_rows || array['11', 'A1 the split''s helper: the orders summed over the stores, zeros, unknown only where held, one market or all, other sets never counted; the subscriptions as 0008zu''s',
      case when v_txt = v_exp and v_bad = '' and not v_provoke then 'ok' else 'FAIL' end,
      v_txt || case when v_bad <> '' then ' | subscriptions differ: ' || v_bad else '' end];

    -- the reviews fixture of tenant one: GB and NL counted, one counted without a market (unknown), one not counted
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyreviews', 'Verify reviews', 'reviews-0008zw', 'reviews') returning id into v_rev;
    insert into cma.review_channel (tenant_id, connection_id, source_id, name, market, is_counted) values (v_t1, v_rev, 'ch-gb', 'Shop GB', 'GB', true) returning id into v_ch_gb;
    insert into cma.review_channel (tenant_id, connection_id, source_id, name, market, is_counted) values (v_t1, v_rev, 'ch-nl', 'Shop NL', 'NL', true) returning id into v_ch_nl;
    insert into cma.review_channel (tenant_id, connection_id, source_id, name, market, is_counted) values (v_t1, v_rev, 'ch-x', 'Shop X', null, true) returning id into v_ch_x;
    insert into cma.review_channel (tenant_id, connection_id, source_id, name, market, is_counted) values (v_t1, v_rev, 'ch-off', 'Shop off', 'GB', false) returning id into v_ch_off;
    insert into cma.review (tenant_id, connection_id, review_channel_id, source_system, source_id, review_type, state, is_published, rating, submitted_at, link_level)
    values (v_t1, v_rev, v_ch_off, 'verifyreviews', 'rv-0', 'SERVICE_REVIEW', 'APPROVED', true, 3, '2025-11-01 10:00 Europe/Amsterdam', 'none'),
           (v_t1, v_rev, v_ch_gb, 'verifyreviews', 'rv-1', 'SERVICE_REVIEW', 'APPROVED', true, 5, '2025-12-10 10:00 Europe/Amsterdam', 'none'),
           (v_t1, v_rev, v_ch_nl, 'verifyreviews', 'rv-2', 'SERVICE_REVIEW', 'APPROVED', true, 1, '2026-01-20 10:00 Europe/Amsterdam', 'none'),
           (v_t1, v_rev, v_ch_gb, 'verifyreviews', 'rv-3', 'SERVICE_REVIEW', 'APPROVED', true, 4, '2026-03-05 10:00 Europe/Amsterdam', 'none'),
           (v_t1, v_rev, v_ch_gb, 'verifyreviews', 'rv-4', 'SERVICE_REVIEW', 'MODERATION', false, 2, '2026-03-25 10:00 Europe/Amsterdam', 'none'),
           (v_t1, v_rev, v_ch_x, 'verifyreviews', 'rv-5', 'SERVICE_REVIEW', 'APPROVED', true, 3, '2026-06-15 10:00 Europe/Amsterdam', 'none'),
           (v_t1, v_rev, v_ch_nl, 'verifyreviews', 'rv-6', 'SERVICE_REVIEW', 'APPROVED', true, 5, '2026-10-13 10:00 Europe/Amsterdam', 'none'),
           (v_t1, v_rev, v_ch_gb, 'verifyreviews', 'rv-7', 'SERVICE_REVIEW', 'APPROVED', true, 4, '2026-10-14 09:00 Europe/Amsterdam', 'none'),
           (v_t1, v_rev, v_ch_gb, 'verifyreviews', 'rv-8', 'SERVICE_REVIEW', 'APPROVED', true, 2, '2026-10-14 13:00 Europe/Amsterdam', 'none'),
           (v_t1, v_rev, v_ch_nl, 'verifyreviews', 'rv-9', 'SERVICE_REVIEW', 'APPROVED', true, 4, '2026-10-01 00:30 Europe/Amsterdam', 'none'),
           (v_t1, v_rev, v_ch_gb, 'verifyreviews', 'rv-10', 'SERVICE_REVIEW', 'APPROVED', true, 3, '2026-07-01 08:00 Europe/Amsterdam', 'none');

    -- A2. All, as of v_now: counted are rv-1, 2, 3, 5, 6, 7, 9 and 10 (rv-0's channel is not counted, rv-4 is not
    -- published, rv-8 comes after v_now); rv-9 (00:30 on 1 October in Amsterdam, 30 September in UTC) is October's: a
    -- month is the tenant's business date's
    j := cma.reviews_page_of(v_t1, null, '2026-10-14', null, 'month', v_now);
    v_txt := (j ->> 'from') || '..' || (j ->> 'to') || ' all ' || (j ->> 'all') || ' reviews ' || (j -> 'figures' ->> 'reviews')
             || ' avg ' || (j -> 'figures' ->> 'average_rating') || ' groups ' || jsonb_array_length(j -> 'groups')
             || ' first ' || (j -> 'groups' -> 0 ->> 'key') || ' last ' || (j -> 'groups' -> -1 ->> 'key')
             || ' sum ' || (select sum((g ->> 'reviews')::int) from jsonb_array_elements(j -> 'groups') g)
             || ' ' || (select string_agg((g ->> 'key') || '=' || (g ->> 'reviews'), ',' order by g ->> 'key') from jsonb_array_elements(j -> 'groups') g where (g ->> 'reviews')::int > 0)
             || ' prev ' || coalesce(j ->> 'previous_from', 'null') || '..' || coalesce(j ->> 'previous_to', 'null') || ':' || (j ->> 'previous_partial')
             || ':' || (j -> 'previous' ->> 'reviews')
             || ' dist-prev ' || (select sum((d ->> 'previous')::int) from jsonb_array_elements(j -> 'distribution') d)
             || ' markets ' || (select string_agg((x ->> 'market') || '=' || (x -> 'current' ->> 'reviews') || '/' || (x -> 'previous' ->> 'reviews'), ',') from jsonb_array_elements(j -> 'markets') x)
             || ' start ' || (j ->> 'history_start');
    v_exp := '2025-12-10..2026-10-14 all true reviews 8 avg 3.63 groups 11 first 2025-12-01 last 2026-10-01 sum 8 '
             || '2025-12-01=1,2026-01-01=1,2026-03-01=1,2026-06-01=1,2026-07-01=1,2026-10-01=3 prev null..null:false:0 dist-prev 0 '
             || 'markets GB=4/0,NL=3/0,unknown=1/0 start 2025-12-10';
    v_rows := v_rows || array['12', 'A2 All: from the first counted review to the end, every month, the sum of every counted review, the groups adding up, no previous period',
      case when v_txt = v_exp and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- A3. All with a market: the tenant's period, the market's reviews, the market's history start; a tenant without reviews
    j := cma.reviews_page_of(v_t1, null, '2026-10-14', 'NL', 'month', v_now);
    v_txt := (j ->> 'from') || '..' || (j ->> 'to') || ' reviews ' || (j -> 'figures' ->> 'reviews') || ' groups ' || jsonb_array_length(j -> 'groups')
             || ' start ' || (j ->> 'history_start');
    j := cma.reviews_page_of(v_t2, null, '2026-10-14', null, 'month', v_now);
    v_txt := v_txt || ' | ' || (j ->> 'from') || '..' || (j ->> 'to') || ' reviews ' || (j -> 'figures' ->> 'reviews') || ' groups '
             || (select string_agg((g ->> 'key') || '=' || (g ->> 'reviews'), ',') from jsonb_array_elements(j -> 'groups') g)
             || ' start ' || coalesce(j ->> 'history_start', 'null') || ' prev ' || coalesce(j ->> 'previous_from', 'null');
    v_rows := v_rows || array['13', 'A3 All with a market: the tenant''s period, the market''s reviews and history start; a tenant without reviews: one month, zeros',
      case when v_txt = '2025-12-10..2026-10-14 reviews 3 groups 11 start 2026-01-20 | 2026-10-14..2026-10-14 reviews 0 groups 2026-10-01=0 start null prev null'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- A4. a period as 0008ze's definition, key for key
    v_bad := '';
    for p in select * from (values ('2026-10-14'::date, '2026-10-14'::date, 'day'), ('2026-10-01', '2026-10-14', 'day'),
                                   ('2026-09-01', '2026-09-30', 'week'), ('2026-07-15', '2026-10-14', 'week')) x(f, t, g) loop
      foreach m in array array['*', 'GB', 'NL', 'unknown', 'DE'] loop
        j := cma.reviews_page_of(v_t1, p.f, p.t, nullif(m, '*'), p.g, v_now);
        if pg_temp.v0008zw_strip(j) is distinct from pg_temp.v0008zw_reviews_0008ze(v_t1, p.f, p.t, nullif(m, '*'), p.g, v_now)
           or (j ->> 'from')::date is distinct from p.f or (j ->> 'to')::date is distinct from p.t or (j ->> 'all')::boolean is distinct from false then
          v_bad := v_bad || p.f || '..' || p.t || ' ' || p.g || ' ' || m || '; ';
        end if;
      end loop;
    end loop;
    v_rows := v_rows || array['14', 'A4 a period answers as 0008ze''s definition, key for key (four periods, every market, unknown and all); its from and to the period''s, all false',
      case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, case when v_bad = '' then '20 pages equal' else v_bad end];

    -- A5. the read's parameters, as the application
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_reader::text, true);
    v_today := cma.tenant_today_of(v_t1);
    v_txt := pg_temp.v0008zw_code(format('select cma.reviews_page(null, %L, null, ''month'')', v_today))
             || ' ' || pg_temp.v0008zw_code(format('select cma.reviews_page(%L, %L, null, ''day'')', v_today - 10, v_today))
             || ' ' || pg_temp.v0008zw_code(format('select cma.reviews_page(null, %L, null, ''week'')', v_today))
             || ' ' || pg_temp.v0008zw_code(format('select cma.reviews_page(null, %L, null, null)', v_today))
             || ' ' || pg_temp.v0008zw_code('select cma.reviews_page(null, null, null, ''month'')')
             || ' ' || pg_temp.v0008zw_code(format('select cma.reviews_page(%L, %L, null, ''month'')', v_today - 10, v_today))
             || ' ' || pg_temp.v0008zw_code(format('select cma.reviews_page(%L, %L, null, ''week'')', v_today - 199, v_today))
             || ' ' || pg_temp.v0008zw_code(format('select cma.reviews_page(null, %L, ''NLD'', ''month'')', v_today))
             || ' ' || pg_temp.v0008zw_code(format('select cma.reviews_page(null, %L, null, ''month'')', v_today + 1))
             || ' ' || pg_temp.v0008zw_code(format('select cma.reviews_page(null, %L, null, ''month'')', v_today + 2))
             || ' ' || pg_temp.v0008zw_code('select cma.reviews_page(null, ''9999-12-31'', null, ''month'')');
    j := cma.reviews_page(null, v_today, null, 'month');
    v_txt := v_txt || ' ' || (j -> 'figures' ->> 'reviews') || ' ' || (j ->> 'from');
    perform set_config('app.user_id', v_agent::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zw_code(format('select cma.reviews_page(null, %L, null, ''month'')', v_today));
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['15', 'A5 the read''s parameters: All by month to today or the day after passes; All by week, without a group or an end, past tomorrow, a period by month, 200 days, a bad market refused (CMA04); no report permission (CMA06)',
      case when v_txt = 'ok ok CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 ok CMA04 CMA04 9 2025-12-10 CMA06' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- the orders fixture of tenant one: two GB stores and an NL store; on 30 and 31 October (Amsterdam)
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyshop', 'Verify shop GB 1', 'gb-1.shop.example', 'commerce') returning id into v_gb1;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyshop', 'Verify shop GB 2', 'gb-2.shop.example', 'commerce') returning id into v_gb2;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyshop', 'Verify shop NL', 'nl-1.shop.example', 'commerce') returning id into v_nl;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values
      (v_t1, v_gb1, 'gb-1', 'Shop GB 1', 'GB', 'GBP', 'Europe/London'), (v_t1, v_gb2, 'gb-2', 'Shop GB 2', 'GB', 'GBP', 'Europe/London'),
      (v_t1, v_nl, 'nl-1', 'Shop NL', 'NL', 'EUR', 'Europe/Amsterdam');
    insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, order_name, customer_source_id, source_created_at, is_test,
                                    currency, total_amount, refunded_amount, financial_status, fulfillment_status, order_kind) values
      (v_t1, v_gb1, 'verifyshop', 'o-1', '#1001', null, '2026-10-30 10:00 Europe/Amsterdam', false, 'GBP', 50.00, null, 'PAID', null, 'first'),
      (v_t1, v_gb1, 'verifyshop', 'o-2', '#1002', null, '2026-10-30 11:00 Europe/Amsterdam', false, 'GBP', 50.00, null, 'PAID', null, 'first'),
      (v_t1, v_gb1, 'verifyshop', 'o-3', '#1003', null, '2026-10-31 11:00 Europe/Amsterdam', false, 'GBP', 10.00, null, 'PAID', null, 'renewal'),
      (v_t1, v_gb2, 'verifyshop', 'o-4', '#2001', null, '2026-10-30 12:00 Europe/Amsterdam', false, 'GBP', 30.00, null, 'PAID', null, 'first'),
      (v_t1, v_gb2, 'verifyshop', 'o-5', '#2002', null, '2026-10-31 12:00 Europe/Amsterdam', false, 'GBP', 30.00, null, 'PAID', null, 'repeat'),
      (v_t1, v_gb2, 'verifyshop', 'o-6', '#2003', null, '2026-10-31 13:00 Europe/Amsterdam', true, 'GBP', 99.00, null, 'PAID', null, 'first'),
      (v_t1, v_nl, 'verifyshop', 'o-7', '#3001', null, '2026-10-30 14:00 Europe/Amsterdam', false, 'EUR', 40.00, null, 'PAID', null, 'first'),
      (v_t1, v_nl, 'verifyshop', 'o-8', '#3002', null, '2026-10-31 14:00 Europe/Amsterdam', false, 'EUR', 40.00, null, 'PAID', null, 'unknown');

    -- A6. the orders' live headline, as the reader: 7 orders (the test order left out)
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_reader::text, true);
    v_txt := '';
    foreach m in array array['*', 'GB', 'NL', 'DE'] loop
      j := cma.flash_headline('orders', nullif(m, '*'), '2026-10-30', '2026-10-31');
      v_txt := v_txt || m || ' ' || (j ->> 'value') || ' ' || pg_temp.v0008zw_split(j -> 'split') || ' | ';
    end loop;
    perform set_config('role', 'cma_owner', true);
    v_bad := pg_temp.v0008zw_orders_unbalanced(v_t1, (select jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures))
                                                      from cma.flash_compute_of(v_t1, 'orders', '2026-10-30', '2026-10-31') c));
    v_rows := v_rows || array['16', 'A6 the orders'' live headline per kind: summed over the GB stores, unknown only where an order has it, the test order out; adding up in all and per market',
      case when v_txt = '* 7 first 4, renewal 1, repeat 1, unknown 1 | GB 5 first 3, renewal 1, repeat 1 | NL 2 first 1, renewal 0, repeat 0, unknown 1 | DE 0 first 0, renewal 0, repeat 0 | '
                and v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_txt || v_bad];

    -- A7. as of a date: 30 and 31 October taken (the computation stored for each, as a take stores it), 29 October stored
    -- without the set [market, store, kind] (as a snapshot that holds none of its rows)
    foreach m in array array['2026-10-29', '2026-10-30', '2026-10-31'] loop
      insert into cma.flash_snapshot_run (id, tenant_id, snapshot_date, due_at, started_at, finished_at, status, sources)
      values (uuidv7(), v_t1, m::date, cma.flash_due_at_of('Europe/Amsterdam', '00:30', m::date), now(), now(), 'succeeded',
              '{"commerce": {"set_up": true, "last_read_at": null, "adapters": ["verifyshop"]}}')
      returning id into v_run;
      insert into cma.flash_snapshot (tenant_id, snapshot_date, overview, dims, measures, definition_version, computed_at, run_id)
      select v_t1, m::date, 'orders', c.dims, c.measures, cma.flash_definition_version('orders'), now(), v_run
      from cma.flash_compute_of(v_t1, 'orders', m::date, m::date, m::date) c
      where m::date <> '2026-10-29';
    end loop;
    -- 29 October: one invented order of GB's, stored as the totals and the market's row only
    insert into cma.flash_snapshot (tenant_id, snapshot_date, overview, dims, measures, definition_version, computed_at, run_id)
    select v_t1, '2026-10-29', 'orders', x.dims, x.measures, cma.flash_definition_version('orders'), now(), r.id
    from cma.flash_snapshot_run r
    cross join (values ('{}'::jsonb, '{"orders": 1, "units": 0, "amount": {"GBP": 10}}'::jsonb),
                       ('{"market": "GB"}'::jsonb, '{"orders": 1, "units": 0, "amount": {"GBP": 10}}'::jsonb)) x(dims, measures)
    where r.tenant_id = v_t1 and r.snapshot_date = '2026-10-29';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_reader::text, true);
    v_txt := '';
    foreach m in array array['*', 'GB', 'NL'] loop
      select c into j from jsonb_array_elements(cma.flash_page(nullif(m, '*'), '2026-10-31', '2026-10-30', '2026-10-31') -> 'overviews') c where c ->> 'key' = 'orders';
      v_txt := v_txt || m || ' ' || (j ->> 'value') || ' ' || pg_temp.v0008zw_split(j -> 'split') || ' | ';
    end loop;
    select c into j from jsonb_array_elements(cma.flash_page(null, '2026-10-29', '2026-10-29', '2026-10-29') -> 'overviews') c where c ->> 'key' = 'orders';
    v_txt := v_txt || '29 ' || (j ->> 'value') || ' ' || pg_temp.v0008zw_split(j -> 'split');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | stored ' || pg_temp.v0008zw_split(cma.flash_stored_split_of(v_t1, 'orders', 'GB', array['2026-10-30'::date]))
             || ' | none ' || pg_temp.v0008zw_split(cma.flash_stored_split_of(v_t1, 'orders', null, array['2026-10-29'::date]));
    v_rows := v_rows || array['17', 'A7 the orders'' split as of a date: the stored rows of [market, store, kind] over the period, per market; none for a snapshot without them',
      case when v_txt = '* 7 first 4, renewal 1, repeat 1, unknown 1 | GB 5 first 3, renewal 1, repeat 1 | NL 2 first 1, renewal 0, repeat 0, unknown 1 | 29 1 none'
                         || ' | stored first 3, renewal 0, repeat 0 | none none'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['29', 'A the block ran to the end', 'FAIL', sqlstate || ' ' || sqlerrm];
  end;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0008zw select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if not exists (select 1 from verify_0008zw where ord between 11 and 29) then
    insert into verify_0008zw values (29, 'A the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- D. Every active tenant's own data, read only (as the owner, the tenant named on every read)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  t record; m text;
  v_rows jsonb; j jsonb; v_from date; v_to date; v_today date; v_n integer;
  v_bad1 text := ''; v_bad2 text := ''; v_bad3 text := '';
  v_tenants integer := 0;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    v_tenants := v_tenants + 1;
    v_today := cma.tenant_today_of(t.id);
    -- D1. the subscriptions' live split as 0008zu's
    select jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures)) into v_rows from cma.flash_compute_of(t.id, 'subscriptions', null, null) c;
    foreach m in array array['*'] || coalesce((select array_agg(distinct r -> 'dims' ->> 'market') from jsonb_array_elements(coalesce(v_rows, '[]')) r
                                               where r -> 'dims' ? 'market'), '{}') loop
      if cma.flash_headline_split_of(t.id, 'subscriptions', v_rows, nullif(m, '*'))
         is distinct from cma.flash_split_of(v_rows, nullif(m, '*'), 'status', 'holding_subscriptions', cma.flash_holding_statuses_of(t.id)) then
        v_bad1 := v_bad1 || t.slug || ' ' || m || '; ';
      end if;
    end loop;
    -- D2. the orders over the previous month
    v_from := (date_trunc('month', v_today) - interval '1 month')::date;
    v_to := (date_trunc('month', v_today) - interval '1 day')::date;
    select jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures)) into v_rows from cma.flash_compute_of(t.id, 'orders', v_from, v_to) c;
    if v_rows is not null and pg_temp.v0008zw_orders_unbalanced(t.id, v_rows) <> '' then
      v_bad2 := v_bad2 || t.slug || ': ' || pg_temp.v0008zw_orders_unbalanced(t.id, v_rows) || '; ';
    end if;
    -- D3. All, and the last 92 days by week as 0008ze's
    j := cma.reviews_page_of(t.id, null, v_today, null, 'month', now());
    select count(*) into v_n from cma.reviews_of(t.id) x where x.submitted_at <= now() and x.business_date <= v_today;
    if (j -> 'figures' ->> 'reviews')::integer <> v_n
       or (select coalesce(sum((g ->> 'reviews')::integer), 0) from jsonb_array_elements(j -> 'groups') g) <> v_n
       or (j -> 'groups' -> 0 ->> 'key')::date <> date_trunc('month', (j ->> 'from')::date)::date
       or (j -> 'groups' -> -1 ->> 'key')::date <> date_trunc('month', v_today)::date
       or jsonb_array_length(j -> 'groups') <> (extract(year from age(date_trunc('month', v_today), date_trunc('month', (j ->> 'from')::date))) * 12
                                                + extract(month from age(date_trunc('month', v_today), date_trunc('month', (j ->> 'from')::date))) + 1)::integer
       or j ->> 'previous_from' is not null or (j -> 'previous' ->> 'reviews')::integer <> 0 then
      v_bad3 := v_bad3 || t.slug || ' all ' || (j -> 'figures' ->> 'reviews') || '/' || v_n || '; ';
    end if;
    if pg_temp.v0008zw_strip(cma.reviews_page_of(t.id, v_today - 91, v_today, null, 'week', now()))
       is distinct from pg_temp.v0008zw_reviews_0008ze(t.id, v_today - 91, v_today, null, 'week', now()) then
      v_bad3 := v_bad3 || t.slug || ' 92 days; ';
    end if;
  end loop;
  insert into verify_0008zw values
    (31, 'D1 every active tenant: the subscriptions'' live split as 0008zu''s, in all and per market',
     case when v_tenants = 0 then 'skip' when v_bad1 = '' and not v_provoke then 'ok' else 'FAIL' end,
     case when v_tenants = 0 then 'no active tenant' when v_bad1 = '' then v_tenants || ' tenant(s)' else v_bad1 end),
    (32, 'D2 every active tenant: the orders'' split over the previous month adding up in all and per market, the three kinds, unknown only above 0',
     case when v_tenants = 0 then 'skip' when v_bad2 = '' and not v_provoke then 'ok' else 'FAIL' end,
     case when v_tenants = 0 then 'no active tenant' when v_bad2 = '' then v_tenants || ' tenant(s)' else v_bad2 end),
    (33, 'D3 every active tenant: All the count of every counted review by now, monthly from its first month to this one, no previous period; 92 days as 0008ze''s',
     case when v_tenants = 0 then 'skip' when v_bad3 = '' and not v_provoke then 'ok' else 'FAIL' end,
     case when v_tenants = 0 then 'no active tenant' when v_bad3 = '' then v_tenants || ' tenant(s)' else v_bad3 end);
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0008zw_code(text);
drop function if exists pg_temp.v0008zw_split(jsonb);
drop function if exists pg_temp.v0008zw_orders_unbalanced(uuid, jsonb);
drop function if exists pg_temp.v0008zw_strip(jsonb);
drop function if exists pg_temp.v0008zw_reviews_0008ze(uuid, date, date, text, text, timestamptz);

-- Verdict: one row per check, then the verdict: no FAIL, a skip only where the check says why (no active tenant)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zw
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from verify_0008zw where result not in ('ok', 'skip')) then 'FAIL'
                  when (select count(*) from verify_0008zw where result = 'ok') >= 10 then '0008zw verified'
                  else 'FAIL' end,
             format('143_verify_reviews_all_order_kinds: %s ok, %s FAIL, %s skip', (select count(*) from verify_0008zw where result = 'ok'),
                    (select count(*) from verify_0008zw where result not in ('ok', 'skip')),
                    (select count(*) from verify_0008zw where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0008zw;
reset role;
