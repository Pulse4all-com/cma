-- =============================================================================================
-- 223_verify_subscription_moves_entry.sql: verifies addition 0009zk, a subscription's entry status from its first status
-- event, named or not
-- =============================================================================================
-- Block A only reads and runs in every database, prod included: the addition, the function's privileges and setting, and
-- its answer against 210's (kept below) row for row on every tenant (counts only: no id of a customer or a subscription).
-- Block B runs in dev and local databases only, as 211 (the dev seed's agent.two@example.com active), on a throwaway
-- tenant inside a subtransaction that is always rolled back; elsewhere it reads REFUSED and the verdict says PASS, A ONLY
-- when block A passes. Every check writes one row, PASS or FAIL, and the last row is the verdict, because Cloud SQL Studio
-- shows no notices. Run as your own IAM login after 222_subscription_moves_entry.sql; then 211 and 213 (and 219 where
-- 0009zi ran, 217 where 0009zh ran).
--   A  A1 the addition after 0009ze; A2 the function the application's and no one else's, its JIT off, 210's filter on a
--      named previous status gone; A3 its moves equal 210's on every tenant but for subscriptions whose first status event
--      names no previous status (before the backfill of the events: Juo's canceled and paused reports without one, if any);
--      provoked, 210's side loses one move, which the comparison must find
--   B  on a throwaway tenant: a subscription moved into canceled in 2025 by a legacy move (no previous status) and reactivated in
--      March 2026 (from canceled) enters active and churns in 2025 (210: entered canceled, no churn); one whose moves are
--      all legacy, and one whose events all name a previous status, move as under 210
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
-- block B in dev or a local database only: the dev seed's agent.two@example.com active, as 211
select set_config('verify.dev', (select exists (select 1 from cma.app_user u where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false);

drop table if exists pg_temp.verify_0009zk;
create temp table verify_0009zk (ord int, check_name text, result text, detail text);

-- 210's cma.subscription_moves_of, kept to compare: the entry status from the first status event that names a previous one
create or replace function pg_temp.v0009zk_old(p_tenant_id uuid, p_now timestamptz)
returns table (subscription_id uuid, connection_id uuid, at timestamptz, status_from text, status_to text, kind text)
language sql stable
rows 100000
as $$
  with st as materialized (
    select cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.ended_subscription_statuses')) as ended
  ), s as materialized (
    select x.id, x.connection_id, x.source_id, x.status, x.source_created_at, x.paused_at, x.canceled_at, x.source_updated_at
    from cma.subscription x
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null
  ), ev as materialized (
    select s.id, e.occurred_at, e.source_id, e.event_type, e.status_from,
           case e.event_type when 'status_changed' then e.status_to when 'canceled' then 'canceled' when 'paused' then 'paused'
                             when 'resumed' then 'active' when 'reactivated' then 'active' end as status_to
    from s
    join cma.subscription_event e on e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
    where e.occurred_at <= p_now
      and e.event_type in ('status_changed', 'canceled', 'paused', 'resumed', 'reactivated', 'migrated', 'purchased', 'created')
  ), first_ev as (
    select ev.id, min(ev.occurred_at) as first_at,
           (array_agg(ev.status_from order by ev.occurred_at, ev.source_id collate "C")
              filter (where ev.status_to is not null and ev.status_from is not null))[1] as first_from,
           bool_or(ev.event_type = 'migrated') as migrated
    from ev
    group by ev.id
  ), seq as (
    -- the entry, then the status events in their order
    select s.id, coalesce(s.source_created_at, f.first_at) as at, 0 as ord, ''::text as src, coalesce(f.first_from, 'active') as status_to,
           coalesce(f.migrated, false) as migrated
    from s left join first_ev f on f.id = s.id
    where coalesce(s.source_created_at, f.first_at) <= p_now
    union all
    select ev.id, ev.occurred_at, 1, ev.source_id, ev.status_to, false
    from ev where ev.status_to is not null
  ), lagged as (
    select q.id, q.at, q.ord, q.src, q.status_to, q.migrated,
           lag(q.status_to) over (partition by q.id order by q.at, q.ord, q.src collate "C") as status_from,
           row_number() over (partition by q.id order by q.at desc, q.ord desc, q.src collate "C" desc) as from_last
    from seq q
  ), moves as (
    select l.id, l.at, l.status_from, l.status_to, l.ord, l.migrated
    from lagged l
    where l.ord = 0 or l.status_from is distinct from l.status_to
    union all
    -- the current status where the events do not end in it
    select s.id,
           greatest(l.at, case when s.status = 'paused' then s.paused_at when s.status in ('canceled', 'expired') then s.canceled_at end,
                    least(s.source_updated_at, p_now)),
           l.status_to, s.status, 2, false
    from s
    join lagged l on l.id = s.id and l.from_last = 1
    where l.status_to is distinct from s.status and s.source_updated_at <= p_now
  )
  select m.id, s.connection_id, m.at, m.status_from, m.status_to,
         case when m.ord = 0 then case when m.status_to = 'active' then case when m.migrated then 'migrated' else 'new' end end
              when m.status_to = any ((select st.ended from st)::text[]) then
                case when m.status_from = any ((select st.ended from st)::text[]) then null else 'churned' end
              when m.status_to = 'failed' then 'moved_to_failed'
              when m.status_to = 'paused' then 'paused'
              when m.status_to = 'active' and m.status_from = 'paused' then 'resumed'
              when m.status_to = 'active' then 'reactivated' end
  from moves m
  join s on s.id = m.id
$$;


alter function pg_temp.v0009zk_old(uuid, timestamptz) set jit = off;

-- A. Structure, privileges and the answer against 210's
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_txt     text;
  v_bad     text;
  v_now     timestamptz := now();
begin
  -- the comparison below plans two set-returning functions of 100,000 rows each per tenant: no JIT for this block
  perform set_config('jit', 'off', true);
  insert into verify_0009zk values (1, 'A1 addition 0009zk recorded, after 0009ze',
    case when exists (select 1 from cma.schema_migration where version = '0009zk')
              and exists (select 1 from cma.schema_migration where version = '0009ze') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  select string_agg(f, ', ') into v_bad
  from unnest(array['cma.subscription_moves_of(uuid,timestamptz)']) f
  where to_regprocedure(f) is null or not has_function_privilege('cma_app', f, 'execute') or has_function_privilege('public', f, 'execute');
  select coalesce(array_to_string(p.proconfig, ','), '-') || ' ' || (p.prosrc like '%ev.status_from is not null))[1] as first_from%')
         || ' ' || (p.prosrc like '%filter (where ev.status_to is not null))[1] as first_from%')
  into v_txt
  from pg_proc p where p.oid = 'cma.subscription_moves_of(uuid,timestamptz)'::regprocedure;
  insert into verify_0009zk values (2, 'A2 cma.subscription_moves_of the application''s and no one else''s; its JIT off; the entry status from the first status event, 210''s filter on a named previous status gone',
    case when v_bad is null and v_txt = 'jit=off false true' and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce('not the application''s only: ' || v_bad || '; ', '') || coalesce(v_txt, 'missing'));

  -- A3. row for row against 210's on every tenant; a difference only where the first status event names no previous status
  with t as (select x.id from cma.tenant x),
  n as (select t.id as tenant_id, m.* from t cross join lateral cma.subscription_moves_of(t.id, v_now) m),
  o0 as (select t.id as tenant_id, m.* from t cross join lateral pg_temp.v0009zk_old(t.id, v_now) m),
  -- provoked, 210's side loses one move (the earliest with a kind), so the comparison itself must find it: the detail
  -- then reads one subscription more that differs
  o as (select * from o0
        where not v_provoke
           or (o0.subscription_id, o0.at) is distinct from (select (x.subscription_id, x.at) from o0 x where x.kind is not null
                                                             order by x.at, x.subscription_id limit 1)),
  d as ((select * from n except all select * from o) union all (select * from o except all select * from n)),
  unnamed as (
    -- the subscriptions whose first status event names no previous status
    select s.id
    from cma.subscription s
    cross join lateral (
      select e.status_from
      from cma.subscription_event e
      where e.tenant_id = s.tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
        and e.occurred_at <= v_now and e.event_type in ('status_changed', 'canceled', 'paused', 'resumed', 'reactivated')
        and (e.event_type <> 'status_changed' or e.status_to is not null)
      order by e.occurred_at, (e.status_from is null), e.source_id collate "C"
      limit 1) f
    where f.status_from is null and s.source_deleted_at is null
  )
  select (select count(*) from n) || ' moves, ' || (select count(distinct d.subscription_id) from d) || ' subscriptions differ, '
         || (select count(distinct d.subscription_id) from d where d.subscription_id not in (select u.id from unnamed u)) || ' of them with a named first previous status'
         || ' | ' || (select count(*) from unnamed) || ' subscriptions whose first status event names none'
  into v_txt;
  insert into verify_0009zk values (3, 'A3 its moves equal 210''s on every tenant, but for subscriptions whose first status event names no previous status (counts only)',
    case when v_txt like '% moves, % subscriptions differ, 0 of them with a named first previous status | %' and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce(v_txt, 'missing'));
end
$$;

-- B. Behaviour on a throwaway tenant (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_rows    text[] := '{}';
  v_t uuid; v_shop uuid; v_sub uuid;
  v_txt text;
begin
  if not v_dev then
    insert into verify_0009zk values (59, 'B a dev or local database (the dev seed''s agent.two@example.com active)', 'REFUSED',
      'no dev seed, so this is no dev or local database: block B did not run (block A is the check here)');
    return;
  end if;
  begin
    v_t := cma.create_tenant('verify-0009zk', 'Verify 0009zk', 'Europe/London');
    perform set_config('app.tenant_id', v_t::text, true);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t, 'verifyshop', 'Verify shop', 'verify-zk.shop.example', 'commerce', 'verify-zk-shop-1') returning id into v_shop;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifysubs', 'Verify subscriptions', 'verify-zk.shop.example', 'subscriptions', 'verify-zk-key-1') returning id into v_sub;
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                  billing_interval_count, amount_per_cycle, currency, source_created_at, source_updated_at)
    values (v_t, v_sub, 'verifysubs', 'l1', 'c-l1', 'active', 'month', 1, 30, 'GBP', '2025-01-01 10:00+00', '2026-03-01 10:00+00'),
           (v_t, v_sub, 'verifysubs', 'l2', 'c-l2', 'active', 'month', 1, 30, 'GBP', '2025-01-01 10:00+00', '2025-05-10 10:00+00'),
           (v_t, v_sub, 'verifysubs', 'n1', 'c-n1', 'active', 'month', 1, 30, 'GBP', '2025-01-01 10:00+00', '2026-04-01 10:00+00');
    -- l1: a legacy move into canceled in 2025 (no previous status), then a reactivation from canceled in 2026; l2: all legacy
    -- (into failed, back to active); n1: every event names its previous status (canceled, then reactivated)
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, status_from, status_to)
    values (v_t, v_sub, 'verifysubs', 'l1-a', 'l1', 'status_changed', '2025-06-01 10:00+00', null, 'canceled'),
           (v_t, v_sub, 'verifysubs', 'l1-b', 'l1', 'status_changed', '2026-03-01 10:00+00', 'canceled', 'active'),
           (v_t, v_sub, 'verifysubs', 'l2-a', 'l2', 'status_changed', '2025-05-01 10:00+00', null, 'failed'),
           (v_t, v_sub, 'verifysubs', 'l2-b', 'l2', 'status_changed', '2025-05-10 10:00+00', null, 'active'),
           (v_t, v_sub, 'verifysubs', 'n1-a', 'n1', 'status_changed', '2025-07-01 10:00+00', 'active', 'canceled'),
           (v_t, v_sub, 'verifysubs', 'n1-b', 'n1', 'status_changed', '2026-04-01 10:00+00', 'canceled', 'active');
    select string_agg(x.k, ' ' order by x.k collate "C") into v_txt
    from (select s.source_id || ':' || coalesce(string_agg(m.kind || '@' || to_char(m.at at time zone 'UTC', 'YYYY-MM'), ',' order by m.at), '-') as k
          from cma.subscription s
          left join cma.subscription_moves_of(v_t, now()) m on m.subscription_id = s.id and m.kind is not null
          where s.tenant_id = v_t group by s.source_id
          union all
          select 'old-' || s.source_id || ':' || coalesce(string_agg(m.kind || '@' || to_char(m.at at time zone 'UTC', 'YYYY-MM'), ',' order by m.at), '-')
          from cma.subscription s
          left join pg_temp.v0009zk_old(v_t, now()) m on m.subscription_id = s.id and m.kind is not null
          where s.tenant_id = v_t group by s.source_id) x;
    v_rows := v_rows || array['11', 'B1 a legacy move into canceled in 2025 then a reactivation from canceled in 2026: entry active, churned in 2025, reactivated in 2026 (210: entered canceled, no churn); all legacy, and all named, move as under 210',
      case when v_txt = 'l1:new@2025-01,churned@2025-06,reactivated@2026-03 l2:new@2025-01,moved_to_failed@2025-05,reactivated@2025-05 n1:new@2025-01,churned@2025-07,reactivated@2026-04 old-l1:reactivated@2026-03 old-l2:new@2025-01,moved_to_failed@2025-05,reactivated@2025-05 old-n1:new@2025-01,churned@2025-07,reactivated@2026-04'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  insert into verify_0009zk (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009zk values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

drop function if exists pg_temp.v0009zk_old(uuid, timestamptz);

-- Verdict: one row per check, then the verdict (4 checks in dev; block A's 3 elsewhere)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009zk
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when not current_setting('verify.dev')::boolean then
                    case when (select count(*) from verify_0009zk where result = 'PASS' and ord < 10) = 3
                              and not exists (select 1 from verify_0009zk where result not in ('PASS', 'REFUSED')) then 'PASS, A ONLY' else 'FAIL' end
                  when (select count(*) from verify_0009zk where result = 'PASS') = 4
                       and not exists (select 1 from verify_0009zk where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('223_verify_subscription_moves_entry: %s PASS, %s FAIL', (select count(*) from verify_0009zk where result = 'PASS'),
                                                                           (select count(*) from verify_0009zk where result not in ('PASS', 'REFUSED')))) x
order by ord;
reset role;
