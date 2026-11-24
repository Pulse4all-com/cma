-- =============================================================================================
-- 233_verify_intake_call_center.sql: verifies addition 0009zp, Intake's lead deals in and closed and other deals in
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Two kinds of checks:
--   on a throwaway tenant (B): invented pipelines and deals written straight into the tables as the owner, the whole step
--     rolled back; every rule of decision 1 and 2 has a deal of its own;
--   on every active tenant (R): the new function against its rules and against the definitions it must agree with
--     (132's, kept below; cma.lead_deals_of), over the last 92 days, as the owner (the functions take the tenant), in
--     steps that read only.
-- Run as your own IAM login, after 232. Output: tenant slugs, business dates, market codes, counts and check names; no
-- record id of a real tenant.
--
-- The throwaway tenant (zone Europe/Amsterdam, intake.start_date 2026-09-01, market NL). Deal pipelines: lead (lead),
-- order (no lead, order), both (lead and order), nolead (neither), off (lead, not counted); no row for the pipeline new
-- (not yet seen). Ticket pipeline support. Times are UTC; 09:00 UTC is the same date in Amsterdam.
--   d1  lead    NL  created 2026-09-10 09:00, open
--   d2  lead    NL  created 2026-09-10 09:00, closed 2026-09-11 09:00
--   d3  order   NL  created and closed 2026-09-10 09:00
--   d4  both    NL  created 2026-09-10 09:00
--   d5  new     NL  created 2026-09-10 09:00
--   d6  nolead  NL  created 2026-09-10 09:00
--   d7  off     NL  created 2026-09-10 09:00                       (not counted)
--   d8  lead    NL  created 2026-09-10 09:00, deleted              (not counted)
--   d9  lead    NL  created 2026-08-20 09:00 (before the start), closed 2026-09-11 09:00
--   d10 order   --  created and closed 2026-09-11 09:00            (no market: unknown)
--   d11 lead    --  its contact's country nl, created 2026-09-09 22:30 (00:30 on 10 September in Amsterdam)
--   t1  support NL  ticket created 2026-09-10 09:00
-- Expected, per date and market: deals in, lead deals in, other deals in, deals closed, lead deals closed, tickets in
--   2026-09-10 NL       7 5 2  1 0  1      (lead: d1 d2 d4 d5 d11; other: d3 d6; closed: d3)
--   2026-09-11 NL       0 0 0  2 2  0      (closed: d2 d9, both lead)
--   2026-09-11 unknown  1 0 1  1 0  0      (d10)
--
-- Checks
--   S1  the addition 0009zp is recorded once, after 0009zo
--   S2  cma.intake_per_day_row has eighteen attributes, its last three lead_deals_created, lead_deals_closed and
--       other_deals_created (integer) after the fifteen earlier ones unchanged; cma_read.intake_per_day_v ends with the
--       same three and the readers may read it
--   S3  cma.intake_per_day_of: jit = off, the caller's rights, the application's to execute, not public's;
--       cma.intake_per_day likewise without the setting; cma_read.intake_per_day_rows(): the owner's rights with its
--       search path, the readers' to execute, not public's nor the application's
--   B1  the throwaway tenant's rows equal the expectation above (decision 1: lead, both and a pipeline not yet seen are
--       lead pipelines; decision 2: order and nolead are not; off, a deleted deal and a deal before the start are not
--       counted; a closing after the start counts whenever the deal was created; the tenant's zone dates d11)
--   B2  the throwaway tenant's lead deals in per date and market equal cma.lead_deals_of's deals
--   R1  per active tenant: every row has lead_deals_created + other_deals_created = deals_created and
--       lead_deals_closed <= deals_closed, none of the three null
--   R2  per active tenant: the fifteen earlier columns equal 132's definition (kept below) row for row
--   R3  per active tenant: lead_deals_created per business date and market equals the count of cma.lead_deals_of over
--       the same range
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id:
-- that check alone fails. S and B checks carry a deliberate difference in their expectation; R1 adds one to every row's
-- other deals in, so the rule itself must catch it; R2 and R3 drop the previous side's first row, so the comparison
-- itself must find the difference (a compare of no rows reads FAIL under the switch).
-- Collation: every ordering that feeds a compared text says collate "C".
-- Expected verdict: "PASS | 233_verify_intake_call_center: <n> PASS, 0 FAIL, <k> skip".
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'R2'

drop table if exists pg_temp.verify_0009zp;
create temporary table verify_0009zp (ord integer, check_name text, result text, detail text);

create or replace function pg_temp.v0009zp_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0009zp_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009zp_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009zp values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 600)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 2400) end);
end
$$;

-- Two reads compared row for row and in order (231's comparison); provoked for the check, the previous side loses its
-- first row. Null when equal, otherwise what differs
create or replace function pg_temp.v0009zp_diff(p_id text, p_new text, p_old text)
returns text
language plpgsql
as $$
declare
  v_old text := p_old;
  v_n_new bigint; v_n_old bigint; v_only_new bigint; v_only_old bigint; v_same boolean;
begin
  if pg_temp.v0009zp_p(p_id) then
    v_old := format('select * from (%s) z offset 1', p_old);
  end if;
  execute format('select count(*) from (%s) a', p_new) into v_n_new;
  execute format('select count(*) from (%s) a', v_old) into v_n_old;
  if pg_temp.v0009zp_p(p_id) and v_n_new = 0 then
    return 'provoked, but the set is empty: nothing to differ (FAIL by the switch)';
  end if;
  execute format('select (select string_agg(a::text, ''|'' order by a.o) from (select row_number() over () as o, t from (%s) t) a) is not distinct from
                         (select string_agg(b::text, ''|'' order by b.o) from (select row_number() over () as o, t from (%s) t) b)', p_new, v_old) into v_same;
  execute format('select count(*) from ((%s) except all (%s)) a', p_new, v_old) into v_only_new;
  execute format('select count(*) from ((%s) except all (%s)) a', v_old, p_new) into v_only_old;
  if v_only_new = 0 and v_only_old = 0 and v_same then
    return null;
  end if;
  return format('new %s rows, previous %s; only in new %s, only in previous %s; same order %s', v_n_new, v_n_old, v_only_new, v_only_old, v_same);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- The previous definition, kept to compare with (R2): 132_perf.sql's cma.intake_per_day_of, its fifteen columns
-- ---------------------------------------------------------------------------------------------
create or replace function pg_temp.old_intake_per_day_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (tenant_id uuid, business_date date, market text, form_submissions integer, deals_created integer,
               deals_closed integer, tickets_created integer, tickets_closed integer, calls_in integer, calls_out integer,
               tagged_calls integer, new_customers integer, first_orders integer, repeat_orders integer, renewals integer)
language sql stable
as $$
  with s as (
    select t.timezone as zone,
           greatest(coalesce(p_from, '-infinity'::timestamptz),
                    cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone) as from_at,
           coalesce(p_to, 'infinity'::timestamptz) as to_at
    from cma.tenant t where t.id = p_tenant_id
  ),
  codes as materialized (
    select * from cma.market_codes_of(p_tenant_id)
  ),
  e as (
    select fs.submitted_at as at, coalesce(cma.market_code_of(p_tenant_id, f.market), 'unknown') as market, 'form' as metric
    from cma.form_submission fs
    join cma.connection_form f
      on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
    where fs.tenant_id = p_tenant_id and f.is_counted and cma.form_is_lead(f.lead_condition, fs.kept_values)
      and fs.submitted_at >= (select s.from_at from s) and fs.submitted_at < (select s.to_at from s)
    union all
    select x.at, coalesce(cr.code, cc.code, 'unknown'), x.metric
    from (select cr.*, cr.source_created_at as at, cr.record_type || '_created' as metric
          from cma.crm_record cr
          union all
          select cr.*, cr.closed_at, cr.record_type || '_closed'
          from cma.crm_record cr where cr.is_closed and cr.closed_at is not null) x
    left join cma.connection_pipeline p
      on p.tenant_id = x.tenant_id and p.connection_id = x.connection_id
     and p.record_type = x.record_type and p.source_pipeline_id = x.pipeline_id
    left join codes cr on cr.value = x.market
    left join cma.crm_contact k on k.tenant_id = x.tenant_id and k.connection_id = x.connection_id and k.source_id = x.contact_source_id
    left join codes cc on cc.value = k.country
    where x.tenant_id = p_tenant_id and x.record_type in ('deal', 'ticket') and x.source_deleted_at is null
      and coalesce(p.is_counted, true) and x.at >= (select s.from_at from s) and x.at < (select s.to_at from s)
    union all
    select tc.started_at, coalesce(nc.code, 'unknown'), m.metric
    from cma.telephony_call tc
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join codes nc on nc.value = n.market
    cross join lateral (
      select case tc.direction when 'inbound' then 'call_in' else 'call_out' end as metric
      union all
      select 'call_tagged'
      where exists (select 1 from cma.telephony_call_tag ct
                    left join cma.telephony_tag tg
                      on tg.tenant_id = ct.tenant_id and tg.connection_id = ct.connection_id and tg.tag_ref = ct.tag_ref
                    where ct.tenant_id = tc.tenant_id and ct.connection_id = tc.connection_id
                      and ct.call_source_id = tc.source_id and ct.untagged_at is null and coalesce(tg.is_counted, true))) m
    where tc.tenant_id = p_tenant_id and tc.source_deleted_at is null and coalesce(n.is_counted, true)
      and tc.started_at >= (select s.from_at from s) and tc.started_at < (select s.to_at from s)
    union all
    select cu.source_created_at, coalesce(sc.code, 'unknown'), 'customer'
    from cma.commerce_customer cu
    left join cma.commerce_store st on st.tenant_id = cu.tenant_id and st.connection_id = cu.connection_id
    left join codes sc on sc.value = st.market
    where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null
      and cu.source_created_at >= (select s.from_at from s) and cu.source_created_at < (select s.to_at from s)
    union all
    select co.source_created_at, coalesce(sc.code, 'unknown'), 'order_' || co.order_kind
    from cma.commerce_order co
    left join cma.commerce_store st on st.tenant_id = co.tenant_id and st.connection_id = co.connection_id
    left join codes sc on sc.value = st.market
    where co.tenant_id = p_tenant_id and co.source_deleted_at is null and not co.is_test and co.cancelled_at is null
      and co.source_created_at >= (select s.from_at from s) and co.source_created_at < (select s.to_at from s)
  )
  select p_tenant_id, (e.at at time zone (select s.zone from s))::date, e.market,
         (count(*) filter (where e.metric = 'form'))::integer,
         (count(*) filter (where e.metric = 'deal_created'))::integer,
         (count(*) filter (where e.metric = 'deal_closed'))::integer,
         (count(*) filter (where e.metric = 'ticket_created'))::integer,
         (count(*) filter (where e.metric = 'ticket_closed'))::integer,
         (count(*) filter (where e.metric = 'call_in'))::integer,
         (count(*) filter (where e.metric = 'call_out'))::integer,
         (count(*) filter (where e.metric = 'call_tagged'))::integer,
         (count(*) filter (where e.metric = 'customer'))::integer,
         (count(*) filter (where e.metric = 'order_first'))::integer,
         (count(*) filter (where e.metric = 'order_repeat'))::integer,
         (count(*) filter (where e.metric = 'order_renewal'))::integer
  from e
  group by 2, 3
$$;

-- ---------------------------------------------------------------------------------------------
-- S1 to S3: the addition, the row and the functions
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_txt text;
begin
  -- S1
  select count(*)::text || ' ' || coalesce(bool_and(m.applied_at >= (select o.applied_at from cma.schema_migration o where o.version = '0009zo'))::text, 'none')
  into v_txt from cma.schema_migration m where m.version = '0009zp';
  perform pg_temp.v0009zp_row(1, 'S1', 'the addition 0009zp is recorded once, after 0009zo', v_txt, '1 true');

  -- S2
  select count(*)::text || ' ' || string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum)
           filter (where a.attnum > 15)
         || ' | ' || md5(string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum) filter (where a.attnum <= 15))
  into v_txt
  from pg_attribute a
  where a.attrelid = (select typrelid from pg_type where oid = 'cma.intake_per_day_row'::regtype) and a.attnum > 0 and not a.attisdropped;
  v_txt := v_txt || ' | view ' || (select count(*)::text || ' ' || string_agg(c.column_name::text, ',' order by c.ordinal_position) filter (where c.ordinal_position > 15)
                                   from information_schema.columns c where c.table_schema = 'cma_read' and c.table_name = 'intake_per_day_v')
         || ' | readers ' || has_table_privilege('cma_readonly', 'cma_read.intake_per_day_v', 'select')::text;
  perform pg_temp.v0009zp_row(2, 'S2', 'the row and the readers'' view end with the three counts after the fifteen earlier columns',
    v_txt,
    '18 lead_deals_created:integer,lead_deals_closed:integer,other_deals_created:integer | '
    || md5('tenant_id:uuid,business_date:date,market:text,form_submissions:integer,deals_created:integer,deals_closed:integer,'
           || 'tickets_created:integer,tickets_closed:integer,calls_in:integer,calls_out:integer,tagged_calls:integer,'
           || 'new_customers:integer,first_orders:integer,repeat_orders:integer,renewals:integer')
    || ' | view 18 lead_deals_created,lead_deals_closed,other_deals_created | readers true');

  -- S3
  -- booleans cast to text: format's %s would print them as t and f
  select string_agg(format('%s: owner %s, definer %s, config %s, app %s, readers %s, public %s', f.sig, pg_get_userbyid(p.proowner), p.prosecdef::text,
                           coalesce(array_to_string(p.proconfig, ';'), '-'), has_function_privilege('cma_app', p.oid, 'execute')::text,
                           has_function_privilege('cma_readonly', p.oid, 'execute')::text,
                           (exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) x where x.grantee = 0 and x.privilege_type = 'EXECUTE'))::text),
                    ' / ' order by f.ord)
  into v_txt
  from (values (1, 'cma.intake_per_day_of(uuid,timestamptz,timestamptz)'), (2, 'cma.intake_per_day(date,date)'),
               (3, 'cma_read.intake_per_day_rows()')) f(ord, sig)
  join pg_proc p on p.oid = f.sig::regprocedure;
  perform pg_temp.v0009zp_row(3, 'S3', 'the functions: settings, rights and grants',
    v_txt,
    'cma.intake_per_day_of(uuid,timestamptz,timestamptz): owner cma_owner, definer false, config jit=off, app true, readers false, public false / '
    || 'cma.intake_per_day(date,date): owner cma_owner, definer false, config -, app true, readers false, public false / '
    || 'cma_read.intake_per_day_rows(): owner cma_owner, definer true, config search_path=pg_catalog, cma, pg_temp, app false, readers true, public false');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B1, B2: the throwaway tenant, rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_t uuid; v_crm uuid;
  v_b1 text; v_b2a text; v_b2b text; v_err text;
begin
  begin
    v_t := cma.create_tenant('verify-0009zp', 'Verify 0009zp', 'Europe/Amsterdam');
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency) values (v_t, 'NL', 'NL', 'Europe/Amsterdam', 'nl', 'EUR');
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'intake.start_date', '2026-09-01');
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifycrm', 'Verify 0009zp CRM', 'portal-v', 'crm') returning id into v_crm;
    insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted, is_lead, is_order)
    values (v_t, v_crm, 'deal', 'lead', 'Lead', true, true, false),
           (v_t, v_crm, 'deal', 'order', 'Order', true, false, true),
           (v_t, v_crm, 'deal', 'both', 'Both', true, true, true),
           (v_t, v_crm, 'deal', 'nolead', 'No lead', true, false, false),
           (v_t, v_crm, 'deal', 'off', 'Off', false, true, false),
           (v_t, v_crm, 'ticket', 'support', 'Support', true, true, false);
    insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country)
    values (v_t, v_crm, 'verifycrm', 'k11', 'nl');
    insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, contact_source_id, market,
                                is_closed, closed_at, source_created_at, source_deleted_at)
    values (v_t, v_crm, 'verifycrm', 'deal', 'd1', 'lead', null, 'NL', false, null, '2026-09-10 09:00+00', null),
           (v_t, v_crm, 'verifycrm', 'deal', 'd2', 'lead', null, 'NL', true, '2026-09-11 09:00+00', '2026-09-10 09:00+00', null),
           (v_t, v_crm, 'verifycrm', 'deal', 'd3', 'order', null, 'NL', true, '2026-09-10 09:00+00', '2026-09-10 09:00+00', null),
           (v_t, v_crm, 'verifycrm', 'deal', 'd4', 'both', null, 'NL', false, null, '2026-09-10 09:00+00', null),
           (v_t, v_crm, 'verifycrm', 'deal', 'd5', 'new', null, 'NL', false, null, '2026-09-10 09:00+00', null),
           (v_t, v_crm, 'verifycrm', 'deal', 'd6', 'nolead', null, 'NL', false, null, '2026-09-10 09:00+00', null),
           (v_t, v_crm, 'verifycrm', 'deal', 'd7', 'off', null, 'NL', false, null, '2026-09-10 09:00+00', null),
           (v_t, v_crm, 'verifycrm', 'deal', 'd8', 'lead', null, 'NL', false, null, '2026-09-10 09:00+00', '2026-09-12 09:00+00'),
           (v_t, v_crm, 'verifycrm', 'deal', 'd9', 'lead', null, 'NL', true, '2026-09-11 09:00+00', '2026-08-20 09:00+00', null),
           (v_t, v_crm, 'verifycrm', 'deal', 'd10', 'order', null, null, true, '2026-09-11 09:00+00', '2026-09-11 09:00+00', null),
           (v_t, v_crm, 'verifycrm', 'deal', 'd11', 'lead', 'k11', null, false, null, '2026-09-09 22:30+00', null),
           (v_t, v_crm, 'verifycrm', 'ticket', 't1', 'support', null, 'NL', false, null, '2026-09-10 09:00+00', null);

    select string_agg(format('%s %s %s %s %s %s %s %s', r.business_date, r.market, r.deals_created, r.lead_deals_created, r.other_deals_created,
                             r.deals_closed, r.lead_deals_closed, r.tickets_created), ' | ' order by r.business_date, r.market collate "C")
    into v_b1 from cma.intake_per_day_of(v_t, null, null) r;
    select string_agg(format('%s %s %s', r.business_date, r.market, r.lead_deals_created), ' | ' order by r.business_date, r.market collate "C")
    into v_b2a from cma.intake_per_day_of(v_t, null, null) r where r.lead_deals_created > 0;
    select string_agg(format('%s %s %s', d.business_date, d.market, d.n), ' | ' order by d.business_date, d.market collate "C")
    into v_b2b from (select l.business_date, l.market, count(*) as n from cma.lead_deals_of(v_t, null, null) l group by 1, 2) d;
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
  end;
  perform pg_temp.v0009zp_row(10, 'B1', 'the throwaway tenant: lead, both and a pipeline not yet seen are lead; order and nolead are other; off, deleted and before the start not counted',
    coalesce(v_err, v_b1), '2026-09-10 NL 7 5 2 1 0 1 | 2026-09-11 NL 0 0 0 2 2 0 | 2026-09-11 unknown 1 0 1 1 0 0');
  perform pg_temp.v0009zp_row(11, 'B2', 'the throwaway tenant: lead deals in per date and market equal cma.lead_deals_of',
    coalesce(v_err, v_b2a || ' = ' || v_b2b), '2026-09-10 NL 5 = 2026-09-10 NL 5');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- R1 to R3: every active tenant, the last 92 days
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t record;
  v_from date;
  v_any boolean := false;
  v_n bigint; v_bad bigint; v_r text; v_err text;
  v_cols constant text := 'tenant_id, business_date, market, form_submissions, deals_created, deals_closed, tickets_created, '
    || 'tickets_closed, calls_in, calls_out, tagged_calls, new_customers, first_orders, repeat_orders, renewals';
begin
  for t in select id, slug from cma.tenant where status = 'active' and slug not like 'verify-%' order by slug collate "C" loop
    v_any := true;
    v_from := cma.tenant_today_of(t.id) - 91;

    -- R1: the rule on every row (provoked: one more other deal in on every row)
    v_n := null; v_bad := null; v_err := null;
    begin
      select count(*),
             count(*) filter (where r.lead_deals_created is null or r.lead_deals_closed is null or r.other_deals_created is null
                                 or r.lead_deals_created + r.other_deals_created + case when pg_temp.v0009zp_p('R1') then 1 else 0 end <> r.deals_created
                                 or r.lead_deals_closed > r.deals_closed
                                 or r.lead_deals_created < 0 or r.lead_deals_closed < 0 or r.other_deals_created < 0)
      into v_n, v_bad
      from cma.intake_per_day_of(t.id, v_from::timestamptz, null) r;
    exception when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
    end;
    insert into pg_temp.verify_0009zp values (20, 'R1 ' || t.slug || ': lead + other deals in = deals in, lead deals closed <= deals closed, on every row',
      case when v_err is null and v_bad = 0 and not (pg_temp.v0009zp_p('R1') and v_n = 0) then 'PASS' else 'FAIL' end,
      coalesce(v_err, format('%s rows, %s break the rule%s', v_n, v_bad,
                             case when pg_temp.v0009zp_p('R1') and v_n = 0 then ' (provoked, but no rows: FAIL by the switch)' else '' end)));

    -- R2: the fifteen earlier columns against 132's definition
    v_r := null; v_err := null;
    begin
      v_r := pg_temp.v0009zp_diff('R2',
        format('select %s from cma.intake_per_day_of(%L, %L::date::timestamptz, null) order by business_date, market collate "C"', v_cols, t.id, v_from),
        format('select %s from pg_temp.old_intake_per_day_of(%L, %L::date::timestamptz, null) order by business_date, market collate "C"', v_cols, t.id, v_from));
      if v_r is null then
        execute format('select ''equal, '' || count(*) || '' rows'' from cma.intake_per_day_of(%L, %L::date::timestamptz, null)', t.id, v_from) into v_r;
      end if;
    exception when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
    end;
    insert into pg_temp.verify_0009zp values (21, 'R2 ' || t.slug || ': the fifteen earlier columns equal 132''s definition, row for row',
      case when v_err is null and v_r like 'equal, %' then 'PASS' else 'FAIL' end, coalesce(v_err, v_r));

    -- R3: lead deals in against cma.lead_deals_of, per business date and market
    v_r := null; v_err := null;
    begin
      v_r := pg_temp.v0009zp_diff('R3',
        format('select business_date, market, lead_deals_created::bigint as n from cma.intake_per_day_of(%L, %L::date::timestamptz, null) '
               || 'where lead_deals_created > 0 order by business_date, market collate "C"', t.id, v_from),
        format('select business_date, market, count(*) as n from cma.lead_deals_of(%L, %L::date::timestamptz, null) '
               || 'group by business_date, market order by business_date, market collate "C"', t.id, v_from));
      if v_r is null then
        execute format('select ''equal, '' || count(*) || '' dates and markets, '' || coalesce(sum(lead_deals_created), 0) || '' lead deals in'' '
                       || 'from cma.intake_per_day_of(%L, %L::date::timestamptz, null) where lead_deals_created > 0', t.id, v_from) into v_r;
      end if;
    exception when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
    end;
    insert into pg_temp.verify_0009zp values (22, 'R3 ' || t.slug || ': lead deals in per date and market equal cma.lead_deals_of',
      case when v_err is null and v_r like 'equal, %' then 'PASS' else 'FAIL' end, coalesce(v_err, v_r));
  end loop;
  if not v_any then
    insert into pg_temp.verify_0009zp values (20, 'R per tenant',
      case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end, 'no active tenant');
  end if;
end
$$;

drop function if exists pg_temp.old_intake_per_day_of(uuid, timestamptz, timestamptz);
drop function if exists pg_temp.v0009zp_diff(text, text, text);
drop function if exists pg_temp.v0009zp_row(integer, text, text, text, text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009zp
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009zp where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009zp where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('233_verify_intake_call_center: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009zp where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009zp where result = 'FAIL'), (select count(*) from pg_temp.verify_0009zp where result = 'skip'))) x
order by ord, check_name collate "C";
drop function if exists pg_temp.v0009zp_p(text);
drop table if exists pg_temp.verify_0009zp;
reset role;
