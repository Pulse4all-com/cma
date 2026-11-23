-- =============================================================================================
-- 225_verify_subscription_rates_start.sql: verifies addition 0009zl, the month the Churn rate, the Failed rate and the
-- movements start for every store (subscriptions.rates_start_month)
-- =============================================================================================
-- Block A only reads and runs in every database, prod included: the addition, the setting, the functions' privileges and
-- settings, a store's rate start against 210's (kept below) with each tenant's floor, the facts' inputs key against 210's
-- while the setting is empty, and the stored take against the floor (counts and months only: no id of a customer or a
-- subscription). Block B runs in dev and local databases only, as 211 and 217 (the dev seed's agent.two@example.com
-- active), on the dev seed's tenant Pulse4all Subscriptions inside a subtransaction that is always rolled back; elsewhere
-- it reads REFUSED and the verdict says PASS, A ONLY when block A passes. Every check writes one row, PASS or FAIL, and
-- the last row is the verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login after
-- 224_subscription_rates_start.sql; then the verifies its header names. In prod, run it again after the setting is seeded
-- and the facts computed again: A5 then reads the floor in the stored take.
--   A  A1 the addition after 0009zh; A2 the setting (text, empty by default), the three functions the application's, JIT
--      off where 210 and 216 set it, the floor read in each; A3 every tenant's store starts equal 210's, each the later of
--      210's and the tenant's floor; A4 the inputs key equals 210's for every tenant without the setting; A5 the stored take
--      follows each tenant's floor (no store's start and no complete month before it), or the take is older than the
--      setting (waiting for the facts' next refresh)
--   B  on the dev seed's subscriptions tenant: B1 the setting's form (2026-13, 2026-6, June, 2026-06-01, 1999-12 refused CMA04;
--      empty and 2026-06 taken); B2 with a floor one month after the earliest store's start, computed again: each store's
--      start the later of its own and the floor, no complete month before it, the inputs key changed; B3 the page as the
--      manager: no rate and no movement before the floor, the months from it as before (counts and amounts), its document naming the floor,
--      Customers → Active's card on a month from it; B4 renewal survival and the renewal outcomes as before; the floor
--      emptied again gives 210's starts
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
-- block B in dev or a local database only: the dev seed's agent.two@example.com active, as 211 and 217
select set_config('verify.dev', (select exists (select 1 from cma.app_user u where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false);

drop table if exists pg_temp.verify_0009zl;
create temp table verify_0009zl (ord int, check_name text, result text, detail text);

-- 210's two functions, kept to compare
create or replace function pg_temp.v0009zl_start_old(p_tenant_id uuid, p_now timestamptz)
returns table (connection_id uuid, first_event_month date, migration_months jsonb, last_migration_month date,
               straggler_months jsonb, stragglers integer, rate_start_month date)
language sql stable
rows 50
as $$
  with z as materialized (
    select t.timezone as zone, cma.setting_of(p_tenant_id, 'subscriptions.migration_bulk_min_pct')::numeric as pct
    from cma.tenant t where t.id = p_tenant_id
  ), fe as materialized (
    select e.connection_id, date_trunc('month', min(e.occurred_at) at time zone (select z.zone from z))::date as first_month
    from cma.subscription_event e
    where e.tenant_id = p_tenant_id and e.occurred_at <= p_now
    group by 1
  ), mm as materialized (
    select e.connection_id, date_trunc('month', e.occurred_at at time zone (select z.zone from z))::date as month, count(*) as n
    from cma.subscription_event e
    where e.tenant_id = p_tenant_id and e.event_type = 'migrated' and e.occurred_at <= p_now
    group by 1, 2
  ), mt as (
    select m.connection_id, m.month, m.n, m.n * 100.0 / sum(m.n) over (partition by m.connection_id) >= (select z.pct from z) as bulk
    from mm m
  ), lb as (
    -- the last month holding the share; a store whose migration is spread so thin that no month holds it takes its
    -- busiest month (the latest of equals), so a store with migrated events never starts as one without
    select t.connection_id,
           coalesce(max(t.month) filter (where t.bulk), (array_agg(t.month order by t.n desc, t.month desc))[1]) as last_month
    from mt t group by 1
  )
  select fe.connection_id, fe.first_month,
         coalesce((select jsonb_object_agg(to_char(t.month, 'YYYY-MM'), t.n) from mt t where t.connection_id = fe.connection_id), '{}'),
         lb.last_month,
         coalesce((select jsonb_object_agg(to_char(t.month, 'YYYY-MM'), t.n) from mt t
                   where t.connection_id = fe.connection_id and not t.bulk and t.month > lb.last_month), '{}'),
         coalesce((select sum(t.n) from mt t where t.connection_id = fe.connection_id and not t.bulk and t.month > lb.last_month), 0)::integer,
         (coalesce(lb.last_month, fe.first_month) + interval '1 month')::date
  from fe
  left join lb on lb.connection_id = fe.connection_id
$$;
alter function pg_temp.v0009zl_start_old(uuid, timestamptz) set jit = off;
create or replace function pg_temp.v0009zl_key_old(p_tenant_id uuid, p_today date)
returns text
language sql stable
as $$
  select md5(concat_ws('|',
    array_to_string(cma.inputs_markers_of(p_tenant_id,
      array['subscription', 'subscription_event', 'commerce_order', 'commerce_store', 'device_model', 'market', 'integration_connection',
            'timezone', 'billing_event', 'subscription_line', 'subscription_product_variant', 'subscription_variant_mapping',
            'subscription_change']), '|'),
    cma.setting_of(p_tenant_id, 'flash.ended_subscription_statuses'), cma.setting_of(p_tenant_id, 'flash.device_holding_statuses'),
    cma.setting_of(p_tenant_id, 'subscriptions.propositions'), cma.setting_of(p_tenant_id, 'subscriptions.migration_bulk_min_pct'),
    p_today::text))
$$;

-- A tenant's floor: the first day of its subscriptions.rates_start_month, or null
create or replace function pg_temp.v0009zl_floor(p_tenant_id uuid)
returns date
language sql stable
as $$ select to_date(nullif(cma.setting_of(p_tenant_id, 'subscriptions.rates_start_month'), '') || '-01', 'YYYY-MM-DD') $$;

-- The error a statement raises as its SQLSTATE, or 'ok'
create or replace function pg_temp.v0009zl_state(p_sql text)
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

-- A. Structure, privileges and the stored take
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_txt     text;
  v_bad     text;
  v_now     timestamptz := now();
begin
  perform set_config('jit', 'off', true);
  insert into verify_0009zl values (1, 'A1 addition 0009zl recorded, after 0009zh',
    case when exists (select 1 from cma.schema_migration where version = '0009zl')
              and exists (select 1 from cma.schema_migration where version = '0009zh') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  select string_agg(f, ', ') into v_bad
  from unnest(array['cma.subscription_rate_start_of(uuid,timestamptz)', 'cma.subscription_facts_inputs_key_of(uuid,date)',
                    'cma.subscriptions_page_of(uuid,text,uuid,text,text,date,date,text,text,boolean,timestamptz,integer)']) f
  where to_regprocedure(f) is null or not has_function_privilege('cma_app', f, 'execute') or has_function_privilege('public', f, 'execute');
  select (select s.value_type || ':' || coalesce(s.default_value, 'null') from cma.setting s where s.key = 'subscriptions.rates_start_month')
         || ' ' || (select coalesce(array_to_string(p.proconfig, ','), '-') from pg_proc p where p.oid = 'cma.subscription_rate_start_of(uuid,timestamptz)'::regprocedure)
         || ' ' || (select coalesce(array_to_string(p.proconfig, ','), '-') from pg_proc p where p.oid = 'cma.subscriptions_page_of(uuid,text,uuid,text,text,date,date,text,text,boolean,timestamptz,integer)'::regprocedure)
         || ' ' || (select count(*) from pg_proc p where p.oid in ('cma.subscription_rate_start_of(uuid,timestamptz)'::regprocedure,
                                                                  'cma.subscription_facts_inputs_key_of(uuid,date)'::regprocedure,
                                                                  'cma.subscriptions_page_of(uuid,text,uuid,text,text,date,date,text,text,boolean,timestamptz,integer)'::regprocedure,
                                                                  'cma.check_tenant_setting()'::regprocedure)
                                                   and p.prosrc like '%subscriptions.rates_start_month%')
  into v_txt;
  insert into verify_0009zl values (2, 'A2 the setting (text, empty by default); the three functions the application''s and no one else''s, JIT off on the rate start and the page; the floor read in the four functions',
    case when v_bad is null and v_txt = 'text: jit=off jit=off 4' and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce('not the application''s only: ' || v_bad || '; ', '') || coalesce(v_txt, 'missing'));

  -- A3. a store's start against 210's with the floor, every tenant
  with t as (select x.id from cma.tenant x),
  n as (select t.id as tenant_id, r.* from t cross join lateral cma.subscription_rate_start_of(t.id, v_now) r),
  o0 as (select t.id as tenant_id, r.connection_id, r.first_event_month, r.migration_months, r.last_migration_month, r.straggler_months,
                r.stragglers, greatest(r.rate_start_month, pg_temp.v0009zl_floor(t.id)) as rate_start_month
         from t cross join lateral pg_temp.v0009zl_start_old(t.id, v_now) r),
  -- provoked, one store of 210's side starts a month later, so the comparison itself must find it
  o as (select o0.tenant_id, o0.connection_id, o0.first_event_month, o0.migration_months, o0.last_migration_month, o0.straggler_months,
               o0.stragglers,
               case when v_provoke and (o0.tenant_id, o0.connection_id) = (select x.tenant_id, x.connection_id from o0 x order by x.tenant_id, x.connection_id limit 1)
                    then (o0.rate_start_month + interval '1 month')::date else o0.rate_start_month end as rate_start_month
        from o0),
  d as ((select * from n except all select * from o) union all (select * from o except all select * from n))
  select (select count(*) from n) || ' stores, ' || (select count(*) from d) || ' differ; '
         || (select count(*) from cma.tenant x where pg_temp.v0009zl_floor(x.id) is not null) || ' tenants with a floor'
  into v_txt;
  -- a database with subscription events has stores to compare
  insert into verify_0009zl values (3, 'A3 every tenant''s store starts equal 210''s, each the later of 210''s and the tenant''s floor',
    case when v_txt like '% stores, 0 differ; %'
              and (v_txt not like '0 stores,%' or not exists (select 1 from cma.subscription_event e limit 1)) and not v_provoke then 'PASS' else 'FAIL' end, v_txt);

  -- A4. the inputs key: 210's for every tenant without the setting
  -- provoked, 210's key gains a character, so the comparison itself must find every tenant
  select count(*) || ' tenants without a floor, ' || count(*) filter (where cma.subscription_facts_inputs_key_of(x.id, current_date)
                                                                    is distinct from pg_temp.v0009zl_key_old(x.id, current_date)
                                                                                     || case when v_provoke then 'x' else '' end) || ' with another key'
  into v_txt
  from cma.tenant x where pg_temp.v0009zl_floor(x.id) is null;
  insert into verify_0009zl values (4, 'A4 the facts'' inputs key equals 210''s for every tenant without the setting',
    case when v_txt like '% tenants without a floor, 0 with another key' and not v_provoke then 'PASS' else 'FAIL' end, v_txt);

  -- A5. the stored take follows each tenant's floor, or is older than the setting
  select coalesce(string_agg(z.slug || ' ' || z.fl || ': ' || case when z.waiting then 'waiting for the next refresh'
                                                              else z.starts_before || ' starts and ' || z.complete_before || ' complete rows before it' end,
                             '; ' order by z.slug collate "C"), 'no tenant with a floor')
  into v_txt
  from (select x.slug, to_char(pg_temp.v0009zl_floor(x.id), 'YYYY-MM') as fl,
               coalesce(ts.computed_at < (select s.updated_at from cma.tenant_setting s where s.tenant_id = x.id and s.key = 'subscriptions.rates_start_month'), true) as waiting,
               (select count(*) from cma.subscription_store_start ss where ss.tenant_id = x.id and ss.rate_start_month < pg_temp.v0009zl_floor(x.id)) as starts_before,
               (select count(*) from cma.subscription_month_take mt where mt.tenant_id = x.id and mt.complete and mt.month < pg_temp.v0009zl_floor(x.id)) as complete_before
        from cma.tenant x
        left join cma.subscription_take_state ts on ts.tenant_id = x.id
        where pg_temp.v0009zl_floor(x.id) is not null) z;
  insert into verify_0009zl values (5, 'A5 the stored take follows each tenant''s floor: no store''s start and no complete month before it (or the take is older than the setting)',
    case when v_txt !~ '[1-9][0-9]* (starts|complete)' and v_txt !~ ' [1-9][0-9]* complete' and not v_provoke then 'PASS' else 'FAIL' end, v_txt);
end
$$;

-- B. Behaviour on the dev seed's subscriptions tenant (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_rows    text[] := '{}';
  v_t uuid; v_zone text; v_mgr uuid; v_sch uuid;
  v_month date; v_from date; v_floor date;
  v_key0 text; v_surv0 text; v_out0 text; v_starts0 jsonb; v_months0 jsonb;
  v_j jsonb; v_card jsonb;
  v_txt text;
begin
  if not v_dev then
    insert into verify_0009zl values (59, 'B a dev or local database (the dev seed''s agent.two@example.com active)', 'REFUSED',
      'no dev seed, so this is no dev or local database: block B did not run (block A is the check here)');
    return;
  end if;
  begin
    select t.id, t.timezone into v_t, v_zone from cma.tenant t where t.slug = 'pulse4all-subscriptions';
    perform set_config('app.tenant_id', v_t::text, true);
    select u.id into v_mgr from cma.app_user u join cma.user_role ur on ur.tenant_id = u.tenant_id and ur.user_id = u.id
      join cma.app_role r on r.tenant_id = u.tenant_id and r.id = ur.role_id
      where u.tenant_id = v_t and u.status = 'active' and u.kind = 'person' and r.key = 'manager' order by u.created_at, u.id limit 1;
    select u.id into v_sch from cma.app_user u where u.tenant_id = v_t and u.kind = 'system' and u.email = 'scheduler@system.invalid';
    v_month := date_trunc('month', now() at time zone v_zone)::date;
    v_from := (v_month - interval '23 months')::date;
    delete from cma.tenant_setting s where s.tenant_id = v_t and s.key = 'subscriptions.rates_start_month';

    -- the facts without a floor, as the scheduler
    perform set_config('app.user_id', v_sch::text, true);
    perform set_config('role', 'cma_app', true);
    perform cma.subscription_facts_refresh_of(v_t, true);
    perform set_config('role', 'cma_owner', true);
    v_key0 := cma.subscription_facts_inputs_key_of(v_t, (now() at time zone v_zone)::date);
    select jsonb_object_agg(s.connection_id, s.rate_start_month) into v_starts0 from cma.subscription_store_start s where s.tenant_id = v_t;
    select md5(coalesce(string_agg(concat_ws(':', x.connection_id, x.market, x.cohort_month, x.interval_group, x.renewal_number, x.started, x.eligible, x.survived),
                                   ',' order by x.connection_id, x.market collate "C", x.cohort_month, x.interval_group collate "C", x.renewal_number), ''))
      into v_surv0 from cma.subscription_survival_take x where x.tenant_id = v_t;
    select md5(coalesce(string_agg(x::text, ',' order by x::text collate "C"), '')) into v_out0 from cma.renewal_outcome x where x.tenant_id = v_t;
    perform set_config('app.user_id', v_mgr::text, true);
    perform set_config('role', 'cma_app', true);
    v_months0 := cma.subscriptions_page(null, null, null, null, v_from, v_month) -> 'months';
    perform set_config('role', 'cma_owner', true);

    -- B1. the setting's form
    v_txt := pg_temp.v0009zl_state(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''subscriptions.rates_start_month'', ''2026-13'')', v_t))
             || ' ' || pg_temp.v0009zl_state(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''subscriptions.rates_start_month'', ''2026-6'')', v_t))
             || ' ' || pg_temp.v0009zl_state(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''subscriptions.rates_start_month'', ''June'')', v_t))
             || ' ' || pg_temp.v0009zl_state(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''subscriptions.rates_start_month'', ''2026-06-01'')', v_t))
             || ' ' || pg_temp.v0009zl_state(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''subscriptions.rates_start_month'', ''1999-12'')', v_t))
             || ' ' || pg_temp.v0009zl_state(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''subscriptions.rates_start_month'', '''') on conflict (tenant_id, key) do update set value = excluded.value', v_t))
             || ' ' || pg_temp.v0009zl_state(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''subscriptions.rates_start_month'', ''2026-06'') on conflict (tenant_id, key) do update set value = excluded.value', v_t));
    v_rows := v_rows || array['11', 'B1 the setting''s form: 2026-13, 2026-6, June, 2026-06-01 and 1999-12 refused (CMA04); empty and 2026-06 taken',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 ok ok' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. a floor one month after the earliest store's start, the facts computed again
    v_floor := (select (min(value::date) + interval '1 month')::date from jsonb_each_text(v_starts0));
    update cma.tenant_setting s set value = to_char(v_floor, 'YYYY-MM') where s.tenant_id = v_t and s.key = 'subscriptions.rates_start_month';
    perform set_config('app.user_id', v_sch::text, true);
    perform set_config('role', 'cma_app', true);
    perform cma.subscription_facts_refresh_of(v_t, true);
    perform set_config('role', 'cma_owner', true);
    select count(*) || ' stores, ' || count(*) filter (where s.rate_start_month is distinct from greatest((v_starts0 ->> s.connection_id::text)::date, v_floor))
           || ' off the later of their own and the floor, ' || count(*) filter (where (v_starts0 ->> s.connection_id::text)::date > v_floor) || ' later than it; '
           || (select count(*) from cma.subscription_month_take m where m.tenant_id = v_t and m.complete and m.month < v_floor) || ' complete rows before the floor; key '
           || case when cma.subscription_facts_inputs_key_of(v_t, (now() at time zone v_zone)::date) <> v_key0 then 'changed' else 'unchanged' end
      into v_txt
    from cma.subscription_store_start s where s.tenant_id = v_t;
    v_rows := v_rows || array['12', 'B2 a floor one month after the earliest store''s start: each store''s start the later of its own and the floor, no complete month before it, the inputs key changed',
      case when v_txt ~ '^[1-9][0-9]* stores, 0 off the later of their own and the floor, [0-9]+ later than it; 0 complete rows before the floor; key changed$'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt || ' (floor ' || to_char(v_floor, 'YYYY-MM') || ')'];

    -- B3. the page and Active's card as the manager
    perform set_config('app.user_id', v_mgr::text, true);
    perform set_config('role', 'cma_app', true);
    v_j := cma.subscriptions_page(null, null, null, null, v_from, v_month);
    v_card := cma.subscriptions_churn_card(null);
    perform set_config('role', 'cma_owner', true);
    select (select count(*) from jsonb_array_elements(v_j -> 'rates') r where (r ->> 'month')::date < v_floor) || ' rates before the floor, '
           || (select count(*) from jsonb_array_elements(v_j -> 'months') m where (m ->> 'month')::date < v_floor
                 and (m -> 'counts' is distinct from 'null'::jsonb or m -> 'complete' is distinct from 'null'::jsonb)) || ' months with movements before it, '
           || (select count(*) from jsonb_array_elements(v_j -> 'months') m join jsonb_array_elements(v_months0) m0 on m0 ->> 'month' = m ->> 'month'
               where (m ->> 'month')::date >= v_floor and (m -> 'counts' is distinct from m0 -> 'counts' or m -> 'amounts' is distinct from m0 -> 'amounts'))
           || ' months from it changed; floor '
           || coalesce(v_j ->> 'rates_start_month', 'none') || '; card '
           || case when v_card is null or v_card -> 'month' is null or v_card = 'null'::jsonb then 'none' when (v_card ->> 'month')::date >= v_floor then 'from the floor' else 'before the floor' end
      into v_txt;
    v_rows := v_rows || array['13', 'B3 the page: no rate and no movement before the floor, the movements from it as before, the document naming the floor; Active''s card on a month from it (or none)',
      case when v_txt ~ '^0 rates before the floor, 0 months with movements before it, 0 months from it changed; floor [0-9-]+; card (from the floor|none)$'
                and v_txt like '%floor ' || to_char(v_floor, 'YYYY-MM-DD') || ';%' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. renewal survival and the renewal outcomes as before; the floor emptied gives 210's starts again
    select case when md5(coalesce(string_agg(concat_ws(':', x.connection_id, x.market, x.cohort_month, x.interval_group, x.renewal_number, x.started, x.eligible, x.survived),
                                             ',' order by x.connection_id, x.market collate "C", x.cohort_month, x.interval_group collate "C", x.renewal_number), '')) = v_surv0
                then 'survival same' else 'survival changed' end
      into v_txt from cma.subscription_survival_take x where x.tenant_id = v_t;
    v_txt := v_txt || ', ' || case when (select md5(coalesce(string_agg(x::text, ',' order by x::text collate "C"), '')) from cma.renewal_outcome x where x.tenant_id = v_t) = v_out0
                                   then 'outcomes same' else 'outcomes changed' end;
    update cma.tenant_setting s set value = '' where s.tenant_id = v_t and s.key = 'subscriptions.rates_start_month';
    perform set_config('app.user_id', v_sch::text, true);
    perform set_config('role', 'cma_app', true);
    perform cma.subscription_facts_refresh_of(v_t, true);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || '; emptied: ' || (select count(*) filter (where s.rate_start_month is distinct from (v_starts0 ->> s.connection_id::text)::date)
                                        from cma.subscription_store_start s where s.tenant_id = v_t) || ' starts off 210''s, key '
             || case when cma.subscription_facts_inputs_key_of(v_t, (now() at time zone v_zone)::date) = v_key0 then 'as before' else 'changed' end;
    v_rows := v_rows || array['14', 'B4 renewal survival and the renewal outcomes as before the floor; the floor emptied again gives 210''s starts and key',
      case when v_txt = 'survival same, outcomes same; emptied: 0 starts off 210''s, key as before' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  insert into verify_0009zl (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009zl values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

drop function if exists pg_temp.v0009zl_start_old(uuid, timestamptz);
drop function if exists pg_temp.v0009zl_key_old(uuid, date);
drop function if exists pg_temp.v0009zl_floor(uuid);
drop function if exists pg_temp.v0009zl_state(text);

-- Verdict: one row per check, then the verdict (9 checks in dev; block A's 5 elsewhere)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009zl
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when not current_setting('verify.dev')::boolean then
                    case when (select count(*) from verify_0009zl where result = 'PASS' and ord < 10) = 5
                              and not exists (select 1 from verify_0009zl where result not in ('PASS', 'REFUSED')) then 'PASS, A ONLY' else 'FAIL' end
                  when (select count(*) from verify_0009zl where result = 'PASS') = 9
                       and not exists (select 1 from verify_0009zl where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('225_verify_subscription_rates_start: %s PASS, %s FAIL', (select count(*) from verify_0009zl where result = 'PASS'),
                                                                            (select count(*) from verify_0009zl where result not in ('PASS', 'REFUSED')))) x
order by ord;
reset role;
