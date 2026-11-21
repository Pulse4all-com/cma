-- =============================================================================================
-- 215_verify_source_figures.sql: verifies addition 0009zg, the subscription app's own figures beside the CMA's (brief
-- B39 continued, Part B39b)
-- =============================================================================================
-- Dev and local databases only, as 211: it refuses a database without the dev seed (no active agent.two@example.com):
-- block B's checks then read FAIL and the verdict REFUSED. Block A only reads; block B works on a throwaway tenant inside
-- a subtransaction that is always rolled back, so nothing stays. It writes the scenario's subscriptions, events and runs
-- as the owner, directly, and writes and reads the figures as the tenant's ingest, administrator, agent and scheduler
-- (cma_app, row-level security on). Every check writes one row, PASS or FAIL, and the last row is the verdict, because
-- Cloud SQL Studio shows no notices. Run as your own IAM login after 214_source_figures.sql, in dev; then the verifies
-- 214's header names. Adapters, handles, ids and secret names are invented data values; no row carries a name, an
-- address, an email of a customer or a phone number.
--   A  the addition row after 0009zf; the table's row-level security, grants and no audit trigger; the functions the
--      application's and no one else's, JIT off on the two large reads re-created; the readers' columns (no raw); the
--      figures' catalog, the check's place, sort order and where it is fixed; sync_run's job list
--   B  on a throwaway tenant (Europe/London) with three subscriptions connections, two with a store: the settings'
--      refusals; the write's refusals (an unknown figure, a key outside the list, dims not the figure's, a unit not the
--      figure's, a negative value, a bad date) and who may write (an agent CMA06, another tenant's ingest CMA02); the CMA's
--      value per figure against a hand count (the subscriptions in each status, the monthly amount with Customers →
--      Active's factor, the day's events in the tenant's zone with both of its ends); a later read replacing a value and
--      keeping the first read; an amount of two currencies not compared; the tolerance on both sides of its boundary;
--      the comparison's permission and tenant; the check's listing (the latest date per figure, a flow's latest complete
--      day, the store's market, fixed in subscriptions, the value) and its place in cma.data_quality(); when a day's read
--      is due; the Flash watch's stale check of the job, which the poll of the same connection no longer hides; the runs;
--      another tenant's application sees none of it
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
-- dev or a local database only: the dev seed's agent.two@example.com active, as 203, 205, 207 and 211
select set_config('verify.dev', (select exists (select 1 from cma.app_user u where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false);

drop table if exists pg_temp.verify_0009zg;
create temp table verify_0009zg (ord int, check_name text, result text, detail text);

-- The error a statement raises as its SQLSTATE, or 'ok'
create or replace function pg_temp.v0009zg_code(p_sql text)
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

-- A. Structure and privileges
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_txt     text;
  v_bad     text;
begin
  -- A1. the addition is recorded, after 0009zf
  insert into verify_0009zg values (1, 'A1 addition 0009zg recorded, after 0009zf',
    case when exists (select 1 from cma.schema_migration where version = '0009zg')
              and exists (select 1 from cma.schema_migration where version = '0009zf') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the table: row-level security on, the application's grants, no audit trigger, its unique key
  select c.relrowsecurity || ':' || has_table_privilege('cma_app', c.oid, 'select') || has_table_privilege('cma_app', c.oid, 'insert')
         || has_table_privilege('cma_app', c.oid, 'update') || ':' || exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'audit')
         || ':' || (select string_agg(a.attname, ',' order by k.o) from pg_constraint x
                    cross join lateral unnest(x.conkey) with ordinality k(n, o)
                    join pg_attribute a on a.attrelid = c.oid and a.attnum = k.n
                    where x.conrelid = c.oid and x.contype = 'u' and array_length(x.conkey, 1) = 5)
  into v_txt
  from pg_class c where c.oid = 'cma.source_figure'::regclass;
  insert into verify_0009zg values (2, 'A2 cma.source_figure: row-level security on, the application''s grants, no audit trigger, unique per tenant, connection, figure, date and dims',
    case when v_txt = 'true:truetruetrue:false:tenant_id,connection_id,figure_key,business_date,dims' and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce(v_txt, 'missing'));

  -- A3. every new function the application's, none public's; JIT off on the two large reads re-created
  select string_agg(f, ', ') into v_bad
  from unnest(array['cma.source_figure_keys()', 'cma.source_figure_dims_ok(text,jsonb)', 'cma.ingest_upsert_source_figures(uuid,uuid,jsonb)',
    'cma.source_figure_rows_of(uuid,date,date)', 'cma.source_figure_compare_of(uuid,date)', 'cma.source_figures_due_of(uuid)']) f
  where to_regprocedure(f) is null or not has_function_privilege('cma_app', f, 'execute') or has_function_privilege('public', f, 'execute');
  v_txt := (select string_agg(coalesce(array_to_string(p.proconfig, ','), '-'), ' ' order by p.proname collate "C") from pg_proc p
            where p.oid in ('cma.data_quality_of(uuid)'::regprocedure, 'cma.flash_watch_of(uuid,date,timestamptz)'::regprocedure));
  insert into verify_0009zg values (3, 'A3 the six functions the application''s and no one else''s; JIT off on cma.data_quality_of and cma.flash_watch_of',
    case when v_bad is null and v_txt = 'jit=off jit=off' and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce('not the application''s only: ' || v_bad || '; ', '') || coalesce(v_txt, 'missing'));

  -- A4. the readers' columns (raw left out); sync_run takes the job source_figures
  v_txt := (select string_agg(a.attname, ',' order by a.attnum) from pg_attribute a
            where a.attrelid = 'cma_read.source_figure'::regclass and a.attnum > 0 and not a.attisdropped)
           || ' | ' || (select string_agg(a.attname, ',' order by a.attnum) from pg_attribute a
                        where a.attrelid = 'cma_read.dq_source_figure_gap'::regclass and a.attnum > 0 and not a.attisdropped)
           || ' | ' || (select (pg_get_constraintdef(x.oid) like '%''source_figures''%')::text from pg_constraint x
                        where x.conrelid = 'cma.sync_run'::regclass and x.conname = 'sync_run_job_check');
  insert into verify_0009zg values (4, 'A4 the readers: cma_read.source_figure without raw, cma_read.dq_source_figure_gap; sync_run takes the job source_figures',
    case when v_txt = 'tenant_id,connection_id,figure_key,source_metric,business_date,dims,value,unit,currency,cma_value,cma_at,fetched_at,run_id | tenant_id,connection_id,object_type,object_id,value | true'
              and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'missing'));

  -- A5. the figures' catalog; the check after subscription_device_units_mismatch, fixed in subscriptions
  v_txt := (select string_agg(k.figure_key || ':' || k.kind || ':' || k.unit || ':' || array_to_string(k.dims, '+') || ':' || k.compared,
                              ' ' order by k.sort_order) from cma.source_figure_keys() k)
           || ' | ' || (select string_agg(c.check_key || ':' || c.sort_order, ' ' order by c.sort_order) from cma.data_quality_flash_checks() c
                        where c.sort_order >= 390)
           || ' | ' || cma.data_quality_fix_in('source_figure_gap', null) || ' ' || cma.data_quality_fix_in('subscription_variant_unmapped', null);
  insert into verify_0009zg values (5, 'A5 the seven figures with their kind, unit, dims and comparison; source_figure_gap at 400, fixed in subscriptions (the variant check still the CMA''s)',
    case when v_txt = 'subscriptions_in_status:stock:count:status:true recurring_amount_active:stock:amount::true renewals:flow:count::true transitions_to_churn:flow:count:status:true purchases:flow:count::true pauses:flow:count::true renewal_survival:cohort:count:cohort_start+period:false | subscription_device_units_mismatch:390 source_figure_gap:400 | subscriptions cma'
              and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'missing'));
end
$$;

-- B. Behaviour on a throwaway tenant (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_rows    text[] := '{}';
  v_t uuid; v_adm uuid; v_agent uuid; v_sch uuid; v_ing uuid; v_other uuid; v_oing uuid;
  v_shop_a uuid; v_sub_a uuid; v_shop_b uuid; v_sub_b uuid; v_sub_c uuid; v_run uuid;
  v_today date := (now() at time zone 'Europe/London')::date;
  v_d date := (now() at time zone 'Europe/London')::date - 1;
  v_d0 timestamptz := ((now() at time zone 'Europe/London')::date - 1)::timestamp at time zone 'Europe/London';
  v_items jsonb;
  v_txt text; v_j jsonb;
begin
  if not v_dev then
    insert into verify_0009zg values (59, 'B a dev or local database (the dev seed''s agent.two@example.com active)', 'FAIL',
      'REFUSED: no dev seed, so this is no dev or local database; nothing ran');
    return;
  end if;
  begin
    v_t := cma.create_tenant('verify-0009zg', 'Verify 0009zg', 'Europe/London');
    perform set_config('app.tenant_id', v_t::text, true);
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest' and x.external_id = 'ingest';
    select u.id into v_sch from cma.app_user u where u.tenant_id = v_t and u.kind = 'system' and u.email = 'scheduler@system.invalid';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify.zg.admin@example.invalid', 'Verify admin') returning id into v_adm;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_adm, r.id from cma.app_role r where r.tenant_id = v_t and r.key = 'admin';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify.zg.agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_agent, r.id from cma.app_role r where r.tenant_id = v_t and r.key = 'agent';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t, 'verifyshop', 'Verify shop A', 'verify-zg-a.shop.example', 'commerce', 'verify-zg-shop-1') returning id into v_shop_a;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifysubs', 'Verify subscriptions A', 'verify-zg-a.shop.example', 'subscriptions', 'verify-zg-key-1') returning id into v_sub_a;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t, 'verifyshop', 'Verify shop B', 'verify-zg-b.shop.example', 'commerce', 'verify-zg-shop-2') returning id into v_shop_b;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifysubs', 'Verify subscriptions B', 'verify-zg-b.shop.example', 'subscriptions', 'verify-zg-key-2') returning id into v_sub_b;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifysubs', 'Verify subscriptions C', 'verify-zg-c.shop.example', 'subscriptions', 'verify-zg-key-3') returning id into v_sub_c;
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency)
    values (v_t, 'GB', 'Verify GB', 'Europe/London', 'en', 'GBP'), (v_t, 'DK', 'Verify DK', 'Europe/London', 'da', 'DKK') on conflict do nothing;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
    values (v_t, v_shop_a, 'verify-zg-a', 'Verify store A', 'GB', 'GBP', 'Europe/London'),
           (v_t, v_shop_b, 'verify-zg-b', 'Verify store B', 'DK', 'DKK', 'Europe/London');

    -- B1. the settings: the tolerance in percent 0 to 100, in units 0 to 1,000,000, the local time 00:00 to 23:59
    v_txt := pg_temp.v0009zg_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''source_figures.tolerance_pct'', ''101'')', v_t))
             || ' ' || pg_temp.v0009zg_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''source_figures.tolerance_pct'', ''-1'')', v_t))
             || ' ' || pg_temp.v0009zg_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''source_figures.tolerance_min'', ''1000001'')', v_t))
             || ' ' || pg_temp.v0009zg_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''source_figures.local_time'', ''24:00'')', v_t))
             || ' ' || pg_temp.v0009zg_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''source_figures.local_time'', ''5am'')', v_t))
             || ' | ' || cma.setting_of(v_t, 'source_figures.tolerance_pct') || ' ' || cma.setting_of(v_t, 'source_figures.tolerance_min')
             || ' ' || cma.setting_of(v_t, 'source_figures.local_time');
    v_rows := v_rows || array['11', 'B1 the settings refuse a share above 100 or below 0, a minimum above 1,000,000, 24:00 and a time out of its form (CMA04); the defaults 1, 2 and 05:00',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 | 1 2 05:00' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- store A (GBP): active a1 to a4 monthly at 30, a5 yearly at 120 (10 a month), a6 active but deleted at the source;
    -- p1, p2 paused; f1 failed; c1 canceled
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                  billing_interval_count, amount_per_cycle, currency, source_created_at, source_updated_at, source_deleted_at)
    select v_t, v_sub_a, 'verifysubs', x.id, 'c-' || x.id, x.status, x.iv, 1, x.amount, 'GBP', v_d0 - interval '100 days', v_d0 - interval '100 days',
           case when x.id = 'a6' then v_d0 end
    from (values ('a1', 'active', 'month', 30), ('a2', 'active', 'month', 30), ('a3', 'active', 'month', 30), ('a4', 'active', 'month', 30),
                 ('a5', 'active', 'year', 120), ('a6', 'active', 'month', 30), ('p1', 'paused', 'month', 30), ('p2', 'paused', 'month', 30),
                 ('f1', 'failed', 'month', 30), ('c1', 'canceled', 'month', 30)) x(id, status, iv, amount);
    -- the day's events (D, yesterday in London): three renewals, a fourth a second before D and a fifth at D + 1 00:00
    -- (both left out); two purchases; a pause and a status change into paused; a cancel; a status change into failed
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, status_from, status_to)
    values (v_t, v_sub_a, 'verifysubs', 'r1', 'a1', 'renewed', v_d0, null, null),
           (v_t, v_sub_a, 'verifysubs', 'r2', 'a2', 'renewed', v_d0 + interval '12 hours', null, null),
           (v_t, v_sub_a, 'verifysubs', 'r3', 'a3', 'renewed', v_d0 + interval '1 day' - interval '1 second', null, null),
           (v_t, v_sub_a, 'verifysubs', 'r4', 'a4', 'renewed', v_d0 - interval '1 second', null, null),
           (v_t, v_sub_a, 'verifysubs', 'r5', 'a5', 'renewed', v_d0 + interval '1 day', null, null),
           (v_t, v_sub_a, 'verifysubs', 'u1', 'a1', 'purchased', v_d0 + interval '1 hour', null, null),
           (v_t, v_sub_a, 'verifysubs', 'u2', 'a2', 'purchased', v_d0 + interval '2 hours', null, null),
           (v_t, v_sub_a, 'verifysubs', 'z1', 'p1', 'paused', v_d0 + interval '3 hours', 'active', 'paused'),
           (v_t, v_sub_a, 'verifysubs', 'z2', 'p2', 'status_changed', v_d0 + interval '4 hours', 'active', 'paused'),
           (v_t, v_sub_a, 'verifysubs', 'x1', 'c1', 'canceled', v_d0 + interval '5 hours', 'active', 'canceled'),
           (v_t, v_sub_a, 'verifysubs', 'x2', 'f1', 'status_changed', v_d0 + interval '6 hours', 'active', 'failed');
    -- store B: active subscriptions in two currencies; connection C: none
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                  billing_interval_count, amount_per_cycle, currency, source_created_at, source_updated_at)
    values (v_t, v_sub_b, 'verifysubs', 'b1', 'c-b1', 'active', 'month', 1, 100, 'DKK', v_d0 - interval '50 days', v_d0 - interval '50 days'),
           (v_t, v_sub_b, 'verifysubs', 'b2', 'c-b2', 'active', 'month', 1, 20, 'EUR', v_d0 - interval '50 days', v_d0 - interval '50 days');

    -- B2. the write's refusals as the ingest, then who may write
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_ing::text, true);
    v_txt := pg_temp.v0009zg_code(format($q$select cma.ingest_upsert_source_figures(%L, null, '[{"figureKey": "mrr", "sourceMetric": "x", "businessDate": "2026-11-20", "dims": {}, "value": 1, "unit": "count"}]')$q$, v_sub_a))
      || ' ' || pg_temp.v0009zg_code(format($q$select cma.ingest_upsert_source_figures(%L, null, '[{"figureKey": "renewals", "sourceMetric": "x", "businessDate": "2026-11-20", "dims": {}, "value": 1, "unit": "count", "email": "a@b"}]')$q$, v_sub_a))
      || ' ' || pg_temp.v0009zg_code(format($q$select cma.ingest_upsert_source_figures(%L, null, '[{"figureKey": "subscriptions_in_status", "sourceMetric": "x", "businessDate": "2026-11-20", "dims": {"status": "gone"}, "value": 1, "unit": "count"}]')$q$, v_sub_a))
      || ' ' || pg_temp.v0009zg_code(format($q$select cma.ingest_upsert_source_figures(%L, null, '[{"figureKey": "renewals", "sourceMetric": "x", "businessDate": "2026-11-20", "dims": {"customer": "c1"}, "value": 1, "unit": "count"}]')$q$, v_sub_a))
      || ' ' || pg_temp.v0009zg_code(format($q$select cma.ingest_upsert_source_figures(%L, null, '[{"figureKey": "renewals", "sourceMetric": "x", "businessDate": "2026-11-20", "dims": {}, "value": 1, "unit": "amount"}]')$q$, v_sub_a))
      || ' ' || pg_temp.v0009zg_code(format($q$select cma.ingest_upsert_source_figures(%L, null, '[{"figureKey": "renewals", "sourceMetric": "x", "businessDate": "2026-11-20", "dims": {}, "value": -1, "unit": "count"}]')$q$, v_sub_a))
      || ' ' || pg_temp.v0009zg_code(format($q$select cma.ingest_upsert_source_figures(%L, null, '[{"figureKey": "renewals", "sourceMetric": "x", "businessDate": "2026-02-30", "dims": {}, "value": 1, "unit": "count"}]')$q$, v_sub_a))
      || ' ' || pg_temp.v0009zg_code(format($q$select cma.ingest_upsert_source_figures(%L, null, '[{"figureKey": "renewal_survival", "sourceMetric": "x", "businessDate": "2026-11-01", "dims": {"cohort_start": "2026-08-15", "period": 1}, "value": 1, "unit": "count"}]')$q$, v_sub_a));
    perform set_config('app.user_id', v_agent::text, true);
    v_txt := v_txt || ' | ' || pg_temp.v0009zg_code(format($q$select cma.ingest_upsert_source_figures(%L, null, '[]')$q$, v_sub_a));
    perform set_config('app.user_id', v_ing::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0009zg_code(format($q$select cma.ingest_upsert_source_figures(%L, null, '[]')$q$, v_shop_a))
             || ' ' || pg_temp.v0009zg_code(format('select * from cma.source_figures_due_of(%L)', v_shop_a))
             || ' ' || (select count(*) from cma.source_figure f where f.tenant_id = v_t)::text;
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['12', 'B2 the write refuses an unknown figure, a key outside the list, a status and a dims key not the figure''s, a unit not its own, a negative value, an impossible date and a cohort not on a month''s first day (CMA04); an agent may not write (CMA06); a connection that is no subscriptions connection is refused by the write and the due check (CMA02); nothing written',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 | CMA06 CMA02 CMA02 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. the CMA's value per figure, against a hand count: active 5 (a6 deleted at the source left out), paused 2, failed
    --     1, canceled 1; 4 × 30 + 120 / 12 = 130.00 GBP a month; on D renewals 3 (its two ends: 00:00 in, 24:00 out),
    --     purchases 2, pauses 2 (any event into paused), into canceled 1, failed 1, expired 0; survival none
    v_items := jsonb_build_array(
      jsonb_build_object('figureKey', 'subscriptions_in_status', 'sourceMetric', 'subscriptions:count', 'businessDate', v_today, 'dims', jsonb_build_object('status', 'active'), 'value', 5, 'unit', 'count'),
      jsonb_build_object('figureKey', 'subscriptions_in_status', 'sourceMetric', 'subscriptions:count', 'businessDate', v_today, 'dims', jsonb_build_object('status', 'paused'), 'value', 2, 'unit', 'count'),
      jsonb_build_object('figureKey', 'subscriptions_in_status', 'sourceMetric', 'subscriptions:count', 'businessDate', v_today, 'dims', jsonb_build_object('status', 'failed'), 'value', 1, 'unit', 'count'),
      jsonb_build_object('figureKey', 'subscriptions_in_status', 'sourceMetric', 'subscriptions:count', 'businessDate', v_today, 'dims', jsonb_build_object('status', 'canceled'), 'value', 9, 'unit', 'count'),
      jsonb_build_object('figureKey', 'recurring_amount_active', 'sourceMetric', 'subscriptions:current-mrr', 'businessDate', v_today, 'dims', '{}'::jsonb, 'value', 130.004, 'unit', 'amount'),
      jsonb_build_object('figureKey', 'renewals', 'sourceMetric', 'subscriptions:renewed', 'businessDate', v_d, 'dims', '{}'::jsonb, 'value', 3, 'unit', 'count'),
      jsonb_build_object('figureKey', 'purchases', 'sourceMetric', 'subscriptions:purchased', 'businessDate', v_d, 'dims', '{}'::jsonb, 'value', 2, 'unit', 'count'),
      jsonb_build_object('figureKey', 'pauses', 'sourceMetric', 'subscriptions:pauses', 'businessDate', v_d, 'dims', '{}'::jsonb, 'value', 2, 'unit', 'count'),
      jsonb_build_object('figureKey', 'transitions_to_churn', 'sourceMetric', 'subscriptions:churned', 'businessDate', v_d, 'dims', jsonb_build_object('status', 'canceled'), 'value', 1, 'unit', 'count'),
      jsonb_build_object('figureKey', 'transitions_to_churn', 'sourceMetric', 'subscriptions:churned', 'businessDate', v_d, 'dims', jsonb_build_object('status', 'failed'), 'value', 1, 'unit', 'count'),
      jsonb_build_object('figureKey', 'transitions_to_churn', 'sourceMetric', 'subscriptions:churned', 'businessDate', v_d, 'dims', jsonb_build_object('status', 'expired'), 'value', 0, 'unit', 'count'),
      jsonb_build_object('figureKey', 'renewal_survival', 'sourceMetric', 'subscriptions:purchased', 'businessDate', date_trunc('month', v_today)::date, 'dims', jsonb_build_object('cohort_start', to_char(date_trunc('month', v_today) - interval '2 months', 'YYYY-MM-DD'), 'period', 2), 'value', 40, 'unit', 'count'));
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_ing::text, true);
    v_run := cma.ingest_sync_run_start(v_sub_a, 'source_figures', 'source_figure', null, now());
    v_j := cma.ingest_upsert_source_figures(v_sub_a, v_run, v_items);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_j::text || ' | ' || (select string_agg(f.figure_key || coalesce(':' || (f.dims ->> 'status'), '') || '=' || coalesce(f.cma_value::text, 'null')
                                                      || coalesce(':' || f.currency, ''), ' ' order by f.figure_key collate "C", f.dims::text collate "C")
                                    from cma.source_figure f where f.tenant_id = v_t and f.connection_id = v_sub_a)
             || ' | ' || (select count(*) from cma.source_figure f where f.tenant_id = v_t and f.run_id = v_run and f.cma_at is not null)::text
             || ' ' || (select f.value::text from cma.source_figure f where f.tenant_id = v_t and f.figure_key = 'recurring_amount_active');
    v_rows := v_rows || array['13', 'B3 the CMA''s value per figure against a hand count (statuses now, the monthly amount with the month factor, the day''s events in the tenant''s zone, both ends), survival not compared; the run named, the amount rounded to cents',
      case when v_txt = '{"updated": 0, "inserted": 12, "unchanged": 0} | pauses=2.00 purchases=2.00 recurring_amount_active=130.00:GBP renewal_survival=null renewals=3.00 subscriptions_in_status:active=5.00 subscriptions_in_status:canceled=1.00 subscriptions_in_status:failed=1.00 subscriptions_in_status:paused=2.00 transitions_to_churn:canceled=1.00 transitions_to_churn:expired=0.00 transitions_to_churn:failed=1.00 | 11 130.00'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. a later read replaces a value and keeps the first read: renewals given twice in one call, 9 then 4 (the later
    --     one wins), the rest unchanged
    update cma.source_figure f set raw = jsonb_build_object('first_fetched_at', '2026-01-01T00:00:00Z', 'fetches', 1)
    where f.tenant_id = v_t and f.figure_key = 'renewals';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_ing::text, true);
    v_j := cma.ingest_upsert_source_figures(v_sub_a, v_run,
             jsonb_set(v_items, '{5,value}', '9'::jsonb) || jsonb_build_array(jsonb_set(v_items -> 5, '{value}', '4'::jsonb)));
    perform set_config('role', 'cma_owner', true);
    v_txt := v_j::text || ' | ' || (select f.value || ' ' || (f.raw ->> 'first_fetched_at') || ' ' || (f.raw ->> 'fetches') from cma.source_figure f
                                    where f.tenant_id = v_t and f.figure_key = 'renewals')
             || ' | ' || (select count(*) from cma.source_figure f where f.tenant_id = v_t)::text;
    v_rows := v_rows || array['14', 'B4 a later read replaces a value (one key given twice in a call: the later value wins, counted once) and keeps the first read in raw; the others unchanged',
      case when v_txt = '{"updated": 1, "inserted": 0, "unchanged": 11} | 4.00 2026-01-01T00:00:00Z 2 | 12' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. an amount in two currencies is stored without a currency and not compared; none active is 0 without one
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_source_figures(v_sub_b, null, jsonb_build_array(v_items -> 4));
    perform cma.ingest_upsert_source_figures(v_sub_c, null, jsonb_build_array(jsonb_set(v_items -> 4, '{value}', '0'::jsonb)));
    perform set_config('role', 'cma_owner', true);
    v_txt := (select string_agg(coalesce(f.currency, '-') || ':' || coalesce(f.cma_value::text, 'null') || ':' || r.state, ' ' order by r.store collate "C" nulls last)
              from cma.source_figure f
              join cma.source_figure_rows_of(v_t, v_today, v_today) r on r.connection_id = f.connection_id and r.figure_key = f.figure_key
              where f.tenant_id = v_t and f.figure_key = 'recurring_amount_active' and f.connection_id in (v_sub_b, v_sub_c));
    v_rows := v_rows || array['15', 'B5 an amount whose active subscriptions hold two currencies: no currency, no CMA value, not compared; a connection without active subscriptions: 0 without a currency',
      case when v_txt = '-:null:not_compared -:0.00:within' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. the tolerance on both sides of its boundary (1 % and 2, both exceeded): 100 against 102 within (2 is not above
    --     2), 103 a gap; 1,000 against 1,010 within (1 % is not above 1 %), 1,011 a gap; 0 against 3 a gap; canceled 9
    --     against 1 a gap
    insert into cma.source_figure (tenant_id, connection_id, figure_key, source_metric, business_date, dims, value, unit, cma_value, cma_at)
    values (v_t, v_sub_c, 'purchases', 'x', v_d - 1, '{}', 100, 'count', 102, now()),
           (v_t, v_sub_c, 'purchases', 'x', v_d - 2, '{}', 100, 'count', 103, now()),
           (v_t, v_sub_c, 'purchases', 'x', v_d - 3, '{}', 1000, 'count', 1010, now()),
           (v_t, v_sub_c, 'purchases', 'x', v_d - 4, '{}', 1000, 'count', 1011, now()),
           (v_t, v_sub_c, 'purchases', 'x', v_d - 5, '{}', 0, 'count', 3, now());
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_adm::text, true);
    v_txt := (select string_agg(r.gap || ':' || coalesce(r.gap_pct::text, '-') || ':' || r.state, ' ' order by r.business_date desc)
              from generate_series(1, 5) n
              cross join lateral cma.source_figure_compare_of(v_t, v_d - n) r where r.connection_id = v_sub_c)
             || ' | ' || (select string_agg(r.figure_key || coalesce(':' || (r.dims ->> 'status'), '') || ':' || r.state || ':' || coalesce(r.store, '-') || ':' || coalesce(r.market, '-'), ' '
                                            order by k.sort_order, r.dims::text collate "C")
                          from cma.source_figure_compare_of(v_t, v_today) r join cma.source_figure_keys() k on k.figure_key = r.figure_key
                          where r.connection_id = v_sub_a);
    v_rows := v_rows || array['16', 'B6 the tolerance: a gap of 2 on 100 and of 1 % on 1,000 within, 3 on 100, 11 on 1,000 and 3 on 0 a gap; the day''s comparison in the catalog''s order with its store and market',
      case when v_txt = '2.00:2.00:within 3.00:3.00:gap 10.00:1.00:within 11.00:1.10:gap 3.00:-:gap | subscriptions_in_status:active:within:verify-zg-a:GB subscriptions_in_status:canceled:gap:verify-zg-a:GB subscriptions_in_status:failed:within:verify-zg-a:GB subscriptions_in_status:paused:within:verify-zg-a:GB recurring_amount_active:within:verify-zg-a:GB'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. the comparison's permission and tenant: an agent CMA06, another tenant CMA06
    perform set_config('app.user_id', v_agent::text, true);
    v_txt := pg_temp.v0009zg_code(format('select * from cma.source_figure_compare_of(%L, %L)', v_t, v_today));
    perform set_config('app.user_id', v_adm::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0009zg_code(format('select * from cma.source_figure_compare_of(%L, %L)', gen_random_uuid(), v_today))
             || ' ' || pg_temp.v0009zg_code(format('select * from cma.source_figure_compare_of(%L, null)', v_t));
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['17', 'B7 the comparison: an agent may not read it, nor anyone another tenant''s or no date (CMA06)',
      case when v_txt = 'CMA06 CMA06 CMA06' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. the check: per figure and dims the latest date read (a flow's latest complete day): store A's canceled count
    --     (9 against 1, today) is listed with its market and fixed in subscriptions; connection C's purchases are not:
    --     their latest complete day, D - 1, is within the tolerance, and today's gap is not read (today is not
    --     complete); store A's renewals neither: D - 1 is a gap, but D, the latest complete day, is within
    insert into cma.source_figure (tenant_id, connection_id, figure_key, source_metric, business_date, dims, value, unit, cma_value, cma_at)
    values (v_t, v_sub_c, 'purchases', 'x', v_today, '{}', 100, 'count', 500, now()),
           (v_t, v_sub_a, 'renewals', 'x', v_d - 1, '{}', 100, 'count', 500, now());
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_sch::text, true);
    v_txt := (select string_agg(x.check_key || ':' || x.object_type || ':' || x.object_id || ':' || x.value || ':' || x.market || ':' || x.fix_in
                                || ':' || coalesce(x.fix_adapter, '-'), ' ' order by x.object_id collate "C")
              from cma.flash_findings_compute_of(v_t) x where x.check_key = 'source_figure_gap');
    perform set_config('app.user_id', v_adm::text, true);
    v_txt := v_txt || ' | ' || (select string_agg(q.check_key || ':' || q.total, ' ') from cma.data_quality() q where q.check_key = 'source_figure_gap');
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['18', 'B8 the check lists the latest date per figure and dims when over the tolerance (a stock''s today, a flow''s latest complete day), with the store''s market, fixed in subscriptions; Data quality counts it',
      case when v_txt = format('source_figure_gap:source_figure:subscriptions_in_status:canceled:%s source 9 cma 1:GB:subscriptions:verifysubs | source_figure_gap:1', v_today)
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. when a day's read is due: from source_figures.local_time in the tenant's zone, until a run of the job started
    --     after it has succeeded (a failed one leaves it due); the dates yesterday and today in London
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'source_figures.local_time', '00:00');
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_ing::text, true);
    v_txt := (select d.due || ':' || (d.today = v_today) || ':' || (d.yesterday = v_d) || ':' || d.timezone from cma.source_figures_due_of(v_sub_b) d);
    perform set_config('role', 'cma_owner', true);
    insert into cma.sync_run (tenant_id, connection_id, job, stream, status, started_at, finished_at)
    values (v_t, v_sub_b, 'source_figures', 'source_figure', 'failed', now(), now());
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' ' || (select d.due::text from cma.source_figures_due_of(v_sub_b) d);
    perform set_config('role', 'cma_owner', true);
    insert into cma.sync_run (tenant_id, connection_id, job, stream, status, started_at, finished_at)
    values (v_t, v_sub_b, 'source_figures', 'source_figure', 'succeeded', now(), now());
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' ' || (select d.due::text from cma.source_figures_due_of(v_sub_b) d);
    perform set_config('app.user_id', v_agent::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0009zg_code(format('select * from cma.source_figures_due_of(%L)', v_sub_b));
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['19', 'B9 a day''s read is due after the local time until a run started after it succeeded (a failed one leaves it due); the dates in the tenant''s zone; an agent may not ask (CMA06)',
      case when v_txt = 'true:true:true:Europe/London true false CMA06' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. the Flash watch: connection A polls every five minutes (two runs a minute and six minutes ago) and read its
    --      figures six and five days ago (a day apart): the poll is fresh, the figures job stale (7,200 minutes against
    --      one and a half days), so one source_stale finding of the source source_figures for store A
    insert into cma.sync_run (tenant_id, connection_id, job, stream, status, started_at, finished_at)
    values (v_t, v_sub_a, 'subscriptions_poll', 'subscriptions', 'succeeded', now() - interval '6 minutes', now() - interval '6 minutes'),
           (v_t, v_sub_a, 'subscriptions_poll', 'subscriptions', 'succeeded', now() - interval '1 minute', now() - interval '1 minute'),
           (v_t, v_sub_a, 'source_figures', 'source_figure', 'succeeded', now() - interval '6 days', now() - interval '6 days'),
           (v_t, v_sub_a, 'source_figures', 'source_figure', 'succeeded', now() - interval '5 days', now() - interval '5 days');
    -- as the snapshot take runs it: the owner's function, under the scheduler (flash.snapshot)
    perform set_config('app.user_id', v_sch::text, true);
    perform cma.flash_watch_of(v_t, v_today, now());
    v_txt := (select string_agg(f.dims::text || ':' || f.value || '/' || f.threshold || ':' || (f.detail ->> 'job'), ' ' order by f.dims::text collate "C")
              from cma.flash_watch_finding f where f.tenant_id = v_t and f.kind = 'source_stale');
    v_rows := v_rows || array['20', 'B10 the Flash watch: the figures job stale on its own (source source_figures, 7,200 minutes against one and a half cadences, 2,160) beside a fresh poll of the same connection',
      case when v_txt = '{"store": "verify-zg-a", "source": "source_figures", "adapter": "verifysubs"}:7200/2160:source_figures' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. the runs: the job's run finishes with the counts the job writes; another tenant's application sees no figure
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_sync_run_finish(v_run, 'succeeded', '{"fetched": 12, "inserted": 12, "updated": 0, "unchanged": 0, "skipped": 1}'::jsonb, null);
    perform set_config('role', 'cma_owner', true);
    v_txt := (select r.job || ':' || r.stream || ':' || r.status || ':' || (r.counts ->> 'skipped') from cma.sync_run r where r.id = v_run);
    select t.id into v_other from cma.tenant t where t.id <> v_t order by t.created_at limit 1;
    select x.user_id into v_oing from cma.app_user_external_id x where x.tenant_id = v_other and x.system = 'ingest' and x.external_id = 'ingest';
    perform set_config('app.tenant_id', v_other::text, true);
    perform set_config('app.user_id', v_oing::text, true);
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' ' || (select count(*) from cma.source_figure f where f.tenant_id = v_t)::text
             || ' ' || pg_temp.v0009zg_code(format($q$select cma.ingest_upsert_source_figures(%L, null, '[]')$q$, v_sub_a));
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', v_t::text, true);
    v_rows := v_rows || array['21', 'B11 the job''s run finishes with its counts; another tenant''s application sees no figure and cannot write to this tenant''s connection (CMA02)',
      case when v_txt = 'source_figures:source_figure:succeeded:1 0 CMA02' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  insert into verify_0009zg (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009zg values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helper is dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009zg_code(text);

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009zg
      union all
      select 99, 'verdict',
             case when not current_setting('verify.dev')::boolean then 'REFUSED'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0009zg where result = 'PASS') = 16
                       and not exists (select 1 from verify_0009zg where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('215_verify_source_figures: %s PASS, %s FAIL', (select count(*) from verify_0009zg where result = 'PASS'),
                                                                    (select count(*) from verify_0009zg where result <> 'PASS'))) x
order by ord;
reset role;
