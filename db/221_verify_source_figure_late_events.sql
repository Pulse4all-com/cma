-- =============================================================================================
-- 221_verify_source_figure_late_events.sql: verifies addition 0009zj, a source figure's CMA value counting the events
-- the CMA stored after the value was first taken
-- =============================================================================================
-- Block A only reads and runs in every database, prod included: the addition, the write's privileges and settings, and
-- every stored exits and pauses row's CMA value against the rule (counts only: no id of a customer or a subscription).
-- Block B runs in dev and local databases only, as 215 and 219 (the dev seed's agent.two@example.com active), on a
-- throwaway tenant inside a subtransaction that is always rolled back, so nothing stays; elsewhere it reads REFUSED and the
-- verdict says PASS, A ONLY when block A passes. Every check writes one row, PASS or FAIL, and the last row is the verdict,
-- because Cloud SQL Studio shows no notices. Run as your own IAM login after 220_source_figure_late_events.sql; then 215
-- and 219.
--   A  A1 the addition after 0009zi; A2 the write the application's and no one else's, its JIT off, 218's counts kept
--      and the late days counted again among the events held now; A3 every stored exits and pauses row's CMA value equals
--      the rule's count of the events the CMA held when it was taken (as 219's A3); A4 no stored exits and pauses row lags
--      the events the CMA holds now (true right after 220 and after each store's write; a sync between two writes may
--      add a lagging day until the next write, so run it right after 220)
--   B  on a throwaway tenant (Europe/London), two subscriptions connections, the stored rows of three past days taken two
--      hours ago (cma_at), then today's write as the ingest:
--      B1 a day with status events stored after its row was taken (one cancellation reported twice, stored half an hour
--         ago) is counted again (1 to 2, the double report once) and its cma_at moves to now; a day whose event was stored
--         before its row was taken keeps its value and cma_at; the answer names the one row counted again
--      B2 a late event of the other connection moves none of this connection's rows; a first write (no earlier row) and a
--         second write once the late days are taken answer with the three counts alone
--      B3 a late event's subscription's next status event, on a later day, is counted again too (a cancellation stored
--         late on D-6 makes the report into canceled on D-5 no move)
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
-- block B in dev or a local database only: the dev seed's agent.two@example.com active, as 211, 215 and 219
select set_config('verify.dev', (select exists (select 1 from cma.app_user u where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false);

drop table if exists pg_temp.verify_0009zj;
create temp table verify_0009zj (ord int, check_name text, result text, detail text);

-- A. Structure, privileges and the stored values
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_txt     text;
  v_bad     text;
begin
  -- A1. the addition is recorded, after 0009zi
  insert into verify_0009zj values (1, 'A1 addition 0009zj recorded, after 0009zi',
    case when exists (select 1 from cma.schema_migration where version = '0009zj')
              and exists (select 1 from cma.schema_migration where version = '0009zi') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the write the application's and no one else's; JIT off; 218's counts kept; the late days counted again at now
  select string_agg(f, ', ') into v_bad
  from unnest(array['cma.ingest_upsert_source_figures(uuid,uuid,jsonb)']) f
  where to_regprocedure(f) is null or not has_function_privilege('cma_app', f, 'execute') or has_function_privilege('public', f, 'execute');
  select coalesce(array_to_string(p.proconfig, ','), '-') || ' ' || (p.prosrc like '%cma.source_figure_moves_of(v_tenant, p_connection_id, ''paused''%now())%')
         || ' ' || (p.prosrc like '%cma.source_figure_moves_of(v_tenant, p_connection_id, it.dims ->> ''status''%')
         || ' ' || (p.prosrc like '%e.synced_at > $4%' and p.prosrc like '%(f.business_date + 1)::timestamp at time zone v_zone, now())%'
                    and p.prosrc like '%cma_at = now()%')
  into v_txt
  from pg_proc p where p.oid = 'cma.ingest_upsert_source_figures(uuid,uuid,jsonb)'::regprocedure;
  insert into verify_0009zj values (2, 'A2 the write the application''s and no one else''s; its JIT off; its exits and pauses counted by the rule (218); the days with events stored since the previous write counted again among the events held now',
    case when v_bad is null and v_txt = 'jit=off true true true' and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce('not the application''s only: ' || v_bad || '; ', '') || coalesce(v_txt, 'missing'));

  -- A3 and A4. every stored exits and pauses row against the rule: at the moment it was taken, and now (counts only)
  select count(*) || ' rows, ' || count(*) filter (where x.cma_value is distinct from x.at_taken) || ' differ at cma_at'
         || coalesce(' (' || string_agg(distinct x.figure_key || coalesce(':' || (x.dims ->> 'status'), ''), ' ')
                               filter (where x.cma_value is distinct from x.at_taken) || ')', '')
         || ' | ' || count(*) filter (where x.cma_value is distinct from x.at_now) || ' lag the events held now'
         || coalesce(' (' || string_agg(distinct x.figure_key || coalesce(':' || (x.dims ->> 'status'), ''), ' ')
                               filter (where x.cma_value is distinct from x.at_now) || ', from ' || min(x.business_date) filter (where x.cma_value is distinct from x.at_now)
                               || ' to ' || max(x.business_date) filter (where x.cma_value is distinct from x.at_now) || ')', '')
  into v_txt
  from (select f.figure_key, f.dims, f.business_date, f.cma_value,
               cma.source_figure_moves_of(f.tenant_id, f.connection_id, case f.figure_key when 'pauses' then 'paused' else f.dims ->> 'status' end,
                                          f.business_date::timestamp at time zone t.timezone,
                                          (f.business_date + 1)::timestamp at time zone t.timezone, f.cma_at)::numeric as at_taken,
               cma.source_figure_moves_of(f.tenant_id, f.connection_id, case f.figure_key when 'pauses' then 'paused' else f.dims ->> 'status' end,
                                          f.business_date::timestamp at time zone t.timezone,
                                          (f.business_date + 1)::timestamp at time zone t.timezone, now())::numeric as at_now
        from cma.source_figure f
        join cma.tenant t on t.id = f.tenant_id
        where f.figure_key in ('exits', 'pauses') and f.cma_value is not null and f.cma_at is not null) x;
  insert into verify_0009zj values (3, 'A3 every stored exits and pauses row''s CMA value equals the rule''s count of the events the CMA held when it was taken (every tenant; counts only)',
    case when v_txt like '% rows, 0 differ at cma_at%' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'missing'));
  insert into verify_0009zj values (4, 'A4 no stored exits and pauses row lags the events the CMA holds now (right after 220, or after each store''s write)',
    case when v_txt like '% | 0 lag the events held now' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'missing'));
end
$$;

-- B. Behaviour on a throwaway tenant (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_rows    text[] := '{}';
  v_t uuid; v_ing uuid; v_shop uuid; v_sub uuid; v_sub2 uuid;
  v_today date := (now() at time zone 'Europe/London')::date;
  v_items jsonb;
  v_j jsonb;
  v_j2 jsonb;
  v_j3 jsonb;
  v_txt text;
begin
  if not v_dev then
    insert into verify_0009zj values (59, 'B a dev or local database (the dev seed''s agent.two@example.com active)', 'REFUSED',
      'no dev seed, so this is no dev or local database: block B did not run (block A is the check here)');
    return;
  end if;
  begin
    v_t := cma.create_tenant('verify-0009zj', 'Verify 0009zj', 'Europe/London');
    perform set_config('app.tenant_id', v_t::text, true);
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest' and x.external_id = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t, 'verifyshop', 'Verify shop', 'verify-zj.shop.example', 'commerce', 'verify-zj-shop-1') returning id into v_shop;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifysubs', 'Verify subscriptions', 'verify-zj.shop.example', 'subscriptions', 'verify-zj-key-1') returning id into v_sub;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifysubs', 'Verify subscriptions 2', 'verify-zj2.shop.example', 'subscriptions', 'verify-zj-key-2') returning id into v_sub2;
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency)
    values (v_t, 'GB', 'Verify GB', 'Europe/London', 'en', 'GBP') on conflict do nothing;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
    values (v_t, v_shop, 'verify-zj', 'Verify store', 'GB', 'GBP', 'Europe/London');

    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                  billing_interval_count, amount_per_cycle, currency, source_created_at, source_updated_at)
    select v_t, x.conn, 'verifysubs', x.id, 'c-' || x.id, 'canceled', 'month', 1, 30, 'GBP', now() - interval '100 days', now() - interval '1 day'
    from (values (v_sub, 'k1'), (v_sub, 'k2'), (v_sub, 'k3'), (v_sub, 'k4'), (v_sub2, 'm1')) x(conn, id);
    -- the events, each with the moment the CMA stored it: k1 on D-2 stored before its row was taken; k2 on D-2 one
    -- cancellation reported twice, stored half an hour ago, after the row; k3 on D-3 stored five hours ago, before its row;
    -- m1, the other connection's, on D-4, stored half an hour ago; k4 a report into canceled on D-5 stored before its row,
    -- and the cancellation it repeats, on D-6, stored half an hour ago
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at,
                                        status_from, status_to, synced_at)
    values (v_t, v_sub, 'verifysubs', 'k1-a', 'k1', 'status_changed', ((v_today - 2)::timestamp + interval '9 hours') at time zone 'Europe/London', 'active', 'canceled', now() - interval '5 hours'),
           (v_t, v_sub, 'verifysubs', 'k2-a', 'k2', 'status_changed', ((v_today - 2)::timestamp + interval '10 hours') at time zone 'Europe/London', 'active', 'canceled', now() - interval '30 minutes'),
           (v_t, v_sub, 'verifysubs', 'k2-b', 'k2', 'canceled', ((v_today - 2)::timestamp + interval '10 hours') at time zone 'Europe/London', 'active', 'canceled', now() - interval '30 minutes'),
           (v_t, v_sub, 'verifysubs', 'k3-a', 'k3', 'status_changed', ((v_today - 3)::timestamp + interval '9 hours') at time zone 'Europe/London', 'active', 'canceled', now() - interval '5 hours'),
           (v_t, v_sub2, 'verifysubs', 'm1-a', 'm1', 'status_changed', ((v_today - 4)::timestamp + interval '9 hours') at time zone 'Europe/London', 'active', 'canceled', now() - interval '30 minutes'),
           (v_t, v_sub, 'verifysubs', 'k4-b', 'k4', 'status_changed', ((v_today - 5)::timestamp + interval '10 hours') at time zone 'Europe/London', 'active', 'canceled', now() - interval '5 hours'),
           (v_t, v_sub, 'verifysubs', 'k4-a', 'k4', 'canceled', ((v_today - 6)::timestamp + interval '10 hours') at time zone 'Europe/London', 'active', 'canceled', now() - interval '30 minutes');
    -- the stored rows of D-2, D-3 and D-4, taken two hours ago with the events held then (D-2 1: k1 only)
    insert into cma.source_figure (tenant_id, connection_id, figure_key, source_metric, business_date, dims, value, unit, cma_value, cma_at, fetched_at)
    values (v_t, v_sub, 'exits', 'subscriptions:churned', v_today - 2, '{"status": "canceled"}', 2, 'count', 1, now() - interval '2 hours', now() - interval '2 hours'),
           (v_t, v_sub, 'exits', 'subscriptions:churned', v_today - 3, '{"status": "canceled"}', 1, 'count', 1, now() - interval '2 hours', now() - interval '2 hours'),
           (v_t, v_sub, 'exits', 'subscriptions:churned', v_today - 4, '{"status": "canceled"}', 0, 'count', 0, now() - interval '2 hours', now() - interval '2 hours'),
           (v_t, v_sub, 'exits', 'subscriptions:churned', v_today - 5, '{"status": "canceled"}', 0, 'count', 1, now() - interval '2 hours', now() - interval '2 hours'),
           (v_t, v_sub, 'exits', 'subscriptions:churned', v_today - 6, '{"status": "canceled"}', 1, 'count', 0, now() - interval '2 hours', now() - interval '2 hours');

    -- B1. today's write as the ingest
    v_items := jsonb_build_array(
      jsonb_build_object('figureKey', 'exits', 'sourceMetric', 'subscriptions:churned', 'businessDate', v_today, 'dims', jsonb_build_object('status', 'canceled'), 'value', 0, 'unit', 'count'));
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_ing::text, true);
    v_j := cma.ingest_upsert_source_figures(v_sub, null, v_items);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_j::text || ' | ' || (select string_agg((f.business_date - v_today) || '=' || f.cma_value || case when f.cma_at = now() then ' now' else ' kept' end, ' '
                                                       order by f.business_date)
                                    from cma.source_figure f where f.tenant_id = v_t and f.connection_id = v_sub and f.business_date >= v_today - 4);
    v_rows := v_rows || array['11', 'B1 a day with status events stored after its row was taken is counted again among the events held now (1 to 2, a double report once) and its cma_at moves to now; a day whose event was stored before keeps its value and cma_at; the answer names the rows counted again (with B3''s two)',
      case when v_txt = '{"updated": 0, "inserted": 1, "recounted": 3, "unchanged": 0} | -4=0.00 kept -3=1.00 kept -2=2.00 now 0=0.00 now'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. a late event changes the next day's count too: k4's cancellation on D-6, stored late, makes its report into
    -- canceled on D-5 no move; both days are counted again (D-6 0 to 1, D-5 1 to 0)
    v_txt := (select string_agg((f.business_date - v_today) || '=' || f.cma_value || case when f.cma_at = now() then ' now' else ' kept' end, ' '
                                order by f.business_date)
              from cma.source_figure f where f.tenant_id = v_t and f.connection_id = v_sub and f.business_date < v_today - 4);
    v_rows := v_rows || array['13', 'B3 a late event''s subscription''s next status event, on a later day, is counted again too: a cancellation on D-6 stored late makes the report into canceled on D-5 no move (D-6 0 to 1, D-5 1 to 0, both taken now)',
      case when v_txt = '-6=1.00 now -5=0.00 now' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. the other connection: its late event moves none of the first connection's rows (D-4 kept above); its first
    -- write (no earlier row) answers with the three counts alone; so does a second write of the first connection once its
    -- late days are taken (their cma_at now: a row is counted again only while its cma_at is older than the write)
    perform set_config('role', 'cma_app', true);
    v_j2 := cma.ingest_upsert_source_figures(v_sub2, null, v_items);
    v_j3 := cma.ingest_upsert_source_figures(v_sub, null, v_items);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_j2::text || ' ' || v_j3::text || ' | '
             || (select string_agg(f.business_date - v_today || '=' || f.cma_value, ' ' order by f.business_date) from cma.source_figure f where f.tenant_id = v_t and f.connection_id = v_sub2);
    v_rows := v_rows || array['12', 'B2 the other connection''s late event moves none of this connection''s rows (B1''s D-4 kept); a first write, and a second write once the late days are taken, answer with the three counts alone',
      case when v_txt = '{"updated": 0, "inserted": 1, "unchanged": 0} {"updated": 0, "inserted": 0, "unchanged": 1} | 0=0.00'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  insert into verify_0009zj (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009zj values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict (7 checks in dev; block A's 4 elsewhere)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009zj
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when not current_setting('verify.dev')::boolean then
                    case when (select count(*) from verify_0009zj where result = 'PASS' and ord < 10) = 4
                              and not exists (select 1 from verify_0009zj where result not in ('PASS', 'REFUSED')) then 'PASS, A ONLY' else 'FAIL' end
                  when (select count(*) from verify_0009zj where result = 'PASS') = 7
                       and not exists (select 1 from verify_0009zj where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('221_verify_source_figure_late_events: %s PASS, %s FAIL', (select count(*) from verify_0009zj where result = 'PASS'),
                                                                              (select count(*) from verify_0009zj where result not in ('PASS', 'REFUSED')))) x
order by ord;
reset role;
