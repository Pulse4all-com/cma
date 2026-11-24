-- =============================================================================================
-- diagnose_0009zq_prod.sql: why 179 E6 and 191 E4 read FAIL in prod after addition 0009zq (234), and in no other
-- database (24 November 2026; #316). A diagnostic, not a migration and not a verify: it changes nothing.
-- =============================================================================================
-- One transaction at REPEATABLE READ, rolled back at the end: every statement in it reads the same snapshot of the data.
-- It is not READ ONLY because it makes temporary functions and a temporary table (pg_temp only); the rollback drops them
-- and nothing else is written. Run as your own IAM login, from the Terminal (see the PR), for pulse4all-subscriptions.
-- Output: one row per finding, as 179's and 191's rows (check_name | result | detail); ids, keys, statuses and times
-- only (a data-quality value is shown as the first 8 characters of its md5, never as itself).
--
-- What it answers
--   E6  179's E6 compares cma.flash_findings_compute_of with its old copy (132's text, kept in 179) through
--       pg_temp.v0009o_diff, which runs four statements (two counts, two except all); in READ COMMITTED each statement
--       takes a fresh snapshot, so a finding whose inputs are written between them can differ although both functions
--       agree. Here both sides are computed once, under one snapshot: the rows that still differ are listed (side, check
--       key, object type and id, connection, market, fix_in, the value's md5 prefix), and for a pair that differs in
--       some column only, which columns. No row here means the FAIL came from data written during 179's run.
--       0009zq re-creates no function flash_findings_compute_of reads (its call graph reaches data_quality_of,
--       lead_deals_of, counted_deals_of, open_tickets_of, open_tasks_of and others, none of them re-created by 234).
--   E4  191's E4 computes the items a follow-up refresh would store at the next weekday 11:06 UTC and a minute later in
--       two statements (two snapshots). Here both instants are computed in one statement: the items whose stored row
--       changed in a key other than the day counts while their state stayed are listed (kind, item id, key, value at
--       11:06, value at 11:07), with the lead's speed-to-lead status, window end and why (close, first order or open)
--       and market. No row here means the FAIL came from data written during 191's run.
--   W   the writes the audit log holds for the tenant in the 30 minutes before this run, per table (counts only): what
--       was moving while 179 and 191 ran.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

begin isolation level repeatable read;
set local role cma_owner;
select set_config('verify.provoke', 'false', true);
create temporary table diag_0009zq (ord integer, check_name text, result text, detail text) on commit drop;
grant select, insert on pg_temp.diag_0009zq to cma_app;

-- 179's old copy of cma.flash_findings_compute_of (132's text), verbatim but for its name
create or replace function pg_temp.d9zq_old_flash_findings_compute_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text, market text, fix_in text, fix_adapter text)
language sql stable
as $$
  with f as materialized (
    select q.* from cma.data_quality_of(p_tenant_id) q
  ), c as materialized (
    select ic.id, ic.adapter, coalesce(ic.kind, (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1]) as kind, ic.status
    from cma.integration_connection ic where ic.tenant_id = p_tenant_id
  ), ka as materialized (
    select distinct on (c.kind) c.kind, c.adapter from c where c.status = 'active' and c.kind is not null order by c.kind, c.id
  ), st as materialized (
    select x.connection_id, x.market from cma.commerce_store x where x.tenant_id = p_tenant_id
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  )
  select f.check_key, f.connection_id, f.object_type, f.object_id, f.value,
         coalesce(case f.object_type
                    when 'commerce_customer' then st.market
                    when 'subscription' then sm.market
                    when 'market' then f.object_id
                    when 'device' then (select d.market from cma.device d
                                        where d.tenant_id = p_tenant_id and d.connection_id = f.connection_id and d.source_id = f.object_id)
                    when 'contact' then (select cma.market_code_of(p_tenant_id, k.country) from cma.crm_contact k
                                         where k.tenant_id = p_tenant_id and k.connection_id = f.connection_id and k.source_id = f.object_id)
                    when 'form' then (select cf.market from cma.connection_form cf
                                      where cf.tenant_id = p_tenant_id and cf.connection_id = f.connection_id and cf.source_form_id = f.object_id)
                    when 'review_channel' then (select ch.market from cma.review_channel ch
                                                where ch.tenant_id = p_tenant_id and ch.connection_id = f.connection_id and ch.source_id = f.object_id)
                    when 'deal' then (select coalesce(cma.market_code_of(p_tenant_id, r.market), cma.market_code_of(p_tenant_id, rk.country))
                                      from cma.crm_record r
                                      left join cma.crm_contact rk
                                        on rk.tenant_id = r.tenant_id and rk.connection_id = r.connection_id and rk.source_id = r.contact_source_id
                                      where r.tenant_id = p_tenant_id and r.connection_id = f.connection_id and r.record_type = 'deal'
                                        and r.source_id = f.object_id)
                    when 'ticket' then (select coalesce(cma.market_code_of(p_tenant_id, r.market), cma.market_code_of(p_tenant_id, rk.country))
                                        from cma.crm_record r
                                        left join cma.crm_contact rk
                                          on rk.tenant_id = r.tenant_id and rk.connection_id = r.connection_id and rk.source_id = r.contact_source_id
                                        where r.tenant_id = p_tenant_id and r.connection_id = f.connection_id and r.record_type = 'ticket'
                                          and r.source_id = f.object_id) end, 'unknown'),
         x.fix_in,
         case when x.fix_in = 'cma' then null when c1.kind = x.fix_in then c1.adapter else ka.adapter end
  from f
  cross join lateral (select cma.data_quality_fix_in(f.check_key, f.value) as fix_in) x
  left join c c1 on c1.id = f.connection_id
  left join ka on ka.kind = x.fix_in
  left join st on f.object_type = 'commerce_customer' and st.connection_id = f.connection_id
  left join sm on f.object_type = 'subscription' and sm.connection_id = f.connection_id
$$;

-- 191's copies with the clock as a parameter (made from the database's own definitions) and its items at an instant,
-- verbatim
do $$
declare
  d text;
  v_path text := current_setting('search_path');
begin
  -- every name qualified in the printed definitions
  perform set_config('search_path', 'pg_catalog', true);
  d := pg_get_functiondef('cma.open_tickets_of(uuid)'::regprocedure);
  if position('FUNCTION cma.open_tickets_of(p_tenant_id uuid)' in d) = 0 then raise exception 'open_tickets_of: unexpected header'; end if;
  d := replace(replace(d, 'FUNCTION cma.open_tickets_of(p_tenant_id uuid)', 'FUNCTION pg_temp.v0009u_open_tickets_at(p_tenant_id uuid, p_at timestamp with time zone)'),
               'now()', 'p_at');
  execute d;
  d := pg_get_functiondef('cma.speed_to_lead_of(uuid,timestamptz,timestamptz)'::regprocedure);
  if position('FUNCTION cma.speed_to_lead_of(p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)' in d) = 0 then
    raise exception 'speed_to_lead_of: unexpected header';
  end if;
  d := replace(replace(d, 'FUNCTION cma.speed_to_lead_of(p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)',
                          'FUNCTION pg_temp.v0009u_speed_to_lead_at(p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_at timestamp with time zone)'),
               'now()', 'p_at');
  execute d;
  d := pg_get_functiondef('cma.open_leads_of(uuid)'::regprocedure);
  if position('FUNCTION cma.open_leads_of(p_tenant_id uuid)' in d) = 0 or position('cma.speed_to_lead_of(p_tenant_id, NULL::timestamp with time zone, NULL::timestamp with time zone)' in d) = 0
     and position('cma.speed_to_lead_of(p_tenant_id, null, null)' in d) = 0 then
    raise exception 'open_leads_of: unexpected header or call';
  end if;
  d := replace(replace(replace(replace(d, 'FUNCTION cma.open_leads_of(p_tenant_id uuid)', 'FUNCTION pg_temp.v0009u_open_leads_at(p_tenant_id uuid, p_at timestamp with time zone)'),
                               'cma.speed_to_lead_of(p_tenant_id, NULL::timestamp with time zone, NULL::timestamp with time zone)',
                               'pg_temp.v0009u_speed_to_lead_at(p_tenant_id, NULL::timestamp with time zone, NULL::timestamp with time zone, p_at)'),
                       'cma.speed_to_lead_of(p_tenant_id, null, null)', 'pg_temp.v0009u_speed_to_lead_at(p_tenant_id, null, null, p_at)'),
               'now()', 'p_at');
  execute d;
  perform set_config('search_path', v_path, true);
end
$$;

create or replace function pg_temp.v0009u_items_at(p_tenant_id uuid, p_at timestamptz, p_shape text)
returns table (kind text, item_id uuid, sort_key integer, state text, item_row jsonb, print text)
language sql stable
as $$
  with x as (
    select 'lead'::text as kind, o.ordinality::integer as sort_key, o.deal_id as item_id, coalesce(nullif(o.market, ''), 'unknown') as market, o.owner_user_id,
           case when o.past_target then 'past_target' when o.past_target is false then 'within_target' else 'no_hours' end as state,
           case when p_shape = '0009u' then to_jsonb(o) - 'tenant_id' - 'ordinality' - 'waiting_business_seconds'
                else to_jsonb(o) - 'tenant_id' - 'ordinality' end as row
    from pg_temp.v0009u_open_leads_at(p_tenant_id, p_at) with ordinality o
    union all
    select 'ticket', o.ordinality::integer, o.ticket_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.sla_state,
           case when p_shape = '0009u' then to_jsonb(o) - 'tenant_id' - 'ordinality' - 'open_business_seconds' - 'minutes_to_breach'
                else to_jsonb(o) - 'tenant_id' - 'ordinality' end
    from pg_temp.v0009u_open_tickets_at(p_tenant_id, p_at) with ordinality o
  )
  select x.kind, x.item_id, x.sort_key, x.state, x.row, cma.follow_up_item_print(x.sort_key, x.market, x.owner_user_id, x.state, x.row) from x
$$;

do $$
declare
  v_t uuid := (select te.id from cma.tenant te where te.slug = 'pulse4all-subscriptions');
  v_sched text;
  v_day date; v_at timestamptz;
  v_ord integer := 0;
  n_now bigint; n_old bigint; n_only_now bigint; n_only_old bigint;
  r record;
  v_rows text[] := '{}';
begin
  if v_t is null then
    raise exception 'tenant pulse4all-subscriptions not found';
  end if;
  insert into diag_0009zq values (0, 'run', 'info', format('one snapshot (REPEATABLE READ) taken at %s UTC; 0009zq recorded %s',
    to_char(now() at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS'), exists (select 1 from cma.schema_migration where version = '0009zq')));

  -- as 179 and 191 read: the application, acting for the tenant as its Scheduler user
  v_sched := coalesce((select u.id::text from cma.app_user_external_id x
                       join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
                       where x.tenant_id = v_t and x.system = 'scheduler' and x.external_id = 'scheduler' and u.status = 'active' limit 1), '');
  perform set_config('app.tenant_id', v_t::text, true);
  perform set_config('app.user_id', v_sched, true);
  perform set_config('role', 'cma_app', true);

  -- E6: both sides once, in one snapshot
  create temporary table d9zq_now on commit drop as select * from cma.flash_findings_compute_of(v_t);
  create temporary table d9zq_old on commit drop as select * from pg_temp.d9zq_old_flash_findings_compute_of(v_t);
  select (select count(*) from d9zq_now), (select count(*) from d9zq_old),
         (select count(*) from (select * from d9zq_now except all select * from d9zq_old) x),
         (select count(*) from (select * from d9zq_old except all select * from d9zq_now) x)
    into n_now, n_old, n_only_now, n_only_old;
  v_ord := 10;
  insert into diag_0009zq values (v_ord, 'E6 flash_findings_compute_of against 179''s old copy, one snapshot (pulse4all-subscriptions)',
    case when n_only_now = 0 and n_only_old = 0 then 'same' else 'differ' end,
    format('%s rows now against %s before: %s only now, %s only before', n_now, n_old, n_only_now, n_only_old));
  for r in
    select 'only now' as side, x.* from (select * from d9zq_now except all select * from d9zq_old) x
    union all
    select 'only before', x.* from (select * from d9zq_old except all select * from d9zq_now) x
    order by 2, 3, 4, 5, 1
  loop
    v_ord := v_ord + 1;
    insert into diag_0009zq values (v_ord, 'E6 ' || r.side, 'row',
      format('check %s | %s %s | connection %s | market %s | fix_in %s | value md5 %s', r.check_key, coalesce(r.object_type, '-'), coalesce(r.object_id, '-'),
             coalesce(r.connection_id::text, '-'), coalesce(r.market, '-'), coalesce(r.fix_in, '-'), coalesce(left(md5(r.value), 8), '-')));
  end loop;
  -- a pair present on both sides with the same check and object: the columns that differ
  for r in
    select a.check_key, a.object_type, a.object_id,
           concat_ws(', ', case when a.connection_id is distinct from b.connection_id then 'connection_id' end,
                           case when a.value is distinct from b.value then 'value' end,
                           case when a.market is distinct from b.market then 'market' end,
                           case when a.fix_in is distinct from b.fix_in then 'fix_in' end,
                           case when a.fix_adapter is distinct from b.fix_adapter then 'fix_adapter' end) as cols
    from (select * from d9zq_now except all select * from d9zq_old) a
    join (select * from d9zq_old except all select * from d9zq_now) b
      on b.check_key = a.check_key and b.object_type is not distinct from a.object_type and b.object_id is not distinct from a.object_id
    order by 1, 2, 3
  loop
    v_ord := v_ord + 1;
    insert into diag_0009zq values (v_ord, 'E6 pair', 'differs in', format('check %s | %s %s | %s', r.check_key, coalesce(r.object_type, '-'), coalesce(r.object_id, '-'), r.cols));
  end loop;

  -- E4: 191's instants, both in one statement
  v_day := (now() at time zone 'UTC')::date + 1;
  while extract(isodow from v_day) in (6, 7) loop v_day := v_day + 1; end loop;
  v_at := (v_day + time '11:06') at time zone 'UTC';
  create temporary table d9zq_items on commit drop as
    select 'a'::text as side, * from pg_temp.v0009u_items_at(v_t, v_at, '0009u')
    union all
    select 'b', * from pg_temp.v0009u_items_at(v_t, v_at + interval '1 minute', '0009u');
  v_ord := 100;
  insert into diag_0009zq
  select v_ord, 'E4 a minute of office hours, one snapshot (pulse4all-subscriptions)',
         case when count(*) filter (where a.state = b.state and (a.item_row - 'age_business_days' - 'bucket_from' - 'bucket_to' - 'last_call_days')
                                                           <> (b.item_row - 'age_business_days' - 'bucket_from' - 'bucket_to' - 'last_call_days')) = 0
              then 'same' else 'differ' end,
         format('%s to %s UTC, %s items: %s with another key moved', to_char(v_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI'),
                to_char((v_at + interval '1 minute') at time zone 'UTC', 'HH24:MI'), count(*),
                count(*) filter (where a.state = b.state and (a.item_row - 'age_business_days' - 'bucket_from' - 'bucket_to' - 'last_call_days')
                                                         <> (b.item_row - 'age_business_days' - 'bucket_from' - 'bucket_to' - 'last_call_days')))
  from (select * from d9zq_items where side = 'a') a
  join (select * from d9zq_items where side = 'b') b on b.kind = a.kind and b.item_id = a.item_id;
  for r in
    select a.kind, a.item_id, k.key, a.item_row -> k.key as at_a, b.item_row -> k.key as at_b
    from (select * from d9zq_items where side = 'a') a
    join (select * from d9zq_items where side = 'b') b on b.kind = a.kind and b.item_id = a.item_id
    cross join lateral jsonb_object_keys(a.item_row - 'age_business_days' - 'bucket_from' - 'bucket_to' - 'last_call_days') k(key)
    where a.state = b.state and (a.item_row -> k.key) is distinct from (b.item_row -> k.key)
    order by 1, 2, 3
  loop
    v_ord := v_ord + 1;
    insert into diag_0009zq values (v_ord, 'E4 moved', r.kind,
      format('item %s | key %s | at 11:06 %s | at 11:07 %s', r.item_id, r.key, coalesce(r.at_a::text, 'null'), coalesce(r.at_b::text, 'null')));
    if r.kind = 'lead' then
      v_ord := v_ord + 1;
      insert into diag_0009zq
      select v_ord, 'E4 moved lead', 'deal',
             format('deal %s | speed to lead %s | window end %s (%s) | market %s',
                    r.item_id, coalesce(s.status, '-'), coalesce(to_char(w.window_end at time zone 'UTC', 'YYYY-MM-DD HH24:MI'), '-'),
                    coalesce(w.window_end_reason, '-'), coalesce(s.market, '-'))
      from (select 1) one
      left join cma.speed_to_lead_of(v_t, null, null) s on s.deal_id = r.item_id
      left join cma.sales_deals_of(v_t, null, null, now()) w on w.deal_id = r.item_id;
    end if;
  end loop;

  -- W: what was written for the tenant in the 30 minutes before this snapshot, per table (counts only), as the owner
  perform set_config('role', 'cma_owner', true);
  v_ord := 200;
  for r in
    select a.table_name, count(*) as n, max(a.changed_at) as last_at
    from cma.audit_log a
    where a.tenant_id = v_t and a.changed_at >= now() - interval '30 minutes'
    group by a.table_name
    order by count(*) desc, a.table_name
    limit 20
  loop
    v_ord := v_ord + 1;
    insert into diag_0009zq values (v_ord, 'W writes in the 30 minutes before', r.table_name,
      format('%s rows, the last at %s UTC', r.n, to_char(r.last_at at time zone 'UTC', 'HH24:MI:SS')));
  end loop;
end
$$;

select check_name, result, detail from diag_0009zq order by ord;

rollback;
