-- =============================================================================================
-- 219_verify_source_figure_moves.sql: verifies addition 0009zi, the source figures' exits and pauses counting one move
-- into a status once
-- =============================================================================================
-- Block A only reads and runs in every database, prod included: the addition, the grants, and every stored exits and
-- pauses row's CMA value against the rule (counts only: no id of a customer or a subscription). Block B runs in dev and
-- local databases only, as 215 (the dev seed's agent.two@example.com active), on a throwaway tenant inside a
-- subtransaction that is always rolled back, so nothing stays; elsewhere it reads REFUSED and the verdict says PASS, A ONLY
-- when block A passes. Every check writes one row, PASS or FAIL, and the last row is the verdict, because Cloud SQL
-- Studio shows no notices. Run as your own IAM login after 218_source_figure_moves.sql; then 215.
--   A  A1 the addition after 0009zg; A2 cma.source_figure_moves_of and the write the application's and no one else's, the
--      write's JIT still off and its exits and pauses read through the rule; A3 every stored exits and pauses row's CMA
--      value equals the rule's recount of the events the CMA held when it was taken (218's recount, and every read since)
--   B  on a throwaway tenant (Europe/London), one subscriptions connection, the day D (yesterday in London):
--      B1 the write as the ingest: exits into canceled 4 where 214's rule gave 8 (one cancellation reported as canceled
--         and as status_changed, at one instant and a second apart: 1 each; cancel, reactivate, cancel: 2; a report into
--         canceled of a subscription canceled the day before: 0, that day 1; a first report whose status_from is canceled
--         already: 0), into failed 2 where 214 gave 3 (one move reported twice), expired 0; pauses 3 where 214 gave 4
--         (paused and status_changed into paused: 1; pause, resume, pause: 2); renewals and purchases unchanged
--      B2 B39c's moves (cma.subscription_moves_of, the Churn rate's and Failed rate's input) on the same events: churned,
--         moved_to_failed and paused on D equal the figures (4, 2, 3), and none of the double reports is a second move
--      B3 the rule against the day's bounds: an event at D 00:00 counts, at D + 1 00:00 not; an event the CMA held only
--         after the moment asked for (synced_at) is not counted
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
-- block B in dev or a local database only: the dev seed's agent.two@example.com active, as 211 and 215
select set_config('verify.dev', (select exists (select 1 from cma.app_user u where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false);

drop table if exists pg_temp.verify_0009zi;
create temp table verify_0009zi (ord int, check_name text, result text, detail text);

-- 214's count of exits and pauses (every event whose status_to is the status), kept to show what the rule changes
create or replace function pg_temp.v0009zi_old(p_tenant_id uuid, p_connection_id uuid, p_status text, p_from timestamptz, p_to timestamptz)
returns bigint
language sql stable
as $$
  select count(*) from cma.subscription_event e
  where e.tenant_id = p_tenant_id and e.connection_id = p_connection_id
    and e.occurred_at >= p_from and e.occurred_at < p_to and e.status_to = p_status
$$;

-- A. Structure, privileges and the stored values
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_txt     text;
  v_bad     text;
begin
  -- A1. the addition is recorded, after 0009zg
  insert into verify_0009zi values (1, 'A1 addition 0009zi recorded, after 0009zg',
    case when exists (select 1 from cma.schema_migration where version = '0009zi')
              and exists (select 1 from cma.schema_migration where version = '0009zg') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the two functions the application's and no one else's; the write's JIT off and its exits and pauses by the rule
  select string_agg(f, ', ') into v_bad
  from unnest(array['cma.source_figure_moves_of(uuid,uuid,text,timestamptz,timestamptz,timestamptz)', 'cma.ingest_upsert_source_figures(uuid,uuid,jsonb)']) f
  where to_regprocedure(f) is null or not has_function_privilege('cma_app', f, 'execute') or has_function_privilege('public', f, 'execute');
  select coalesce(array_to_string(p.proconfig, ','), '-') || ' ' || (p.prosrc like '%cma.source_figure_moves_of(v_tenant, p_connection_id, ''paused''%now())%')
         || ' ' || (p.prosrc like '%cma.source_figure_moves_of(v_tenant, p_connection_id, it.dims ->> ''status''%')
         || ' ' || (p.prosrc like '%e.status_to = it.dims%')
  into v_txt
  from pg_proc p where p.oid = 'cma.ingest_upsert_source_figures(uuid,uuid,jsonb)'::regprocedure;
  insert into verify_0009zi values (2, 'A2 cma.source_figure_moves_of and the write the application''s and no one else''s; the write''s JIT off, its pauses and exits counted by the rule, 214''s status_to count gone',
    case when v_bad is null and v_txt = 'jit=off true true false' and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce('not the application''s only: ' || v_bad || '; ', '') || coalesce(v_txt, 'missing'));

  -- A3. every stored exits and pauses row against the rule's recount for the moment it was taken: counts only
  select count(*) || ' rows, ' || count(*) filter (where x.cma_value is distinct from x.recount) || ' differ'
         || coalesce(' (' || string_agg(distinct x.figure_key || coalesce(':' || (x.dims ->> 'status'), ''), ' ')
                               filter (where x.cma_value is distinct from x.recount) || ')', '')
  into v_txt
  from (select f.figure_key, f.dims, f.cma_value,
               cma.source_figure_moves_of(f.tenant_id, f.connection_id,
                                          case f.figure_key when 'pauses' then 'paused' else f.dims ->> 'status' end,
                                          f.business_date::timestamp at time zone t.timezone,
                                          (f.business_date + 1)::timestamp at time zone t.timezone, f.cma_at)::numeric as recount
        from cma.source_figure f
        join cma.tenant t on t.id = f.tenant_id
        where f.figure_key in ('exits', 'pauses') and f.cma_value is not null and f.cma_at is not null) x;
  insert into verify_0009zi values (3, 'A3 every stored exits and pauses row''s CMA value equals the rule''s recount of the events the CMA held when it was taken (every tenant; counts only)',
    case when v_txt like '% rows, 0 differ' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'missing'));
end
$$;

-- B. Behaviour on a throwaway tenant (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_rows    text[] := '{}';
  v_t uuid; v_ing uuid; v_shop uuid; v_sub uuid;
  v_d date := (now() at time zone 'Europe/London')::date - 1;
  v_d0 timestamptz := ((now() at time zone 'Europe/London')::date - 1)::timestamp at time zone 'Europe/London';
  v_d1 timestamptz := ((now() at time zone 'Europe/London')::date)::timestamp at time zone 'Europe/London';
  v_items jsonb;
  v_j jsonb;
  v_txt text;
begin
  if not v_dev then
    insert into verify_0009zi values (59, 'B a dev or local database (the dev seed''s agent.two@example.com active)', 'REFUSED',
      'no dev seed, so this is no dev or local database: block B did not run (block A is the check here)');
    return;
  end if;
  begin
    v_t := cma.create_tenant('verify-0009zi', 'Verify 0009zi', 'Europe/London');
    perform set_config('app.tenant_id', v_t::text, true);
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest' and x.external_id = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t, 'verifyshop', 'Verify shop', 'verify-zi.shop.example', 'commerce', 'verify-zi-shop-1') returning id into v_shop;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifysubs', 'Verify subscriptions', 'verify-zi.shop.example', 'subscriptions', 'verify-zi-key-1') returning id into v_sub;
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency)
    values (v_t, 'GB', 'Verify GB', 'Europe/London', 'en', 'GBP') on conflict do nothing;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
    values (v_t, v_shop, 'verify-zi', 'Verify store', 'GB', 'GBP', 'Europe/London');

    -- the subscriptions in their current status, created long before D
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                  billing_interval_count, amount_per_cycle, currency, source_created_at, source_updated_at)
    select v_t, v_sub, 'verifysubs', x.id, 'c-' || x.id, x.status, 'month', 1, 30, 'GBP', v_d0 - interval '100 days', v_d0 + interval '20 hours'
    from (values ('k1', 'canceled'), ('k2', 'canceled'), ('k3', 'canceled'), ('k4', 'canceled'), ('k5', 'canceled'),
                 ('f1', 'failed'), ('f2', 'failed'), ('p1', 'paused'), ('p2', 'paused'), ('a1', 'active')) x(id, status);
    -- the events (the adapter's shapes: canceled and paused carry the previous status and their own; status_changed the
    -- move it reports)
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, status_from, status_to)
    values -- k1: one cancellation reported twice at one instant
           (v_t, v_sub, 'verifysubs', 'k1-b', 'k1', 'canceled', v_d0 + interval '1 hour', 'active', 'canceled'),
           (v_t, v_sub, 'verifysubs', 'k1-a', 'k1', 'status_changed', v_d0 + interval '1 hour', 'active', 'canceled'),
           -- k2: the same a second apart, status_changed first
           (v_t, v_sub, 'verifysubs', 'k2-a', 'k2', 'status_changed', v_d0 + interval '2 hours', 'active', 'canceled'),
           (v_t, v_sub, 'verifysubs', 'k2-b', 'k2', 'canceled', v_d0 + interval '2 hours 1 second', 'active', 'canceled'),
           -- k3: cancel, reactivate, cancel: two moves
           (v_t, v_sub, 'verifysubs', 'k3-a', 'k3', 'canceled', v_d0 + interval '3 hours', 'active', 'canceled'),
           (v_t, v_sub, 'verifysubs', 'k3-b', 'k3', 'reactivated', v_d0 + interval '4 hours', 'canceled', 'active'),
           (v_t, v_sub, 'verifysubs', 'k3-c', 'k3', 'canceled', v_d0 + interval '5 hours', 'active', 'canceled'),
           -- k4: canceled the day before, a report into canceled on D
           (v_t, v_sub, 'verifysubs', 'k4-a', 'k4', 'canceled', v_d0 - interval '2 hours', 'active', 'canceled'),
           (v_t, v_sub, 'verifysubs', 'k4-b', 'k4', 'status_changed', v_d0 + interval '6 hours', 'active', 'canceled'),
           -- k5: its first report on D says it was canceled already
           (v_t, v_sub, 'verifysubs', 'k5-a', 'k5', 'canceled', v_d0 + interval '7 hours', 'canceled', 'canceled'),
           -- f1: into failed; f2: one move into failed reported twice
           (v_t, v_sub, 'verifysubs', 'f1-a', 'f1', 'status_changed', v_d0 + interval '8 hours', 'active', 'failed'),
           (v_t, v_sub, 'verifysubs', 'f2-a', 'f2', 'status_changed', v_d0 + interval '9 hours', 'active', 'failed'),
           (v_t, v_sub, 'verifysubs', 'f2-b', 'f2', 'status_changed', v_d0 + interval '9 hours 1 second', 'active', 'failed'),
           -- p1: one pause reported twice; p2: pause, resume, pause
           (v_t, v_sub, 'verifysubs', 'p1-a', 'p1', 'paused', v_d0 + interval '10 hours', 'active', 'paused'),
           (v_t, v_sub, 'verifysubs', 'p1-b', 'p1', 'status_changed', v_d0 + interval '10 hours', 'active', 'paused'),
           (v_t, v_sub, 'verifysubs', 'p2-a', 'p2', 'paused', v_d0 + interval '11 hours', 'active', 'paused'),
           (v_t, v_sub, 'verifysubs', 'p2-b', 'p2', 'resumed', v_d0 + interval '12 hours', 'paused', 'active'),
           (v_t, v_sub, 'verifysubs', 'p2-c', 'p2', 'paused', v_d0 + interval '13 hours', 'active', 'paused'),
           -- a1: a renewal and a purchase, unchanged by the rule
           (v_t, v_sub, 'verifysubs', 'a1-a', 'a1', 'renewed', v_d0 + interval '14 hours', null, null),
           (v_t, v_sub, 'verifysubs', 'a1-b', 'a1', 'purchased', v_d0 + interval '15 hours', null, null);

    -- B1. the write as the ingest, against 214's rule on the same events
    v_items := jsonb_build_array(
      jsonb_build_object('figureKey', 'exits', 'sourceMetric', 'subscriptions:canceled', 'businessDate', v_d, 'dims', jsonb_build_object('status', 'canceled'), 'value', 4, 'unit', 'count'),
      jsonb_build_object('figureKey', 'exits', 'sourceMetric', 'subscriptions:canceled', 'businessDate', v_d - 1, 'dims', jsonb_build_object('status', 'canceled'), 'value', 1, 'unit', 'count'),
      jsonb_build_object('figureKey', 'exits', 'sourceMetric', 'subscriptions:failed', 'businessDate', v_d, 'dims', jsonb_build_object('status', 'failed'), 'value', 2, 'unit', 'count'),
      jsonb_build_object('figureKey', 'exits', 'sourceMetric', 'subscriptions:expired', 'businessDate', v_d, 'dims', jsonb_build_object('status', 'expired'), 'value', 0, 'unit', 'count'),
      jsonb_build_object('figureKey', 'pauses', 'sourceMetric', 'subscriptions:paused', 'businessDate', v_d, 'dims', '{}'::jsonb, 'value', 3, 'unit', 'count'),
      jsonb_build_object('figureKey', 'renewals', 'sourceMetric', 'subscriptions:renewed', 'businessDate', v_d, 'dims', '{}'::jsonb, 'value', 1, 'unit', 'count'),
      jsonb_build_object('figureKey', 'purchases', 'sourceMetric', 'subscriptions:purchased', 'businessDate', v_d, 'dims', '{}'::jsonb, 'value', 1, 'unit', 'count'));
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_ing::text, true);
    v_j := cma.ingest_upsert_source_figures(v_sub, null, v_items);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_j::text
             || ' | ' || (select string_agg(f.figure_key || coalesce(':' || (f.dims ->> 'status'), '') || ':' || f.business_date - v_d || '='
                                            || coalesce(f.cma_value::text, 'null'), ' '
                                            order by f.figure_key collate "C", f.dims::text collate "C", f.business_date)
                          from cma.source_figure f where f.tenant_id = v_t)
             || ' | 214: ' || pg_temp.v0009zi_old(v_t, v_sub, 'canceled', v_d0, v_d1) || ' ' || pg_temp.v0009zi_old(v_t, v_sub, 'failed', v_d0, v_d1)
             || ' ' || pg_temp.v0009zi_old(v_t, v_sub, 'paused', v_d0, v_d1);
    v_rows := v_rows || array['11', 'B1 the write as the ingest: exits into canceled 4 (214: 8), the day before 1, failed 2 (214: 3), expired 0, pauses 3 (214: 4); renewals and purchases 1; every compared figure within',
      case when v_txt = '{"updated": 0, "inserted": 7, "unchanged": 0} | exits:canceled:-1=1.00 exits:canceled:0=4.00 exits:expired:0=0.00 exits:failed:0=2.00 pauses:0=3.00 purchases:0=1.00 renewals:0=1.00 | 214: 8 3 4'
                and not exists (select 1 from cma.source_figure_rows_of(v_t, v_d - 1, v_d) r where r.state <> 'within')
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. B39c's moves on the same events: one move per change of status, equal to the figures
    v_txt := (select count(*) filter (where m.kind = 'churned' and m.status_to = 'canceled' and m.at >= v_d0 and m.at < v_d1) || ' '
                     || count(*) filter (where m.kind = 'moved_to_failed' and m.at >= v_d0 and m.at < v_d1) || ' '
                     || count(*) filter (where m.kind = 'paused' and m.at >= v_d0 and m.at < v_d1) || ' '
                     || count(*) filter (where m.kind = 'churned' and m.at < v_d0)
              from cma.subscription_moves_of(v_t, now()) m)
             || ' | ' || (select string_agg(s.source_id || ':' || x.n, ' ' order by s.source_id collate "C")
                          from (select m.subscription_id, count(*) as n from cma.subscription_moves_of(v_t, now()) m
                                where m.kind in ('churned', 'moved_to_failed', 'paused') group by 1) x
                          join cma.subscription s on s.id = x.subscription_id);
    v_rows := v_rows || array['12', 'B2 B39c''s moves (cma.subscription_moves_of, the Churn rate''s and Failed rate''s input) on the same events: churned into canceled 4, moved_to_failed 2, paused 3 on D, churned 1 the day before; a double report is no second move',
      case when v_txt = '4 2 3 1 | f1:1 f2:1 k1:1 k2:1 k3:2 k4:1 p1:1 p2:2' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. the day's bounds: a move at D 00:00 counts on D, at D + 1 00:00 on the next day
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                  billing_interval_count, amount_per_cycle, currency, source_created_at, source_updated_at)
    values (v_t, v_sub, 'verifysubs', 'e1', 'c-e1', 'expired', 'month', 1, 30, 'GBP', v_d0 - interval '100 days', v_d1),
           (v_t, v_sub, 'verifysubs', 'e2', 'c-e2', 'expired', 'month', 1, 30, 'GBP', v_d0 - interval '100 days', v_d1);
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, status_from, status_to)
    values (v_t, v_sub, 'verifysubs', 'e1-a', 'e1', 'status_changed', v_d0, 'active', 'expired'),
           (v_t, v_sub, 'verifysubs', 'e2-a', 'e2', 'status_changed', v_d1, 'active', 'expired');
    v_txt := cma.source_figure_moves_of(v_t, v_sub, 'expired', v_d0, v_d1, now()) || ' ' || cma.source_figure_moves_of(v_t, v_sub, 'expired', v_d1, v_d1 + interval '1 day', now());
    -- an event the CMA came to hold after a moment is not counted for it: e1's report, held from now on, unknown an hour ago
    v_txt := v_txt || ' ' || cma.source_figure_moves_of(v_t, v_sub, 'expired', v_d0, v_d1, now() - interval '1 hour');
    v_rows := v_rows || array['13', 'B3 the day''s bounds: a move at D 00:00 counts on D, one at D + 1 00:00 on the next day; an event the CMA held only after the moment asked for is not counted',
      case when v_txt = '1 1 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  insert into verify_0009zi (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009zi values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helper is dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009zi_old(uuid, uuid, text, timestamptz, timestamptz);

-- Verdict: one row per check, then the verdict (6 checks in dev; block A's 3 elsewhere)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009zi
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when not current_setting('verify.dev')::boolean then
                    case when (select count(*) from verify_0009zi where result = 'PASS' and ord < 10) = 3
                              and not exists (select 1 from verify_0009zi where result not in ('PASS', 'REFUSED')) then 'PASS, A ONLY' else 'FAIL' end
                  when (select count(*) from verify_0009zi where result = 'PASS') = 6
                       and not exists (select 1 from verify_0009zi where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('219_verify_source_figure_moves: %s PASS, %s FAIL', (select count(*) from verify_0009zi where result = 'PASS'),
                                                                        (select count(*) from verify_0009zi where result not in ('PASS', 'REFUSED')))) x
order by ord;
reset role;
