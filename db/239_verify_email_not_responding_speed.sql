-- =============================================================================================
-- 239_verify_email_not_responding_speed.sql: verifies addition 0009zs, Email's deals not responding in one read per branch
-- (brief N07, PR N07c)
-- =============================================================================================
-- Universal: no seed is assumed; read only (the comparisons write nothing, print counts, never a row). Run as your own
-- IAM login after 238_email_not_responding_speed.sql, dev first, then prod. Expected: E1 to E3 OK, then "PASS 0009zs".
-- Provoked (verify.provoke true at the top): every row FAIL, the verdict PROVOKED, NOT A PASS, and E2 compares with a
-- deliberate difference (one deal left out of 100's side), which its detail shows.
--
--   E1  0009zs recorded after 0009zr; cma.email_not_responding_of the application's only (not public)
--   E2  cma.email_not_responding_of equals 100's definition (kept below) row for row for every active tenant, now
--   E3  the same thirty days on (p_now now() + 30 days: the deals whose last email is older by then come in), row for row
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every check fail

drop table if exists pg_temp.verify_0009zs;
create temporary table verify_0009zs (ord integer, check_name text, result text, detail text);

create or replace function pg_temp.v9zs_row(p_ord integer, p_id text, p_name text, p_ok boolean, p_detail text)
returns void
language sql
as $$
  insert into pg_temp.verify_0009zs
  select p_ord, p_id || ' ' || p_name,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then 'OK' else 'FAIL' end,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then coalesce(p_detail, '')
              else 'FAIL ' || p_id || ': ' || case when current_setting('verify.provoke')::boolean then 'provoked; ' else '' end
                   || coalesce(p_detail, '(no detail)') end
$$;

-- 100's definition, verbatim
create or replace function pg_temp.v9zs_enr_100(p_tenant_id uuid, p_now timestamptz default now())
returns table (
  connection_id     uuid,
  deal_source_id    text,
  pipeline_label    text,
  market            text,
  owner_ref         text,
  source_system     text,
  last_email_at     timestamptz,
  days_since        integer
)
language sql stable
as $$
  with s as (
    select cma.setting_of(t.id, 'email.no_response_days')::integer as days from cma.tenant t where t.id = p_tenant_id
  ),
  d as (
    select l.* from cma.lead_deals_of(p_tenant_id, null, null) l where not l.is_closed and cardinality(l.contacts) > 0
  ),
  last_out as (
    select d.deal_id, max(m.occurred_at) as at
    from d
    join cma.email_message m
      on m.tenant_id = p_tenant_id and m.connection_id = d.connection_id and m.contact_source_id = any (d.contacts)
    join cma.integration_connection c on c.tenant_id = m.tenant_id and c.id = m.connection_id
    left join cma.email_thread th
      on m.source_kind = 'inbox_message' and th.tenant_id = m.tenant_id and th.connection_id = m.connection_id
     and th.source_id = m.thread_source_id
    where m.direction = 'out' and m.status = 'sent' and m.source_deleted_at is null
      and case when m.source_kind = 'crm_email'
               then not (lower(coalesce(m.origin, '')) = any (cma.setting_codes(c.settings, 'email_inbox_copy_origins')))
                    and not (lower(coalesce(m.origin, '')) = any (cma.setting_codes(c.settings, 'email_automated_origins')))
               else m.actor_kind = 'agent' and not coalesce(th.is_spam, false) end
    group by d.deal_id
  )
  select d.connection_id, d.source_id, d.pipeline_label, d.market, d.owner_ref, d.source_system, lo.at,
         floor(extract(epoch from p_now - lo.at) / 86400)::integer
  from d
  join last_out lo on lo.deal_id = d.deal_id
  cross join s
  where lo.at <= p_now - make_interval(days => s.days)
    and not exists (
      select 1 from cma.email_message m
      where m.tenant_id = p_tenant_id and m.connection_id = d.connection_id and m.contact_source_id = any (d.contacts)
        and m.direction in ('in', 'forwarded') and m.source_deleted_at is null and m.occurred_at > lo.at)
    and not exists (
      select 1
      from cma.crm_association a
      join cma.crm_call cc on cc.tenant_id = a.tenant_id and cc.connection_id = a.connection_id and cc.source_id = a.from_id
      cross join lateral cma.crm_call_conversation_of(p_tenant_id, cc.id) k
      where a.tenant_id = p_tenant_id and a.connection_id = d.connection_id and a.from_type = 'crm_call' and a.removed_at is null
        and ((a.to_type = 'contact' and a.to_id = any (d.contacts)) or (a.to_type = 'deal' and a.to_id = d.source_id))
        and cc.source_deleted_at is null and k.is_conversation and k.effective_at > lo.at)
  order by lo.at, d.source_id
$$;

do $$
declare
  t     record;
  ok1   boolean;
  n2    integer := 0;
  n3    integer := 0;
  rows2 integer := 0;
  rows3 integer := 0;
  x     integer;
  v_at  timestamptz := now() + interval '30 days';
begin
  ok1 := (select a.applied_at >= b.applied_at from cma.schema_migration a, cma.schema_migration b where a.version = '0009zs' and b.version = '0009zr')
         and not has_function_privilege('public', 'cma.email_not_responding_of(uuid,timestamptz)', 'execute')
         and has_function_privilege('cma_app', 'cma.email_not_responding_of(uuid,timestamptz)', 'execute');
  perform pg_temp.v9zs_row(1, 'E1', 'structure', ok1, 'order and grants');
  for t in select y.id from cma.tenant y where y.status = 'active' order by y.slug collate "C" loop
    perform set_config('app.tenant_id', t.id::text, true);
    -- provoked: 100's side without its first deal, a deliberate difference the comparison must see
    select count(*) into x from (select * from cma.email_not_responding_of(t.id)
                                 except all
                                 select * from pg_temp.v9zs_enr_100(t.id) z
                                 where not current_setting('verify.provoke')::boolean
                                    or z.deal_source_id <> (select min(w.deal_source_id collate "C") from pg_temp.v9zs_enr_100(t.id) w)) a;
    n2 := n2 + x;
    select count(*) into x from (select * from pg_temp.v9zs_enr_100(t.id) except all select * from cma.email_not_responding_of(t.id)) a;
    n2 := n2 + x;
    rows2 := rows2 + (select count(*) from cma.email_not_responding_of(t.id));
    select count(*) into x from (select * from cma.email_not_responding_of(t.id, v_at) except all select * from pg_temp.v9zs_enr_100(t.id, v_at)) a;
    n3 := n3 + x;
    select count(*) into x from (select * from pg_temp.v9zs_enr_100(t.id, v_at) except all select * from cma.email_not_responding_of(t.id, v_at)) a;
    n3 := n3 + x;
    rows3 := rows3 + (select count(*) from cma.email_not_responding_of(t.id, v_at));
  end loop;
  perform pg_temp.v9zs_row(2, 'E2', 'equals 100 now', n2 = 0, format('%s rows differ over %s deals not responding', n2, rows2));
  perform pg_temp.v9zs_row(3, 'E3', 'equals 100 thirty days on', n3 = 0, format('%s rows differ over %s deals', n3, rows3));
end
$$;

drop function if exists pg_temp.v9zs_enr_100(uuid, timestamptz);
drop function if exists pg_temp.v9zs_row(integer, text, text, boolean, text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009zs
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009zs where result <> 'OK') then 'FAIL'
                  when (select count(*) from pg_temp.verify_0009zs where result = 'OK') <> 3 then 'FAIL'
                  else 'PASS 0009zs' end,
             format('239_verify_email_not_responding_speed: %s OK, %s FAIL', (select count(*) from pg_temp.verify_0009zs where result = 'OK'),
                    (select count(*) from pg_temp.verify_0009zs where result <> 'OK'))) x
order by ord;
reset role;
