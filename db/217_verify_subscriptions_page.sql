-- =============================================================================================
-- 217_verify_subscriptions_page.sql: verifies addition 0009zh, Customers → Subscriptions (brief B39 continued, Part B39d)
-- =============================================================================================
-- Dev and local databases only, as 211: it refuses a database without the dev seed (no active agent.two@example.com):
-- block B's checks then read FAIL and the verdict REFUSED. Block A only reads; block B works on the dev seed's tenant
-- Pulse4all Subscriptions (its three seed stores and their subscriptions) inside a subtransaction that is always rolled
-- back, so nothing stays: it computes the subscription facts as the tenant's scheduler when no take is stored yet, gives
-- some of the take's rows propositions, models and unknown device units as the owner (the seed maps no variant), and
-- reads the page as the seed's manager (cma_app, row-level security on). Every check writes one row, PASS or FAIL, and
-- the last row is the verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login after
-- 216_subscriptions_page.sql, in dev. No row carries a name, an address, an email or a phone number.
--   A  the addition row after 0009zf; the ten functions the application's (not public's), invoker's rights, JIT off
--   B  for every filter (none, each market, each store, a proposition, none, each interval group, a market with an
--      interval, a store with a proposition): the tiles against the take; the months against the month take (and the
--      proposition and interval filters leaving them as they are); the last complete month's rates against the month
--      take and Customers → Active's card; renewal survival against its take with the migrated left out; the mix's sums;
--      the list's totals per measure against the tiles, its pages walked whole under two sorts, the file's rows; the
--      refusals (CMA06 for an agent, CMA04 for every bad filter, measure, sort and page); the file's audit row; another
--      tenant's application sees none of the take; the list's codes read from the mirror equal it; the subscription app's
--      own counts beside the tiles (B39b's source figures, built for two stores) summed and compared by 214's rule
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED instead.
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
-- dev or a local database only: the dev seed's agent.two@example.com active, as 211
select set_config('verify.dev', (select exists (select 1 from cma.app_user u where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false);

drop table if exists pg_temp.verify_0009zh;
create temp table verify_0009zh (ord int, check_name text, result text, detail text);

-- The error a statement raises as its SQLSTATE, or 'ok'
create or replace function pg_temp.v0009zh_code(p_sql text)
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

-- A. The addition and its functions
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_txt text;
begin
  v_txt := (select string_agg(format('%s:%s:%s:%s:%s', p.proname,
                                     has_function_privilege('cma_app', p.oid, 'execute')::text,
                                     has_function_privilege('public', p.oid, 'execute')::text,
                                     p.prosecdef::text, coalesce('jit=off' = any (p.proconfig), false)::text), ' ' order by p.proname collate "C")
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'cma' and p.proname in ('assert_subscriptions_filter', 'assert_subscription_list', 'subscriptions_scope_of', 'subscription_rows_of',
                                                      'subscriptions_page_of', 'subscriptions_page', 'subscription_rows',
                                                      'subscription_file_record', 'subscriptions_churn_card', 'subscriptions_source_counts_of'))
           || ' | ' || coalesce((select (m.applied_at >= p.applied_at)::text from cma.schema_migration m, cma.schema_migration p
                                 where m.version = '0009zh' and p.version = '0009zf'), 'missing');
  insert into verify_0009zh values (1, 'A1 0009zh recorded after 0009zf; the ten functions executable by cma_app and not by public, with the caller''s rights and JIT off',
    case when v_txt = 'assert_subscription_list:true:false:false:true assert_subscriptions_filter:true:false:false:true subscription_file_record:true:false:false:true '
                      || 'subscription_rows:true:false:false:true subscription_rows_of:true:false:false:true '
                      || 'subscriptions_churn_card:true:false:false:true subscriptions_page:true:false:false:true '
                      || 'subscriptions_page_of:true:false:false:true subscriptions_scope_of:true:false:false:true subscriptions_source_counts_of:true:false:false:true | true'
              and not v_provoke then 'PASS' else 'FAIL' end, v_txt);
end
$$;

-- B. The page against the takes, on the dev seed's tenant (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_rows    text[] := '{}';
  v_t uuid; v_inv uuid; v_mgr uuid; v_agent uuid; v_sch uuid;
  v_zone text; v_month date; v_from date;
  v_holding text[]; v_active text[];
  v_f record; v_j jsonb; v_j0 jsonb; v_k jsonb;
  v_bad text := ''; v_bad2 text := ''; v_bad3 text := ''; v_bad4 text := ''; v_bad5 text := ''; v_bad6 text := '';
  v_txt text; v_n integer; v_size integer; v_ids uuid[]; v_page integer; v_seen uuid[]; v_prev numeric; v_prevc text; v_ok boolean;
  v_m1 text; v_s1 uuid; v_s2 uuid; v_audit bigint; v_today date;
begin
  if not v_dev then
    insert into verify_0009zh values (59, 'B a dev or local database (the dev seed''s agent.two@example.com active)', 'FAIL',
      'REFUSED: no dev seed, so this is no dev or local database; nothing ran');
    return;
  end if;
  begin
    select t.id, t.timezone into v_t, v_zone from cma.tenant t where t.slug = 'pulse4all-subscriptions';
    select t.id into v_inv from cma.tenant t where t.slug = 'pulse4all-invest';
    perform set_config('app.tenant_id', v_t::text, true);
    select u.id into v_mgr from cma.app_user u join cma.user_role ur on ur.tenant_id = u.tenant_id and ur.user_id = u.id
      join cma.app_role r on r.tenant_id = u.tenant_id and r.id = ur.role_id
      where u.tenant_id = v_t and u.status = 'active' and u.kind = 'person' and r.key = 'manager' order by u.created_at, u.id limit 1;
    select u.id into v_agent from cma.app_user u where u.tenant_id = v_t and u.email = 'agent.two@example.com';
    select u.id into v_sch from cma.app_user u where u.tenant_id = v_t and u.kind = 'system' and u.email = 'scheduler@system.invalid';
    v_month := date_trunc('month', now() at time zone v_zone)::date;
    v_today := (now() at time zone v_zone)::date;
    v_from := (v_month - interval '23 months')::date;
    v_holding := cma.flash_list_of(cma.setting_of(v_t, 'flash.device_holding_statuses'));
    v_active := cma.flash_list_of(cma.setting_of(v_t, 'flash.active_subscription_statuses'));

    -- the facts, computed as the scheduler when the tenant has no take yet (a take the minute job stored is read as it is)
    if not exists (select 1 from cma.subscription_take_state s where s.tenant_id = v_t) then
      perform set_config('app.user_id', v_sch::text, true);
      perform set_config('role', 'cma_app', true);
      perform cma.subscription_facts_refresh_of(v_t, true);
      perform set_config('role', 'cma_owner', true);
    end if;
    -- propositions, models and unknown device units on some of the take's rows (the seed maps no variant)
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'subscriptions.propositions', 'vp1,vp2')
      on conflict (tenant_id, key) do update set value = excluded.value;
    update cma.subscription_take x
    set propositions = case when z.r % 5 = 0 then array['vp1', 'vp2'] when z.r % 3 = 0 then array['vp1'] else '{}' end,
        models = case when z.r % 4 = 0 then array['vzh_model'] else '{}' end,
        device_units = case when z.r % 7 = 0 then null else coalesce(x.device_units, 0) + (z.r % 3) end
    from (select t.subscription_id, row_number() over (order by t.source_id collate "C", t.subscription_id) as r
          from cma.subscription_take t where t.tenant_id = v_t) z
    where x.tenant_id = v_t and x.subscription_id = z.subscription_id;
    select min(t.market collate "C") into v_m1 from cma.subscription_take t where t.tenant_id = v_t;
    select y.connection_id into v_s1 from cma.flash_subscription_stores_of(v_t) y order by y.handle collate "C" limit 1;
    select y.connection_id into v_s2 from cma.flash_subscription_stores_of(v_t) y order by y.handle collate "C" desc limit 1;

    create temp table if not exists v0009zh_filters (n integer, market text, store uuid, proposition text, interval_group text) on commit drop;
    delete from v0009zh_filters;
    insert into v0009zh_filters values (1, null, null, null, null);
    insert into v0009zh_filters select 10 + row_number() over (order by m collate "C"), m, null, null, null
      from (select distinct t.market as m from cma.subscription_take t where t.tenant_id = v_t) d;
    insert into v0009zh_filters select 20 + row_number() over (order by y.handle collate "C"), null, y.connection_id, null, null
      from cma.flash_subscription_stores_of(v_t) y;
    insert into v0009zh_filters values (31, null, null, 'vp1', null), (32, null, null, 'vp2', null), (33, null, null, 'none', null),
      (41, null, null, null, 'monthly'), (42, null, null, null, 'yearly'), (43, null, null, null, 'other'),
      (51, v_m1, null, null, 'monthly'), (52, null, v_s2, 'vp2', null);

    for v_f in select * from v0009zh_filters order by n loop
      perform set_config('app.user_id', v_mgr::text, true);
      perform set_config('role', 'cma_app', true);
      v_j := cma.subscriptions_page(v_f.market, v_f.store, v_f.proposition, v_f.interval_group, v_from, v_month);
      v_j0 := cma.subscriptions_page(v_f.market, v_f.store, null, null, v_from, v_month);
      perform set_config('role', 'cma_owner', true);

      -- B1 the tiles against the take
      with t as (select x.* from cma.subscription_take x where x.tenant_id = v_t
                   and (v_f.market is null or x.market = v_f.market) and (v_f.store is null or x.connection_id = v_f.store)
                   and (v_f.proposition is null or (v_f.proposition = 'none' and x.propositions = '{}') or v_f.proposition = any (x.propositions))
                   and (v_f.interval_group is null or x.interval_group = v_f.interval_group))
      select concat_ws(';',
               case when (v_j #>> '{tiles,total,value}')::bigint is distinct from (select count(*) from t where t.status = any (v_holding)) then 'total' end,
               case when (select string_agg(k || '=' || (v_j #>> array['tiles', 'total', 'by_status', k]), ',' order by k collate "C") from unnest(v_holding) k)
                         is distinct from (select string_agg(k || '=' || (select count(*) from t where t.status = k), ',' order by k collate "C") from unnest(v_holding) k)
                    then 'by_status' end,
               case when (v_j #>> '{tiles,paused}')::bigint is distinct from (select count(*) from t where t.status = 'paused') then 'paused' end,
               case when (select string_agg((a ->> 'currency') || '=' || (a ->> 'amount')::numeric || '/' || (a ->> 'subscriptions'), ',' order by a ->> 'currency' collate "C")
                          from jsonb_array_elements(v_j #> '{tiles,amounts}') a)
                         is distinct from (select string_agg(c || '=' || s || '/' || n, ',' order by c collate "C")
                                           from (select t.currency as c, round(sum(t.monthly_amount), 2) as s, count(*) as n from t
                                                 where t.status = any (v_active) and t.currency is not null and t.monthly_amount is not null group by 1) z)
                    then 'amounts' end,
               case when (v_j #>> '{tiles,devices,units}')::bigint is distinct from (select coalesce(sum(t.device_units), 0) from t where t.status = any (v_holding))
                         or (v_j #>> '{tiles,devices,unmapped}')::bigint is distinct from (select count(*) from t where t.status = any (v_holding) and t.device_units is null)
                    then 'devices' end,
               case when (v_f.proposition is not null or v_f.interval_group is not null) and v_j #> '{tiles,source_counts}' <> 'null'::jsonb
                    then 'source_counts' end)
      into v_txt;
      if v_txt <> '' then v_bad := v_bad || v_f.n || ':' || v_txt || ' '; end if;

      -- B2 the months against the month take; the proposition and interval filters leave them as they are
      select concat_ws(';',
               case when (select string_agg(mo ->> 'month' || ':' || coalesce((select string_agg(k || '=' || v, ',' order by k collate "C")
                                                                               from jsonb_each_text(case when jsonb_typeof(mo -> 'counts') = 'object' then mo -> 'counts' else '{}' end) e(k, v)), ''), ' ' order by mo ->> 'month' collate "C")
                          from jsonb_array_elements(v_j -> 'months') mo)
                         is distinct from
                         (select string_agg(g::date || ':' || coalesce((select string_agg(k || '=' || n, ',' order by k collate "C")
                                                                       from (select x.kind as k, sum(x.subscriptions) as n from cma.subscription_month_take x
                                                                             where x.tenant_id = v_t and x.month = g::date and x.currency = ''
                                                                               and (v_f.market is null or x.market = v_f.market)
                                                                               and (v_f.store is null or x.connection_id = v_f.store) group by 1) z), ''),
                                           ' ' order by g)
                          from generate_series(v_from, v_month, interval '1 month') g)
                    then 'counts' end,
               case when (select string_agg(mo ->> 'month' || ':' || coalesce((select string_agg(c || '.' || k || '=' || (v)::numeric, ',' order by c collate "C", k collate "C")
                                                                               from jsonb_each(case when jsonb_typeof(mo -> 'amounts') = 'object' then mo -> 'amounts' else '{}' end) a(c, kinds), jsonb_each_text(kinds) b(k, v)), ''), ' ' order by mo ->> 'month' collate "C")
                          from jsonb_array_elements(v_j -> 'months') mo)
                         is distinct from
                         (select string_agg(g::date || ':' || coalesce((select string_agg(c || '.' || k || '=' || s, ',' order by c collate "C", k collate "C")
                                                                       from (select x.currency as c, x.kind as k, sum(x.amount) as s from cma.subscription_month_take x
                                                                             where x.tenant_id = v_t and x.month = g::date and x.currency <> '' and x.amount is not null
                                                                               and (v_f.market is null or x.market = v_f.market)
                                                                               and (v_f.store is null or x.connection_id = v_f.store) group by 1, 2) z), ''),
                                           ' ' order by g)
                          from generate_series(v_from, v_month, interval '1 month') g)
                    then 'amounts' end,
               case when (v_j -> 'months') is distinct from (v_j0 -> 'months') or (v_j -> 'rates') is distinct from (v_j0 -> 'rates') then 'pi_changes_months' end)
      into v_txt;
      if v_txt <> '' then v_bad2 := v_bad2 || v_f.n || ':' || v_txt || ' '; end if;

      -- B3 the last complete month's rates against the month take, and the rates per market against the months' complete parts
      select concat_ws(';',
               case when coalesce(v_j #> '{tiles,rates}', 'null'::jsonb) is distinct from coalesce((
                      select jsonb_build_object('month', l.month, 'base', sum(x.subscriptions) filter (where x.kind = 'start'),
                                                'churned', coalesce(sum(x.subscriptions) filter (where x.kind = 'churned'), 0),
                                                'moved_to_failed', coalesce(sum(x.subscriptions) filter (where x.kind = 'moved_to_failed'), 0))
                      from (select max(y.month) as month from cma.subscription_month_take y
                            where y.tenant_id = v_t and y.currency = '' and y.complete and y.month <= v_month
                              and (v_f.market is null or y.market = v_f.market) and (v_f.store is null or y.connection_id = v_f.store)) l
                      join cma.subscription_month_take x on x.tenant_id = v_t and x.month = l.month and x.currency = '' and x.complete
                        and (v_f.market is null or x.market = v_f.market) and (v_f.store is null or x.connection_id = v_f.store)
                      group by l.month), 'null'::jsonb) then 'tile' end,
               case when (select coalesce(sum((r ->> 'churned')::bigint), 0) || '/' || coalesce(sum((r ->> 'base')::bigint), 0)
                          from jsonb_array_elements(v_j -> 'rates') r)
                         is distinct from (select coalesce(sum((mo #>> '{complete,churned}')::bigint), 0) || '/' || coalesce(sum((mo #>> '{complete,base}')::bigint), 0)
                                           from jsonb_array_elements(v_j -> 'months') mo)
                    then 'rates' end)
      into v_txt;
      if v_txt <> '' then v_bad3 := v_bad3 || v_f.n || ':' || v_txt || ' '; end if;

      -- B4 renewal survival against its take (cohorts in the range), the migrated left out counted
      select concat_ws(';',
               case when (select coalesce(sum((c ->> 'started')::bigint), 0) || '/' || coalesce(sum((cell ->> 'eligible')::bigint), 0) || '/' || coalesce(sum((cell ->> 'survived')::bigint), 0)
                          from jsonb_array_elements(v_j #> '{survival,groups}') g, jsonb_array_elements(g -> 'cohorts') c, jsonb_array_elements(c -> 'cells') cell
                          where (cell ->> 'renewal')::integer = 1)
                         || '|' || (select coalesce(sum((cell ->> 'survived')::bigint), 0)
                                    from jsonb_array_elements(v_j #> '{survival,groups}') g, jsonb_array_elements(g -> 'cohorts') c, jsonb_array_elements(c -> 'cells') cell)
                         is distinct from
                         (select coalesce(sum(x.started), 0) || '/' || coalesce(sum(x.eligible), 0) || '/' || coalesce(sum(x.survived), 0)
                          from cma.subscription_survival_take x
                          where x.tenant_id = v_t and x.renewal_number = 1 and x.cohort_month between v_from and v_month
                            and (v_f.market is null or x.market = v_f.market) and (v_f.store is null or x.connection_id = v_f.store)
                            and (v_f.interval_group is null or x.interval_group = v_f.interval_group))
                         || '|' || (select coalesce(sum(z.s), 0)
                                    from (select x.renewal_number as n, sum(x.eligible) as e, sum(x.survived) as s
                                          from cma.subscription_survival_take x
                                          where x.tenant_id = v_t and x.cohort_month between v_from and v_month
                                            and (v_f.market is null or x.market = v_f.market) and (v_f.store is null or x.connection_id = v_f.store)
                                            and (v_f.interval_group is null or x.interval_group = v_f.interval_group)
                                          group by x.interval_group, x.cohort_month, x.renewal_number) z
                                    where z.e > 0 or z.n = 1)
                    then 'cells' end,
               case when (v_j #>> '{survival,migrated_left_out}')::bigint is distinct from (select count(*) from cma.subscriptions_scope_of(v_t, v_f.market, v_f.store, v_f.proposition, v_f.interval_group) s where s.migrated)
                    then 'migrated' end)
      into v_txt;
      if v_txt <> '' then v_bad4 := v_bad4 || v_f.n || ':' || v_txt || ' '; end if;

      -- B5 the mix: every single-valued breakdown sums to the Total subscriptions; propositions and models per key
      select concat_ws(';',
               (select string_agg(d, ',' order by d collate "C") from unnest(array['interval', 'device_band', 'age_band', 'instrument', 'payment_state']) d
                where (select coalesce(sum((e ->> 'subscriptions')::bigint), 0) from jsonb_array_elements(v_j #> array['mix', d]) e)
                      is distinct from (v_j #>> '{tiles,total,value}')::bigint),
               case when (select string_agg((e ->> 'key') || '=' || (e ->> 'subscriptions'), ',' order by e ->> 'key' collate "C") from jsonb_array_elements(v_j #> '{mix,proposition}') e)
                         is distinct from (select string_agg(k || '=' || n, ',' order by k collate "C")
                                           from (select coalesce(p, 'none') as k, count(*) as n
                                                 from cma.subscriptions_scope_of(v_t, v_f.market, v_f.store, v_f.proposition, v_f.interval_group) s
                                                 left join lateral unnest(nullif(s.propositions, '{}')) p on true
                                                 where s.status = any (v_holding) group by 1) z)
                    then 'proposition' end,
               case when (select string_agg((e ->> 'key') || '=' || (e ->> 'subscriptions'), ',' order by e ->> 'key' collate "C") from jsonb_array_elements(v_j #> '{mix,model}') e)
                         is distinct from (select string_agg(k || '=' || n, ',' order by k collate "C")
                                           from (select coalesce(m, 'none') as k, count(*) as n
                                                 from cma.subscriptions_scope_of(v_t, v_f.market, v_f.store, v_f.proposition, v_f.interval_group) s
                                                 left join lateral unnest(nullif(s.models, '{}')) m on true
                                                 where s.status = any (v_holding) group by 1) z)
                    then 'model' end)
      into v_txt;
      if v_txt <> '' then v_bad5 := v_bad5 || v_f.n || ':' || v_txt || ' '; end if;

      -- B6 the list's totals per measure against the tiles and the take
      perform set_config('role', 'cma_app', true);
      select concat_ws(';',
               case when (v_j #>> '{list,total}')::bigint is distinct from (v_j #>> '{tiles,total,value}')::bigint then 'first_page' end,
               case when (cma.subscription_rows(v_f.market, v_f.store, v_f.proposition, v_f.interval_group, 'total', 'monthly_amount', true, 1, 50, false) ->> 'total')::bigint
                         is distinct from (v_j #>> '{tiles,total,value}')::bigint then 'total' end,
               case when (cma.subscriptions_page(v_f.market, v_f.store, v_f.proposition, v_f.interval_group, v_from, v_month, 'total', 'monthly_amount', true, 2) #> '{list,rows}')
                         is distinct from (cma.subscription_rows(v_f.market, v_f.store, v_f.proposition, v_f.interval_group, 'total', 'monthly_amount', true, 2, 50, false) -> 'rows')
                    then 'page_2' end,
               case when (cma.subscription_rows(v_f.market, v_f.store, v_f.proposition, v_f.interval_group, 'paused', 'monthly_amount', true, 1, 50, false) ->> 'total')::bigint
                         is distinct from (v_j #>> '{tiles,paused}')::bigint then 'paused' end,
               case when (cma.subscription_rows(v_f.market, v_f.store, v_f.proposition, v_f.interval_group, 'unmapped', 'monthly_amount', true, 1, 50, false) ->> 'total')::bigint
                         is distinct from (v_j #>> '{tiles,devices,unmapped}')::bigint then 'unmapped' end,
               case when (cma.subscription_rows(v_f.market, v_f.store, v_f.proposition, v_f.interval_group, 'failed', 'monthly_amount', true, 1, 50, false) ->> 'total')::bigint
                         is distinct from (select count(*) from cma.subscriptions_scope_of(v_t, v_f.market, v_f.store, v_f.proposition, v_f.interval_group) s where s.status = 'failed')
                    then 'failed' end,
               case when (cma.subscription_rows(v_f.market, v_f.store, v_f.proposition, v_f.interval_group, 'active', 'monthly_amount', true, 1, 50, false) ->> 'total')::bigint
                         is distinct from (select count(*) from cma.subscriptions_scope_of(v_t, v_f.market, v_f.store, v_f.proposition, v_f.interval_group) s where s.status = any (v_active))
                    then 'active' end,
               case when jsonb_array_length(cma.subscription_rows(v_f.market, v_f.store, v_f.proposition, v_f.interval_group, 'all', 'monthly_amount', true, null, null, true) -> 'rows')
                         is distinct from (select count(*)::integer from cma.subscriptions_scope_of(v_t, v_f.market, v_f.store, v_f.proposition, v_f.interval_group))
                    then 'file' end)
      into v_txt;
      perform set_config('role', 'cma_owner', true);
      if v_txt <> '' then v_bad6 := v_bad6 || v_f.n || ':' || v_txt || ' '; end if;
    end loop;

    v_rows := v_rows || array['10', 'B1 the tiles equal the take for every filter: Total subscriptions and its split per holding status, Paused, the Monthly recurring amount per currency, device units and the unmapped; no source counts under a proposition or interval filter',
      case when v_bad = '' and (select count(*) from v0009zh_filters) >= 12 and not v_provoke then 'PASS' else 'FAIL' end,
      'filters ' || (select count(*) from v0009zh_filters) || '; mismatches: ' || coalesce(nullif(v_bad, ''), 'none')];
    v_rows := v_rows || array['11', 'B2 the months'' counts per kind and amounts per currency equal the month take under the market and store filters; a proposition or interval filter leaves months and rates as they are',
      case when v_bad2 = '' and not v_provoke then 'PASS' else 'FAIL' end, 'mismatches: ' || coalesce(nullif(v_bad2, ''), 'none')];
    v_rows := v_rows || array['12', 'B3 the last complete month''s churned, moved to failed and base equal the month take''s complete rows; the rates per market sum to the months'' complete parts',
      case when v_bad3 = '' and not v_provoke then 'PASS' else 'FAIL' end, 'mismatches: ' || coalesce(nullif(v_bad3, ''), 'none')];
    v_rows := v_rows || array['13', 'B4 renewal survival equals its take for the cohorts in the range under the market, store and interval filters; the migrated subscriptions left out are counted',
      case when v_bad4 = '' and not v_provoke then 'PASS' else 'FAIL' end, 'mismatches: ' || coalesce(nullif(v_bad4, ''), 'none')];
    v_rows := v_rows || array['14', 'B5 the mix: interval, device band, age band, instrument and payment state each sum to the Total subscriptions; propositions and models per key equal the take',
      case when v_bad5 = '' and not v_provoke then 'PASS' else 'FAIL' end, 'mismatches: ' || coalesce(nullif(v_bad5, ''), 'none')];
    v_rows := v_rows || array['15', 'B6 the list''s totals per measure (total, paused, unmapped, failed, active) equal the tiles and the take; the page read''s page 2 equals the list''s; the file holds every row of the measure',
      case when v_bad6 = '' and not v_provoke then 'PASS' else 'FAIL' end, 'mismatches: ' || coalesce(nullif(v_bad6, ''), 'none')];

    -- B7 the list's pages walked whole: every subscription of the measure all once, in the sort's order (four sorts); pages
    --    of 37 (a page size no default divides), of 200 on a take of more than 2,000 (the local volume fixture)
    v_size := case when (select count(*) from cma.subscription_take t where t.tenant_id = v_t) > 2000 then 200 else 37 end;
    perform set_config('app.user_id', v_mgr::text, true);
    perform set_config('role', 'cma_app', true);
    v_txt := '';
    for v_k in select to_jsonb(x) from (values ('monthly_amount', true), ('subscription', false), ('payment_state', false), ('device_units', true),
                                               ('market', false), ('status', true), ('interval', false)) x(s, d) loop
      v_seen := '{}'; v_page := 1; v_prev := null; v_prevc := null; v_ok := true;
      loop
        v_j := cma.subscription_rows(null, null, null, null, 'all', v_k ->> 's', (v_k ->> 'd')::boolean, v_page, v_size, false);
        exit when jsonb_array_length(v_j -> 'rows') = 0 or v_page > 5000;
        v_seen := v_seen || array(select (r ->> 'subscription_id')::uuid from jsonb_array_elements(v_j -> 'rows') r);
        if v_k ->> 's' = 'monthly_amount' then
          -- descending: the currencies in falling byte order, the amounts falling within each
          for v_n in 0 .. jsonb_array_length(v_j -> 'rows') - 1 loop
            if v_prevc is not null and coalesce(v_j -> 'rows' -> v_n ->> 'currency', '') collate "C" > v_prevc collate "C" then v_ok := false; end if;
            if v_prevc is not distinct from coalesce(v_j -> 'rows' -> v_n ->> 'currency', '')
               and coalesce((v_j -> 'rows' -> v_n ->> 'monthly_amount')::numeric, -1) > v_prev then v_ok := false; end if;
            v_prevc := coalesce(v_j -> 'rows' -> v_n ->> 'currency', '');
            v_prev := coalesce((v_j -> 'rows' -> v_n ->> 'monthly_amount')::numeric, -1);
          end loop;
        end if;
        v_page := v_page + 1;
      end loop;
      perform set_config('role', 'cma_owner', true);
      v_txt := v_txt || (v_k ->> 's') || ':' || cardinality(v_seen) || '/' || (select count(distinct u) from unnest(v_seen) u) || '/'
               || (select count(*) from cma.subscription_take t where t.tenant_id = v_t) || '/'
               || ((select array_agg(u order by u) from unnest(v_seen) u) = (select array_agg(t.subscription_id order by t.subscription_id) from cma.subscription_take t where t.tenant_id = v_t))::text
               || '/' || v_ok || ' ';
      perform set_config('role', 'cma_app', true);
    end loop;
    perform set_config('role', 'cma_owner', true);
    v_n := (select count(*) from cma.subscription_take t where t.tenant_id = v_t);
    v_rows := v_rows || array['16', 'B7 the list''s pages (of 37; of 200 above 2,000 subscriptions), walked to the end under all seven sorts, hold every subscription of the take once; the amount''s sort by currency, never rising within one',
      case when v_txt = format('monthly_amount:%1$s/%1$s/%1$s/true/true subscription:%1$s/%1$s/%1$s/true/true payment_state:%1$s/%1$s/%1$s/true/true '
                               || 'device_units:%1$s/%1$s/%1$s/true/true market:%1$s/%1$s/%1$s/true/true status:%1$s/%1$s/%1$s/true/true '
                               || 'interval:%1$s/%1$s/%1$s/true/true ', v_n)
                and v_n > 37 and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8 the refusals: an agent CMA06 on every read; the manager CMA04 for every bad filter, measure, sort and page
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_agent::text, true);
    v_txt := pg_temp.v0009zh_code(format('select cma.subscriptions_page(null, null, null, null, %L, %L)', v_from, v_month))
             || ' ' || pg_temp.v0009zh_code('select cma.subscription_rows(null, null, null, null, ''total'', ''monthly_amount'', true, 1, 50, false)')
             || ' ' || pg_temp.v0009zh_code('select cma.subscription_file_record(''records'', null, null, null, null, ''total'', 3)')
             || ' ' || pg_temp.v0009zh_code('select cma.subscriptions_churn_card(null)');
    perform set_config('app.user_id', v_mgr::text, true);
    v_txt := v_txt || ' | '
      || (select string_agg(pg_temp.v0009zh_code(q), ' ' order by o) from unnest(array[
           format('select cma.subscriptions_page(''gb'', null, null, null, %L, %L)', v_from, v_month),
           format('select cma.subscriptions_page(null, %L, null, null, %L, %L)', gen_random_uuid(), v_from, v_month),
           format('select cma.subscriptions_page(null, null, ''nope'', null, %L, %L)', v_from, v_month),
           format('select cma.subscriptions_page(null, null, null, ''weekly'', %L, %L)', v_from, v_month),
           format('select cma.subscriptions_page(null, null, null, null, %L, %L)', v_month, v_from),
           format('select cma.subscriptions_page(null, null, null, null, %L, %L)', v_from + 1, v_month),
           format('select cma.subscriptions_page(null, null, null, null, %L, %L)', v_from, (v_month + interval '1 month')::date),
           format('select cma.subscriptions_page(null, null, null, null, %L, %L)', (v_month - interval '10 years')::date, v_month),
           format('select cma.subscriptions_page(null, null, null, null, %L, %L, ''x'')', v_from, v_month),
           format('select cma.subscriptions_page(null, null, null, null, %L, %L, ''total'', ''name'')', v_from, v_month),
           'select cma.subscription_rows(null, null, null, null, ''total'', ''monthly_amount'', true, 0, 50, false)',
           'select cma.subscription_rows(null, null, null, null, ''total'', ''monthly_amount'', true, 1, 201, false)',
           'select cma.subscription_rows(null, null, null, null, null, ''monthly_amount'', true, 1, 50, false)',
           'select cma.subscription_rows(null, null, null, null, ''total'', ''monthly_amount'', null, 1, 50, false)',
           format('select cma.subscriptions_page(null, null, null, null, %L, %L, ''total'', ''monthly_amount'', true, 0)', v_from, v_month),
           'select cma.subscription_file_record(''records'', null, null, null, null, ''total'', -1)',
           'select cma.subscription_file_record(''list'', null, null, null, null, ''total'', 3)',
           format('select cma.subscription_file_record(''records'', null, null, null, null, ''total'', 3, %L, %L)', v_from, v_month),
           'select cma.subscriptions_churn_card(''xx'')']) with ordinality u(q, o))
      || ' | ' || pg_temp.v0009zh_code(format('select cma.subscriptions_page(null, null, ''none'', ''other'', %L, %L, ''unmapped'', ''device_units'', false)', v_from, v_month));
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['17', 'B8 an agent is refused every read and the file record (CMA06); a bad market, store, proposition, interval, range, measure (null too), sort, direction, page, limit, row count or file part is refused (CMA04); a valid rare combination answers',
      case when v_txt = 'CMA06 CMA06 CMA06 CMA06 | CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 | ok'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9 the file's audit row: the filters, the measure and the rows, never a listed subscription; Customers → Active's card
    --    equals the page's last complete month for a market and for every market
    select count(*) into v_audit from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'subscription_file';
    perform set_config('role', 'cma_app', true);
    perform cma.subscription_file_record('months', v_m1, v_s1, 'vp1', 'monthly', 'total', 12, v_from, v_month);
    v_j := cma.subscriptions_churn_card(v_m1);
    v_j0 := cma.subscriptions_page(v_m1, null, null, null, v_from, v_month);
    v_k := cma.subscriptions_churn_card(null);
    v_txt := ((cma.subscriptions_page(null, null, null, null, v_from, v_month) #> '{tiles,rates}') = v_k)::text;
    perform set_config('role', 'cma_owner', true);
    v_txt := (((select count(*) - v_audit from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'subscription_file') || ' '
               || (select a.new_row::text from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'subscription_file' order by a.changed_at desc, a.id desc limit 1))
              = format('1 {"to": "%s", "from": "%s", "part": "months", "rows": 12, "store": "%s", "market": "%s", "measure": "total", "interval": "monthly", "proposition": "vp1"}', v_month, v_from, v_s1, v_m1))::text
             || ' ' || (v_j = (v_j0 #> '{tiles,rates}'))::text || ' ' || v_txt || ' ' || (v_j is not null)::text;
    v_rows := v_rows || array['18', 'B9 the file''s audit row holds the part, the filters, the range, the measure and the rows only; Customers → Active''s card equals the page''s last complete month, for a market and for every market',
      case when v_txt = 'true true true true' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10 another tenant's application sees none of the take: its own page has no history, the scope is empty
    perform set_config('app.tenant_id', v_inv::text, true);
    perform set_config('role', 'cma_app', true);
    v_txt := (select count(*) from cma.subscriptions_scope_of(v_t, null, null, null, null))::text || ' '
             || (cma.subscriptions_page_of(v_t, null, null, null, null, v_from, v_month, 'total', 'monthly_amount', true, now(), 1) ->> 'history') || ' '
             || coalesce((cma.subscriptions_page_of(v_t, null, null, null, null, v_from, v_month, 'total', 'monthly_amount', true, now(), 1) #>> '{list,total}'), 'none');
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', v_t::text, true);
    v_rows := v_rows || array['19', 'B10 another tenant''s application (row-level security) sees none of the take: an empty scope, no history, no list',
      case when v_txt = '0 false none' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11 the three codes the list reads from the mirror by the take's key: the app's number, the payment instrument and the
    --     CRM contact the CMA matched to the store customer (through the store connection), on the first two pages of every
    --     present subscription
    perform set_config('app.user_id', v_mgr::text, true);
    perform set_config('role', 'cma_app', true);
    v_j := cma.subscription_rows(null, null, null, null, 'all', 'subscription', false, 1, 200, false) -> 'rows';
    v_j0 := cma.subscription_rows(null, null, null, null, 'all', 'subscription', false, 2, 200, false) -> 'rows';
    perform set_config('role', 'cma_owner', true);
    select count(*) filter (where r ->> 'number' is distinct from s.source_number
                               or r ->> 'instrument' is distinct from s.payment_instrument_type
                               or r ->> 'contact_id' is distinct from cc.crm_contact_source_id
                               or r ->> 'store' is distinct from y.handle) || '/' || count(*)
           || '/' || count(cc.crm_contact_source_id)
      into v_txt
    from jsonb_array_elements(v_j || coalesce(v_j0, '[]'::jsonb)) r
    join cma.subscription s on s.tenant_id = v_t and s.id = (r ->> 'subscription_id')::uuid
    left join cma.flash_subscription_stores_of(v_t) y on y.connection_id = s.connection_id
    left join cma.commerce_customer cc on cc.tenant_id = v_t and cc.connection_id = y.store_connection_id and cc.source_id = s.customer_source_id;
    v_rows := v_rows || array['20', 'B11 the list''s number, payment instrument, store and CRM contact equal the mirror''s for its subscriptions (the store customer of the store connection)',
      case when v_txt ~ '^0/[1-9][0-9]*/' and not v_provoke then 'PASS' else 'FAIL' end, 'mismatches/rows/with a contact: ' || v_txt];

    -- B12 the subscription app's own counts beside the tiles (B39b's source figures): two stores' figures of today (one
    --     of them also an older day, which the page leaves out), a third store's of four days ago (out of date: left out);
    --     the sums over the holding statuses and paused, the amounts per currency, the CMA's values beside them and 214's
    --     gap rule; a market filter keeps its stores only; none under a proposition filter; none without any figure
    delete from cma.source_figure x where x.tenant_id = v_t;
    insert into cma.source_figure (tenant_id, connection_id, figure_key, source_metric, business_date, dims, value, unit, currency, cma_value, cma_at, fetched_at)
    select v_t, c.id, k.figure_key, 'verify:zh', v_today - k.back, k.dims, k.value, k.unit, k.currency, k.cma, now(), now()
    from (select y.connection_id as id, row_number() over (order by y.handle collate "C") as n from cma.flash_subscription_stores_of(v_t) y) c
    cross join lateral (values
      ('subscriptions_in_status', 0, '{"status": "active"}'::jsonb, 100.0 * c.n, 'count', null::text, 100.0 * c.n),
      ('subscriptions_in_status', 0, '{"status": "failed"}'::jsonb, 10.0, 'count', null, 30.0),
      ('subscriptions_in_status', 0, '{"status": "paused"}'::jsonb, 5.0, 'count', null, 5.0),
      ('subscriptions_in_status', 0, '{"status": "canceled"}'::jsonb, 50.0, 'count', null, 50.0),
      ('subscriptions_in_status', 1, '{"status": "active"}'::jsonb, 999.0, 'count', null, 999.0),
      ('recurring_amount_active', 0, '{}'::jsonb, 1000.0 * c.n, 'amount', 'EUR', 1000.0 * c.n + 1),
      ('subscriptions_in_status', 4, '{"status": "active"}'::jsonb, 7.0, 'count', null, 7.0)) k(figure_key, back, dims, value, unit, currency, cma)
    where (c.n <= 2 and k.back <= 1) or (c.n = 3 and k.back = 4);
    perform set_config('app.user_id', v_mgr::text, true);
    perform set_config('role', 'cma_app', true);
    v_j := cma.subscriptions_page(null, null, null, null, v_from, v_month) #> '{tiles,source_counts}';
    v_j0 := cma.subscriptions_page(v_m1, null, null, null, v_from, v_month) #> '{tiles,source_counts}';
    v_k := cma.subscriptions_page(null, null, 'vp1', null, v_from, v_month) #> '{tiles,source_counts}';
    perform set_config('role', 'cma_owner', true);
    v_txt := concat_ws(' ', v_j ->> 'stores', v_j ->> 'in_scope', v_j ->> 'to', trim_scale((v_j ->> 'total')::numeric), trim_scale((v_j ->> 'total_cma')::numeric),
                       v_j ->> 'total_gap', trim_scale((v_j ->> 'paused')::numeric), v_j ->> 'paused_gap', trim_scale((v_j #>> '{amounts,0,amount}')::numeric),
                       trim_scale((v_j #>> '{amounts,0,cma}')::numeric), v_j #>> '{amounts,0,gap}', coalesce(v_j0 ->> 'stores', 'none'),
                       coalesce(nullif(v_k::text, 'null'), 'none'));
    -- expected: the holding statuses of the tenant's setting (the dev seed's active,failed: 100 + 200 active and 10 + 10
    -- failed; the CMA 300 + 60, a gap of 40 over 2 and 1 % of 320); paused 10, equal; amounts 3,000 against 3,002 (2 over 2:
    -- no gap); the first market's stores alone under its filter; nothing under a proposition
    v_n := (select count(*) from cma.flash_subscription_stores_of(v_t));
    v_rows := v_rows || array['21', 'B12 the subscription app''s own counts beside the tiles: today''s figures of the stores that have them (an older day and an out-of-date store left out), the sums, the CMA''s values and 214''s gap rule; a market''s stores alone; none under a proposition filter',
      case when v_txt = format('2 %s %s %s %s true 10 false 3000 3002 false %s none', v_n, v_today,
                               case when 'failed' = any (v_holding) then 320 else 300 end, case when 'failed' = any (v_holding) then 360 else 300 end,
                               (select count(*) from (select y.connection_id, row_number() over (order by y.handle collate "C") as n
                                                       from cma.flash_subscription_stores_of(v_t) y) q
                                join cma.flash_subscription_stores_of(v_t) y2 on y2.connection_id = q.connection_id
                                where q.n <= 2 and coalesce(y2.market, 'unknown') = v_m1))
                and 'failed' = any (v_holding) and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  insert into verify_0009zh (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009zh values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helper is dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009zh_code(text);

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009zh
      union all
      select 99, 'verdict',
             case when not current_setting('verify.dev')::boolean then 'REFUSED'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0009zh where result = 'PASS') = 13
                       and not exists (select 1 from verify_0009zh where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('217_verify_subscriptions_page: %s PASS, %s FAIL', (select count(*) from verify_0009zh where result = 'PASS'),
                                                                      (select count(*) from verify_0009zh where result <> 'PASS'))) x
order by ord;
reset role;
