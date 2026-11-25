-- =============================================================================================
-- 251_verify_payments_page.sql: verifies addition 0009zy, Customers → Payments (250_payments_page.sql)
-- =============================================================================================
-- Block A only reads and runs in every database (prod included). Block B runs in dev and local databases only, as 217:
-- it refuses a database without the dev seed (no active agent.two@example.com), its checks then read FAIL and the
-- verdict REFUSED. Block B works on the dev seed's tenant Pulse4all Subscriptions inside a subtransaction that is always
-- rolled back, so nothing stays: it computes the subscription facts as the tenant's scheduler when no take is stored yet,
-- gives some of the take's rows each payment state with a since, an overdue flag, a return code and an amount at risk
-- as the owner (the seed's subscriptions are all paid or ended), and reads the page as the seed's manager (cma_app,
-- row-level security on). Every check writes one row, PASS or FAIL, and the last row is the verdict, because Cloud SQL
-- Studio shows no notices. Run as your own IAM login after 250_payments_page.sql: in dev normal (13 PASS, verdict PASS),
-- then provoked (every row FAIL, verdict PROVOKED, NOT A PASS); in prod the whole script, where block B refuses prod's
-- data (its row reads REFUSED) and the verdict says PASS, A ONLY when block A passes. No row carries a name, an address,
-- an email or a phone number.
--   A  the addition row after 0009zv; the six functions the application's (not public's), invoker's rights, JIT off
--   B  for every filter (none, each market, each store, a proposition, none, each interval group, a market with an
--      interval): the tiles per payment state, the overdue and the amount at risk per currency against the take; the
--      base the five states alone (Paused and Canceled left out); the cross table's sums against the tiles and its
--      instruments against the mirror; the Failed rate's parts (tiles, months, rates, stores' starts and the floor)
--      equal to Customers → Subscriptions' for the same market and store, without a floor of the rates and again with
--      one inside the range (subscriptions.rates_start_month, as prod holds it); the list's totals per state against the
--      tiles, its pages walked whole under two sorts in their order, the file's rows; the refusals (CMA06 for an agent,
--      CMA04 for every bad filter, state, sort, page and file record); the file's audit row without an id; another
--      tenant's application (row-level security) sees none of the take; a tenant without the take is history false and
--      nothing more
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
-- dev or a local database only for block B: the dev seed's agent.two@example.com active, as 217
select set_config('verify.dev', (select exists (select 1 from cma.app_user u where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false);

drop table if exists pg_temp.verify_0009zy;
create temp table verify_0009zy (ord int, check_name text, result text, detail text);

-- The error a statement raises as its SQLSTATE, or 'ok'
create or replace function pg_temp.v0009zy_code(p_sql text)
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
            where n.nspname = 'cma' and p.proname in ('assert_payment_list', 'payment_rows_of', 'payments_page_of', 'payments_page',
                                                      'payment_rows', 'payment_file_record'))
           || ' | ' || coalesce((select (m.applied_at >= p.applied_at)::text from cma.schema_migration m, cma.schema_migration p
                                 where m.version = '0009zy' and p.version = '0009zv'), 'missing');
  insert into verify_0009zy values (1, 'A1 0009zy recorded after 0009zv; the six functions executable by cma_app and not by public, with the caller''s rights and JIT off',
    case when v_txt = 'assert_payment_list:true:false:false:true payment_file_record:true:false:false:true payment_rows:true:false:false:true '
                      || 'payment_rows_of:true:false:false:true payments_page:true:false:false:true payments_page_of:true:false:false:true | true'
              and not v_provoke then 'PASS' else 'FAIL' end, v_txt);
end
$$;

-- B. The page against the takes, on the dev seed's tenant (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_rows    text[] := '{}';
  v_states  text[] := array['paid', 'in_retry', 'charged_back', 'awaiting_payment', 'failed'];
  v_t uuid; v_inv uuid; v_mgr uuid; v_agent uuid; v_sch uuid;
  v_zone text; v_month date; v_from date;
  v_f record; v_j jsonb; v_s jsonb; v_k jsonb;
  v_bad text := ''; v_bad2 text := ''; v_bad3 text := ''; v_bad4 text := ''; v_bad5 text := '';
  v_txt text; v_n integer; v_page integer; v_seen uuid[]; v_prev text; v_cur text;
  v_m1 text; v_s1 uuid; v_audit bigint; v_st text; v_sort text;
begin
  if not v_dev then
    insert into verify_0009zy values (59, 'B a dev or local database (the dev seed''s agent.two@example.com active)', 'REFUSED',
      'no dev seed, so this is no dev or local database; block B did not run');
    return;
  end if;
  begin
    select t.id, t.timezone into v_t, v_zone from cma.tenant t where t.slug = 'pulse4all-subscriptions';
    select t.id into v_inv from cma.tenant t where t.slug = 'pulse4all-invest';
    perform set_config('app.tenant_id', v_t::text, true);
    -- no floor of the rates in this block (subscriptions.rates_start_month, 0009zl; rolled back with it), as 217's block B
    delete from cma.tenant_setting s where s.tenant_id = v_t and s.key = 'subscriptions.rates_start_month';
    select u.id into v_mgr from cma.app_user u join cma.user_role ur on ur.tenant_id = u.tenant_id and ur.user_id = u.id
      join cma.app_role r on r.tenant_id = u.tenant_id and r.id = ur.role_id
      where u.tenant_id = v_t and u.status = 'active' and u.kind = 'person' and r.key = 'manager' order by u.created_at, u.id limit 1;
    select u.id into v_agent from cma.app_user u where u.tenant_id = v_t and u.email = 'agent.two@example.com';
    select u.id into v_sch from cma.app_user u where u.tenant_id = v_t and u.kind = 'system' and u.email = 'scheduler@system.invalid';
    v_month := date_trunc('month', now() at time zone v_zone)::date;
    v_from := (v_month - interval '23 months')::date;

    -- the facts, computed as the scheduler when the tenant has no take yet (a take the minute job stored is read as it is)
    if not exists (select 1 from cma.subscription_take_state s where s.tenant_id = v_t) then
      perform set_config('app.user_id', v_sch::text, true);
      perform set_config('role', 'cma_app', true);
      perform cma.subscription_facts_refresh_of(v_t, true);
      perform set_config('role', 'cma_owner', true);
    end if;
    -- every payment state on some of the take's rows, with its since, overdue, return code and amount at risk (the
    -- seed's subscriptions are paid or ended), and propositions for the proposition filter
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'subscriptions.propositions', 'vp1,vp2')
      on conflict (tenant_id, key) do update set value = excluded.value;
    update cma.subscription_take x
    set payment_state = case when x.status = 'active' then case z.r % 6 when 1 then 'in_retry' when 2 then 'charged_back' when 3 then 'awaiting_payment'
                                                                       when 4 then 'awaiting_payment' else 'paid' end
                             else x.payment_state end,
        state_since = now() - make_interval(days => (z.r % 40)::integer),
        overdue = case when x.status = 'active' and z.r % 6 = 4 then true when x.status = 'active' and z.r % 6 = 3 then false else null end,
        chargeback_return_code = case when x.status = 'active' and z.r % 6 = 2 then 'MD06' when x.status = 'failed' and z.r % 2 = 0 then 'AM04' end,
        currency = coalesce(x.currency, case when z.r % 5 = 0 then 'GBP' else 'EUR' end),
        amount_at_risk = case when (x.status = 'active' and z.r % 6 in (1, 2, 4)) or x.status = 'failed' then 10 + (z.r % 7) * 2.5 end,
        propositions = case when z.r % 5 = 0 then array['vp1', 'vp2'] when z.r % 3 = 0 then array['vp1'] else '{}' end
    from (select t.subscription_id, row_number() over (order by t.source_id collate "C", t.subscription_id) as r
          from cma.subscription_take t where t.tenant_id = v_t) z
    where x.tenant_id = v_t and x.subscription_id = z.subscription_id;
    -- at least one failed subscription: the take's first active row becomes failed when the seed has none
    if not exists (select 1 from cma.subscription_take t where t.tenant_id = v_t and t.payment_state = 'failed') then
      update cma.subscription_take x set status = 'failed', payment_state = 'failed', amount_at_risk = 12.5, chargeback_return_code = 'AM04'
      where x.tenant_id = v_t and x.subscription_id = (select t.subscription_id from cma.subscription_take t where t.tenant_id = v_t and t.status = 'active'
                                                       order by t.source_id collate "C", t.subscription_id limit 1);
    end if;
    select min(t.market collate "C") into v_m1 from cma.subscription_take t where t.tenant_id = v_t;
    select y.connection_id into v_s1 from cma.flash_subscription_stores_of(v_t) y order by y.handle collate "C" limit 1;

    create temp table if not exists v0009zy_filters (n integer, market text, store uuid, proposition text, interval_group text) on commit drop;
    delete from v0009zy_filters;
    insert into v0009zy_filters values (1, null, null, null, null);
    insert into v0009zy_filters select 10 + row_number() over (order by m collate "C"), m, null, null, null
      from (select distinct t.market as m from cma.subscription_take t where t.tenant_id = v_t) d;
    insert into v0009zy_filters select 20 + row_number() over (order by y.handle collate "C"), null, y.connection_id, null, null
      from cma.flash_subscription_stores_of(v_t) y;
    insert into v0009zy_filters values (31, null, null, 'vp1', null), (33, null, null, 'none', null),
      (41, null, null, null, 'monthly'), (42, null, null, null, 'yearly'), (51, v_m1, null, null, 'monthly');

    for v_f in select * from v0009zy_filters order by n loop
      perform set_config('app.user_id', v_mgr::text, true);
      perform set_config('role', 'cma_app', true);
      v_j := cma.payments_page(v_f.market, v_f.store, v_f.proposition, v_f.interval_group, v_from, v_month);
      v_s := cma.subscriptions_page(v_f.market, v_f.store, null, null, v_from, v_month);
      perform set_config('role', 'cma_owner', true);

      -- B1 the tiles against the take: the base the five states, per state, the overdue, the amount at risk per currency
      with t as (select x.* from cma.subscription_take x where x.tenant_id = v_t
                   and (v_f.market is null or x.market = v_f.market) and (v_f.store is null or x.connection_id = v_f.store)
                   and (v_f.proposition is null or (v_f.proposition = 'none' and x.propositions = '{}') or v_f.proposition = any (x.propositions))
                   and (v_f.interval_group is null or x.interval_group = v_f.interval_group)
                   and x.payment_state = any (v_states))
      select concat_ws(';',
               case when (v_j #>> '{tiles,total}')::bigint is distinct from (select count(*) from t) then 'total' end,
               case when (select string_agg((b ->> 'key') || '=' || (b ->> 'subscriptions'), ',' order by o) from jsonb_array_elements(v_j #> '{tiles,by_state}') with ordinality e(b, o))
                         is distinct from (select string_agg(k || '=' || (select count(*) from t where t.payment_state = k), ',' order by o) from unnest(v_states) with ordinality u(k, o))
                    then 'by_state' end,
               case when (v_j #>> '{tiles,overdue}')::bigint is distinct from (select count(*) from t where t.payment_state = 'awaiting_payment' and t.overdue) then 'overdue' end,
               case when (v_j #>> '{tiles,at_risk,subscriptions}')::bigint is distinct from (select count(*) from t where t.amount_at_risk is not null) then 'at_risk' end,
               case when (select string_agg((a ->> 'currency') || '=' || (a ->> 'amount')::numeric || '/' || (a ->> 'subscriptions'), ',' order by a ->> 'currency' collate "C")
                          from jsonb_array_elements(v_j #> '{tiles,at_risk,amounts}') a)
                         is distinct from (select string_agg(c || '=' || s || '/' || n, ',' order by c collate "C")
                                           from (select t.currency as c, round(sum(t.amount_at_risk), 2) as s, count(*) as n from t
                                                 where t.amount_at_risk is not null and t.currency is not null group by 1) z)
                    then 'amounts' end)
      into v_txt;
      if v_txt <> '' then v_bad := v_bad || v_f.n || ':' || v_txt || ' '; end if;

      -- B2 the cross table: its sums per state equal the tiles, its instruments the mirror's
      select concat_ws(';',
               case when (select coalesce(sum((c ->> 'subscriptions')::bigint), 0) from jsonb_array_elements(v_j -> 'cross') c) <> (v_j #>> '{tiles,total}')::bigint then 'sum' end,
               case when exists (select 1 from jsonb_array_elements(v_j #> '{tiles,by_state}') b
                                 where (b ->> 'subscriptions')::bigint <> (select coalesce(sum((c ->> 'subscriptions')::bigint), 0) from jsonb_array_elements(v_j -> 'cross') c
                                                                            where c ->> 'state' = b ->> 'key')) then 'per_state' end,
               case when (select string_agg((c ->> 'state') || '/' || (c ->> 'instrument') || '=' || (c ->> 'subscriptions'), ',' order by c ->> 'state' collate "C", c ->> 'instrument' collate "C")
                          from jsonb_array_elements(v_j -> 'cross') c)
                         is distinct from
                         (select string_agg(st || '/' || ins || '=' || n, ',' order by st collate "C", ins collate "C")
                          from (select x.payment_state as st, coalesce(s.payment_instrument_type, 'unknown') as ins, count(*) as n
                                from cma.subscription_take x
                                left join cma.subscription s on s.tenant_id = v_t and s.id = x.subscription_id and s.source_deleted_at is null
                                where x.tenant_id = v_t and x.payment_state = any (v_states)
                                  and (v_f.market is null or x.market = v_f.market) and (v_f.store is null or x.connection_id = v_f.store)
                                  and (v_f.proposition is null or (v_f.proposition = 'none' and x.propositions = '{}') or v_f.proposition = any (x.propositions))
                                  and (v_f.interval_group is null or x.interval_group = v_f.interval_group)
                                group by 1, 2) z)
                    then 'instruments' end)
      into v_txt;
      if v_txt <> '' then v_bad2 := v_bad2 || v_f.n || ':' || v_txt || ' '; end if;

      -- B3 the Failed rate's parts equal Customers → Subscriptions' for the same market and store
      select concat_ws(';',
               case when (v_j #>> '{tiles,rates,month}') is distinct from (v_s #>> '{tiles,rates,month}')
                         or (v_j #>> '{tiles,rates,base}') is distinct from (v_s #>> '{tiles,rates,base}')
                         or (v_j #>> '{tiles,rates,moved_to_failed}') is distinct from (v_s #>> '{tiles,rates,moved_to_failed}') then 'tile' end,
               case when (select string_agg((r ->> 'market') || (r ->> 'month') || ':' || coalesce(r ->> 'base', '-') || '/' || (r ->> 'moved_to_failed'), ',' order by r ->> 'market' collate "C", r ->> 'month' collate "C")
                          from jsonb_array_elements(v_j -> 'rates') r)
                         is distinct from
                         (select string_agg((r ->> 'market') || (r ->> 'month') || ':' || coalesce(r ->> 'base', '-') || '/' || (r ->> 'moved_to_failed'), ',' order by r ->> 'market' collate "C", r ->> 'month' collate "C")
                          from jsonb_array_elements(v_s -> 'rates') r) then 'rates' end,
               case when (select string_agg(m ->> 'month' || ':' || coalesce(m #>> '{complete,base}', '-') || '/' || coalesce(m #>> '{complete,moved_to_failed}', '-'), ',' order by m ->> 'month' collate "C")
                          from jsonb_array_elements(v_j -> 'months') m)
                         is distinct from
                         (select string_agg(m ->> 'month' || ':' || coalesce(m #>> '{complete,base}', '-') || '/' || coalesce(m #>> '{complete,moved_to_failed}', '-'), ',' order by m ->> 'month' collate "C")
                          from jsonb_array_elements(v_s -> 'months') m) then 'months' end,
               case when (v_j -> 'store_starts') is distinct from (v_s -> 'store_starts') or (v_j -> 'rates_start_month') is distinct from (v_s -> 'rates_start_month') then 'starts' end)
      into v_txt;
      if v_txt <> '' then v_bad3 := v_bad3 || v_f.n || ':' || v_txt || ' '; end if;

      -- B4 the list's totals per state against the tiles
      perform set_config('role', 'cma_app', true);
      select concat_ws(';',
               case when (cma.payment_rows(v_f.market, v_f.store, v_f.proposition, v_f.interval_group, 'at_risk', 'amount_at_risk', true, 1, 50, false) ->> 'total')::bigint
                         is distinct from (v_j #>> '{tiles,at_risk,subscriptions}')::bigint then 'at_risk' end,
               case when (cma.payment_rows(v_f.market, v_f.store, v_f.proposition, v_f.interval_group, 'all', 'amount_at_risk', true, 1, 50, false) ->> 'total')::bigint
                         is distinct from (v_j #>> '{tiles,total}')::bigint then 'all' end,
               (select string_agg(b ->> 'key', ',' order by b ->> 'key' collate "C") from jsonb_array_elements(v_j #> '{tiles,by_state}') b
                where (cma.payment_rows(v_f.market, v_f.store, v_f.proposition, v_f.interval_group, b ->> 'key', 'subscription', false, 1, 50, false) ->> 'total')::bigint
                      <> (b ->> 'subscriptions')::bigint),
               case when (v_j #>> '{list,total}')::bigint is distinct from (v_j #>> '{tiles,at_risk,subscriptions}')::bigint then 'first_page' end)
      into v_txt;
      perform set_config('role', 'cma_owner', true);
      if v_txt <> '' then v_bad4 := v_bad4 || v_f.n || ':' || v_txt || ' '; end if;
    end loop;

    v_rows := v_rows || array['2', 'B1 the tiles against the take for every filter: the five payment states'' subscriptions, the per-state counts with zeros, the overdue Awaiting payment, the amount at risk per currency with its subscriptions',
      case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(nullif(v_bad, ''), 'every filter as the take')];
    v_rows := v_rows || array['3', 'B2 the cross table: its sums equal the tiles in total and per state, and each instrument is the mirror''s (unknown where none)',
      case when v_bad2 = '' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(nullif(v_bad2, ''), 'every filter as the take and the mirror')];
    v_rows := v_rows || array['4', 'B3 the Failed rate''s parts (the tile''s last complete month, the rates per market and month, the months, the stores'' starts and the floor) equal Customers → Subscriptions'' for the same market and store',
      case when v_bad3 = '' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(nullif(v_bad3, ''), 'every filter equal')];
    -- B3b the same comparison with a floor of the rates inside the range (subscriptions.rates_start_month, as prod holds
    --     one; rolled back with the block): 250's floor branches against 224's, for no filter and each market
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'subscriptions.rates_start_month', to_char(v_from + interval '6 months', 'YYYY-MM'))
      on conflict (tenant_id, key) do update set value = excluded.value;
    v_bad5 := '';
    for v_f in select * from v0009zy_filters where n < 20 order by n loop
      perform set_config('app.user_id', v_mgr::text, true);
      perform set_config('role', 'cma_app', true);
      v_j := cma.payments_page(v_f.market, v_f.store, null, null, v_from, v_month);
      v_s := cma.subscriptions_page(v_f.market, v_f.store, null, null, v_from, v_month);
      perform set_config('role', 'cma_owner', true);
      if (v_j #> '{tiles,rates}') is distinct from (select case when v_s #> '{tiles,rates}' = 'null'::jsonb then 'null'::jsonb
                                                               else (v_s #> '{tiles,rates}') - 'churned' end)
         or (select jsonb_agg(r - 'churned' order by r ->> 'market' collate "C", r ->> 'month' collate "C") from jsonb_array_elements(v_s -> 'rates') r)
            is distinct from (select jsonb_agg(r order by r ->> 'market' collate "C", r ->> 'month' collate "C") from jsonb_array_elements(v_j -> 'rates') r)
         or (select jsonb_agg(jsonb_build_object('month', m -> 'month', 'complete', case when m -> 'complete' = 'null'::jsonb then 'null'::jsonb else (m -> 'complete') - 'churned' end)
                              order by m ->> 'month' collate "C") from jsonb_array_elements(v_s -> 'months') m)
            is distinct from (select jsonb_agg(m order by m ->> 'month' collate "C") from jsonb_array_elements(v_j -> 'months') m)
         or (v_j -> 'rates_start_month') is distinct from (v_s -> 'rates_start_month') or v_j ->> 'rates_start_month' is null then
        v_bad5 := v_bad5 || v_f.n || ' ';
      end if;
    end loop;
    delete from cma.tenant_setting s where s.tenant_id = v_t and s.key = 'subscriptions.rates_start_month';
    v_rows := v_rows || array['13', 'B3b with a floor of the rates inside the range: the Failed rate''s parts, the rates, the months and the floor equal Customers → Subscriptions'' for no filter and each market',
      case when v_bad5 = '' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(nullif(v_bad5, ''), 'every filter equal with the floor')];

    v_rows := v_rows || array['5', 'B4 the list''s totals: at_risk the amount at risk''s subscriptions, all the tiles'' total, each state its tile, the page''s first page the at-risk list',
      case when v_bad4 = '' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(nullif(v_bad4, ''), 'every filter as the tiles')];

    -- B5 Paused and Canceled are not on the page: the take holds some, and none is counted or listed
    perform set_config('role', 'cma_app', true);
    v_j := cma.payments_page(null, null, null, null, v_from, v_month);
    v_k := cma.payment_rows(null, null, null, null, 'all', 'subscription', false, 1, 200, true);
    perform set_config('role', 'cma_owner', true);
    v_txt := concat_ws(' ', ((select count(*) from cma.subscription_take t where t.tenant_id = v_t and t.payment_state in ('paused', 'canceled')) > 0)::text,
                       (select count(*) from jsonb_array_elements(v_k -> 'rows') r where r ->> 'payment_state' not in ('paid', 'in_retry', 'charged_back', 'awaiting_payment', 'failed')),
                       (select count(*) from jsonb_array_elements(v_j -> 'cross') c where c ->> 'state' not in ('paid', 'in_retry', 'charged_back', 'awaiting_payment', 'failed')),
                       (jsonb_array_length(v_k -> 'rows') = (v_k ->> 'total')::integer)::text);
    v_rows := v_rows || array['6', 'B5 Paused and Canceled are not on the page (the take holds some): no file row and no cross cell outside the five states, and the file holds every row',
      case when v_txt = 'true 0 0 true' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6 the list's pages walked whole under two sorts: no row twice, every row once, each page in its sort's order
    v_bad5 := '';
    foreach v_sort in array array['amount_at_risk', 'state_since'] loop
      v_seen := '{}'; v_page := 1; v_prev := null;
      perform set_config('role', 'cma_app', true);
      v_n := (cma.payment_rows(null, null, null, null, 'all', v_sort, true, 1, 7, false) ->> 'total')::integer;
      loop
        v_k := cma.payment_rows(null, null, null, null, 'all', v_sort, true, v_page, 7, false);
        exit when jsonb_array_length(v_k -> 'rows') = 0 or v_page > 500;
        for v_j in select r from jsonb_array_elements(v_k -> 'rows') r loop
          if (v_j ->> 'subscription_id')::uuid = any (v_seen) then v_bad5 := v_bad5 || v_sort || ':twice '; end if;
          v_seen := v_seen || (v_j ->> 'subscription_id')::uuid;
          -- the sort's key: an amount within its currency (descending: the currency first), else the since
          v_cur := case v_sort when 'amount_at_risk' then coalesce(v_j ->> 'currency', '') || '|' || to_char(coalesce((v_j ->> 'amount_at_risk')::numeric, -1) + 1000000, 'FM0000000000.00')
                               else coalesce(to_char((v_j ->> 'state_since')::timestamptz at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), '0000') end;
          if v_prev is not null and (v_cur collate "C") > (v_prev collate "C") then v_bad5 := v_bad5 || v_sort || ':order '; end if;
          v_prev := v_cur;
        end loop;
        v_page := v_page + 1;
      end loop;
      perform set_config('role', 'cma_owner', true);
      if cardinality(v_seen) <> v_n then v_bad5 := v_bad5 || v_sort || ':' || cardinality(v_seen) || '/' || v_n || ' '; end if;
    end loop;
    v_rows := v_rows || array['7', 'B6 the list''s pages walked whole under amount_at_risk and state_since (descending, 7 a page): every row once, none twice, each in its sort''s order',
      case when v_bad5 = '' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(nullif(v_bad5, ''), 'both sorts whole')];

    -- B7 a row's codes: the instrument and number are the mirror's, the take's since, overdue, return code and amount
    perform set_config('role', 'cma_app', true);
    v_k := cma.payment_rows(null, null, null, null, 'all', 'subscription', false, 1, 200, true);
    perform set_config('role', 'cma_owner', true);
    v_n := (select count(*) from jsonb_array_elements(v_k -> 'rows') r
            join cma.subscription_take x on x.tenant_id = v_t and x.subscription_id = (r ->> 'subscription_id')::uuid
            left join cma.subscription s on s.tenant_id = v_t and s.id = x.subscription_id
            where (r ->> 'instrument') is distinct from s.payment_instrument_type or (r ->> 'number') is distinct from s.source_number
               or (r ->> 'return_code') is distinct from x.chargeback_return_code or ((r ->> 'overdue')::boolean) is distinct from x.overdue
               or ((r ->> 'amount_at_risk')::numeric) is distinct from round(x.amount_at_risk, 2)
               or ((r ->> 'state_since')::timestamptz) is distinct from x.state_since
               or (r ->> 'payment_state') is distinct from x.payment_state or (r ->> 'contact_url') is not null
               or (r ->> 'contact_id') is distinct from (select cc.crm_contact_source_id from cma.flash_subscription_stores_of(v_t) y
                                                         join cma.commerce_customer cc on cc.tenant_id = v_t and cc.connection_id = y.store_connection_id
                                                                                      and cc.source_id = s.customer_source_id
                                                         where y.connection_id = x.connection_id));
    v_rows := v_rows || array['8', 'B7 each file row''s codes: the instrument, number and CRM contact id the mirror''s; the state, since, overdue, return code and amount at risk the take''s; no link in a file row',
      case when v_n = 0 and jsonb_array_length(v_k -> 'rows') > 0 and not v_provoke then 'PASS' else 'FAIL' end,
      v_n || ' rows differ of ' || jsonb_array_length(v_k -> 'rows')];

    -- B8 the refusals: an agent CMA06; every bad filter, state, sort, page and file record CMA04
    perform set_config('app.user_id', v_agent::text, true);
    perform set_config('role', 'cma_app', true);
    v_txt := pg_temp.v0009zy_code(format('select cma.payments_page(null, null, null, null, %L, %L)', v_from, v_month))
             || ' ' || pg_temp.v0009zy_code('select cma.payment_rows(null, null, null, null, ''at_risk'', ''amount_at_risk'', true, 1, 50, false)')
             || ' ' || pg_temp.v0009zy_code('select cma.payment_file_record(''records'', null, null, null, null, ''at_risk'', 3)');
    perform set_config('app.user_id', v_mgr::text, true);
    v_txt := v_txt || ' | ' || (select string_agg(pg_temp.v0009zy_code(q), ' ' order by o) from unnest(array[
           format('select cma.payments_page(''gb'', null, null, null, %L, %L)', v_from, v_month),
           format('select cma.payments_page(null, %L, null, null, %L, %L)', gen_random_uuid(), v_from, v_month),
           format('select cma.payments_page(null, null, ''vp9'', null, %L, %L)', v_from, v_month),
           format('select cma.payments_page(null, null, null, ''weekly'', %L, %L)', v_from, v_month),
           format('select cma.payments_page(null, null, null, null, %L, %L)', v_month, v_from),
           format('select cma.payments_page(null, null, null, null, %L, %L, ''paused'')', v_from, v_month),
           format('select cma.payments_page(null, null, null, null, %L, %L, ''at_risk'', ''monthly_amount'')', v_from, v_month),
           format('select cma.payments_page(null, null, null, null, %L, %L, ''at_risk'', ''amount_at_risk'', null)', v_from, v_month),
           format('select cma.payments_page(null, null, null, null, %L, %L, ''at_risk'', ''amount_at_risk'', true, 0)', v_from, v_month),
           'select cma.payment_rows(null, null, null, null, ''at_risk'', ''amount_at_risk'', true, 1, 500, false)',
           'select cma.payment_rows(null, null, null, null, ''canceled'', ''amount_at_risk'', true, 1, 50, false)',
           'select cma.payment_file_record(''list'', null, null, null, null, ''at_risk'', 3)',
           'select cma.payment_file_record(''records'', null, null, null, null, ''paused'', 3)',
           'select cma.payment_file_record(''records'', null, null, null, null, ''at_risk'', -1)',
           format('select cma.payment_file_record(''records'', null, null, null, null, ''at_risk'', 3, %L, %L)', v_from, v_month)]) with ordinality u(q, o));
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['9', 'B8 the refusals: an agent CMA06 on the page, the list and the file record; CMA04 for a bad market, store, proposition, interval, range, state, sort, direction, page, limit, part, rows and a range on records',
      case when v_txt = 'CMA06 CMA06 CMA06 | CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9 the file's audit row: who, part, filters, state, range and rows; never an id of a listed subscription
    select count(*) into v_audit from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'payment_file';
    perform set_config('role', 'cma_app', true);
    perform cma.payment_file_record('months', v_m1, v_s1, 'vp1', 'monthly', 'at_risk', 12, v_from, v_month);
    perform set_config('role', 'cma_owner', true);
    v_txt := ((select count(*) - v_audit from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'payment_file') || ' '
              || (select (a.actor_user_id = v_mgr)::text || ' ' || a.new_row::text from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'payment_file'
                  order by a.changed_at desc, a.id desc limit 1));
    v_rows := v_rows || array['10', 'B9 the file''s audit row: one row naming the manager, the part, the filters, the state, the range and the rows, no subscription''s id',
      case when v_txt = format('1 true {"to": "%s", "from": "%s", "part": "months", "rows": 12, "state": "at_risk", "store": "%s", "market": "%s", "interval": "monthly", "proposition": "vp1"}',
                               v_month, v_from, v_s1, v_m1)
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10 another tenant's application (row-level security) sees none of the take: the page's read of this tenant under
    --     the other tenant's setting has no history, and its list is empty
    perform set_config('app.tenant_id', v_inv::text, true);
    perform set_config('role', 'cma_app', true);
    v_j := cma.payments_page_of(v_t, null, null, null, null, v_from, v_month, 'all', 'subscription', true, now(), 1);
    v_k := cma.payment_rows_of(v_t, null, null, null, null, 'all', 'subscription', true, 1, 200, true);
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', v_t::text, true);
    v_txt := concat_ws(' ', v_j ->> 'history', coalesce(v_j #>> '{tiles,total}', 'none'), v_k ->> 'total', jsonb_array_length(v_k -> 'rows'));
    v_rows := v_rows || array['11', 'B10 another tenant''s application (row-level security) sees none of the take: no history, no tiles, an empty list',
      case when v_txt = 'false none 0 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11 without a stored take: history false, no tiles, no cross, no list, the months empty
    delete from cma.subscription_take_state s where s.tenant_id = v_t;
    perform set_config('app.user_id', v_mgr::text, true);
    perform set_config('role', 'cma_app', true);
    v_j := cma.payments_page(null, null, null, null, v_from, v_month);
    v_k := cma.payment_rows(null, null, null, null, 'all', 'subscription', false, 1, 50, false);
    perform set_config('role', 'cma_owner', true);
    v_txt := concat_ws(' ', v_j ->> 'set_up', v_j ->> 'history', v_j -> 'tiles', v_j -> 'cross', v_j -> 'list', jsonb_array_length(v_j -> 'months'), v_k ->> 'history');
    v_rows := v_rows || array['12', 'B11 a tenant without a stored take: set up, history false, no tiles, cross or list, no months; the list''s read history false',
      case when v_txt = 'true false null null null 0 false' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  insert into verify_0009zy (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009zy values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helper is dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009zy_code(text);

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009zy
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when not current_setting('verify.dev')::boolean then
                    case when (select count(*) from verify_0009zy where result = 'PASS' and ord < 2) = 1
                              and not exists (select 1 from verify_0009zy where result not in ('PASS', 'REFUSED')) then 'PASS, A ONLY' else 'FAIL' end
                  when (select count(*) from verify_0009zy where result = 'PASS') = 13
                       and not exists (select 1 from verify_0009zy where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('251_verify_payments_page: %s PASS, %s FAIL', (select count(*) from verify_0009zy where result = 'PASS'),
                                                                 (select count(*) from verify_0009zy where result not in ('PASS', 'REFUSED')))) x
order by ord;
reset role;
