-- =============================================================================================
-- 235_verify_speed_to_lead_one.sql: verifies addition 0009zq, speed to lead in one definition and one function
-- (24 November 2026; brief B40a)
-- =============================================================================================
-- Universal: no seed is assumed. V1 checks the structure on the database itself; V2 to V13 work on two throwaway tenants
-- inside a subtransaction that is always rolled back, so nothing stays and the script runs in dev and in prod. Synthetic
-- data only (example.invalid people, invented ids, no name, address or phone number of anyone). The fixed instants are
-- the week of Monday 5 October 2026 (Europe/Amsterdam, UTC+2); two deals of a market open around the clock are placed
-- relative to now() for the checks that turn on the clock (V5). Every check writes one row, OK or FAIL (its detail then
-- starts "FAIL V<n>"), because Cloud SQL Studio shows no notices; the block ends with a row of its own ("ran to the
-- end"), which the verdict requires, so a block that an error ended reads FAIL. Run as your own IAM login after
-- 234_speed_to_lead_one.sql, dev first, then prod.
-- Edited by 0009zr (236, night N07, 25 November 2026): V1 and V11 read the one definition's body in
-- cma.speed_to_lead_rows_of when it exists (236 moved it there, with an open-only bound cma.open_leads_of passes as true);
-- the checks are otherwise unchanged.
-- Expected: V1 to V13 OK, then the verdict "PASS 0009zq". Provoked (verify.provoke true at the top): every row reads
-- FAIL with its own id, and the verdict PROVOKED, NOT A PASS.
--
--   V1  structure: 0009zq recorded after 0009zp (main's Intake); cma.speed_to_lead_row ends in first_attempt_call_id, first_attempt_at,
--       attempts_so_far, deal_owner_user_id (34 columns, every earlier name kept) and cma_read.speed_to_lead has the
--       same columns in the same order; cma.speed_to_lead_of names closed_before_first_call and no longer
--       not_called_closed, and the fixture's rows hold exactly the three status values; the setting
--       speed_to_lead.next_day_cutoff (time, 12:00); the summary's four-argument form and the cutoff form of
--       cma.next_business_noon_in the application's only, the replaced forms gone
--   V2  a CRM call without a telephony call before an Aircall attempt (dA): the end is the attempt (D10), the CRM call
--       stays the first outbound CRM call shown; a deal with only such a CRM call (dH) is not called
--   V3  an attempt in the pre-window (dP): 0 business seconds, within the target; one before the pre-window not counted
--   V4  a deal closed before any attempt (dC; an attempt after the close): closed_before_first_call, both shares and the
--       waiting time null; counted in the summary's closed_before_first_call and in no percentage
--   V5  an open deal not called, in a market open around the clock: three days old (dO), within_target and
--       before_next_noon false; a minute old (dN), both null (the target and the cutoff not reached)
--   V6  at the default 12:00, cma.next_business_noon_of and _in answer as their bases (40's and 178's, copied here) on
--       every market and an unknown one over a year of instants; next_day_cutoff '10:00': 10:00 local on the next working
--       day (dA: Tuesday; dF, Friday: Monday), the same as cma.next_business_noon_of; 'noon' and '25:00' refused with CMA04
--   V7  the agent is the first attempt's telephony user (dA: tu-1, a person), not the CRM call's owner (dW: tu-9, no
--       person, agent null); deal_owner_user_id the deal's owner; by agent, deals without an attempt under no_attempt
--       (no label), the unmapped attempt under unknown
--   V8  one function: Attempts per deal's speed_to_lead_seconds and called_before_next_noon equal cma.speed_to_lead_of's
--       business_seconds and before_next_noon for every deal on both fixture tenants (except all both ways: 0 rows; both
--       windows end at the earliest of the close, the first order and now), and
--       cma.open_leads_of's deals are the not_called_open rows, on both tenants
--   V9  the summary's group total is one row (also for a week without deals) equal to the sum of the market rows'
--       counts, with the decided shares and median; p_market narrows every group to the market's rows
--   V10 tenant isolation: the summary, the rows and cma.speed_to_lead_of for tenant two hold none of tenant one's deals;
--       a reader limited to tenant one sees exactly the application's rows in cma_read.speed_to_lead, limited to tenant
--       two none of tenant one's
--   V12 a deal whose contact ordered before its first attempt (dX) is closed_before_first_call in cma.speed_to_lead_of and
--       has no attempt, no speed to lead and no answer before the cutoff in Attempts per deal (Martin, 24 Nov 2026)
--   V13 cma.contact_store_orders_of, probed per store connection since 0009zq, gives 94's rows (kept here verbatim)
--       on both fixture tenants and on every tenant of the database (except all both ways: 0 rows); on tenant one two
--       stores of one system, one of another, the same customer id in each, a test, a cancelled and a deleted order
--   V11 191's clock-at-read check still holds: cma.speed_to_lead_of's printed definition carries the header 191 replaces
--       and a copy with now() as a parameter equals the function at now() row for row; cma.open_leads_of calls it as 191
--       expects
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

drop table if exists pg_temp.verify_0009zq;
create temporary table verify_0009zq (ord integer, check_name text, result text, detail text);

-- One result row as four texts: OK when the check holds and the run is not provoked, else FAIL with its id
create or replace function pg_temp.v9zp_row(p_ord integer, p_id text, p_name text, p_ok boolean, p_detail text)
returns text[]
language sql stable
as $$
  select array[p_ord::text, p_id || ' ' || p_name,
               case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then 'OK' else 'FAIL' end,
               case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then coalesce(p_detail, '')
                    else 'FAIL ' || p_id || ': ' || case when current_setting('verify.provoke')::boolean then 'provoked; ' else '' end
                         || coalesce(p_detail, '(no detail)') end]
$$;

-- The SQLSTATE a statement raises, or 'ok'
create or replace function pg_temp.v9zp_code(p_sql text)
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

-- The bases of the two cutoff functions, verbatim (40's cma.next_business_noon_of and 178's cma.next_business_noon_in,
-- both at 12:00): V6 compares 0009zq's forms with them at the default cutoff
create or replace function pg_temp.v9zp_noon_of_40(p_tenant_id uuid, p_market text, p_at timestamptz)
returns timestamptz
language plpgsql stable
as $$
declare
  v_zone   text;
  v_sched  text;
  v_day    date;
begin
  if p_tenant_id is null or p_market is null or p_at is null then
    return null;
  end if;
  select m.time_zone into v_zone from cma.market m where m.tenant_id = p_tenant_id and m.code = p_market;
  if v_zone is null then
    return null;
  end if;
  v_sched := case when exists (select 1 from cma.business_hours h where h.tenant_id = p_tenant_id and h.market = p_market)
                  then p_market else '*' end;
  for i in 1 .. 31 loop
    v_day := (p_at at time zone v_zone)::date + i;
    if exists (select 1 from cma.business_hours h
               where h.tenant_id = p_tenant_id and h.market = v_sched and h.weekday = extract(isodow from v_day))
       and not exists (select 1 from cma.business_holiday b
                       where b.tenant_id = p_tenant_id and b.market in (p_market, '*') and b.day = v_day) then
      return (v_day + time '12:00') at time zone v_zone;
    end if;
  end loop;
  return null;
end
$$;

create or replace function pg_temp.v9zp_noon_in_178(p_zone text, p_weekdays integer[], p_holidays date[], p_at timestamptz)
returns timestamptz
language plpgsql stable
as $$
declare
  v_base date;
  v_day  date;
begin
  if p_zone is null or p_at is null then
    return null;
  end if;
  v_base := (p_at at time zone p_zone)::date;
  for i in 1 .. 31 loop
    v_day := v_base + i;
    if extract(isodow from v_day)::integer = any (p_weekdays) and not (v_day = any (coalesce(p_holidays, '{}'::date[]))) then
      return (v_day + time '12:00') at time zone p_zone;
    end if;
  end loop;
  return null;
end
$$;

-- cma.contact_store_orders_of as 94 defined it, verbatim: V13 compares 0009zq's form with it row for row
create or replace function pg_temp.v9zp_cso_94(p_tenant_id uuid)
returns table (
  connection_id        uuid,
  contact_source_id    text,
  order_id             uuid,
  order_connection_id  uuid,
  order_source_id      text,
  created_at           timestamptz,
  order_kind           text,
  currency             text,
  total_amount         numeric
)
language sql stable
as $$
  select k.connection_id, k.source_id, co.id, co.connection_id, co.source_id, co.source_created_at, co.order_kind, co.currency,
         co.total_amount
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id
  join cma.commerce_order co
    on co.tenant_id = k.tenant_id and co.source_system = r.system and co.customer_source_id = r.external_id
  where k.tenant_id = p_tenant_id
    and not co.is_test and co.cancelled_at is null and co.source_deleted_at is null
$$;

-- ---------------------------------------------------------------------------------------------
-- V1. Structure
-- ---------------------------------------------------------------------------------------------
do $$
declare
  rows_ text[] := '{}';
  v_ok boolean; v_txt text; v_bad text := '';
  v_type text; v_view text;
begin
  v_ok := exists (select 1 from cma.schema_migration where version = '0009zq')
      and exists (select 1 from cma.schema_migration where version = '0009zp');
  v_type := (select string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum)
             from pg_attribute a where a.attrelid = (select t.typrelid from pg_type t where t.oid = 'cma.speed_to_lead_row'::regtype)
               and a.attnum > 0 and not a.attisdropped);
  v_view := (select string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum)
             from pg_attribute a where a.attrelid = 'cma_read.speed_to_lead'::regclass and a.attnum > 0 and not a.attisdropped);
  if v_type !~ ',first_attempt_call_id:uuid,first_attempt_at:timestamp with time zone,attempts_so_far:integer,deal_owner_user_id:uuid$'
     or (select count(*) from regexp_split_to_table(v_type, ',')) <> 34
     or v_type !~ '^tenant_id:uuid,deal_id:uuid,.*,status:text,first_call_id:uuid,.*,agent_user_id:uuid,agent_ref:text,agent_from:text,.*,waiting_business_seconds:integer,first_attempt_call_id' then
    v_bad := v_bad || 'the row type is ' || v_type || '; ';
  end if;
  if v_view is distinct from v_type then
    v_bad := v_bad || 'cma_read.speed_to_lead is ' || coalesce(v_view, 'missing') || '; ';
  end if;
  -- since 0009zr (236) the one definition's body is cma.speed_to_lead_rows_of (edited by 236)
  v_txt := (select p.prosrc from pg_proc p
            where p.oid = coalesce(to_regprocedure('cma.speed_to_lead_rows_of(uuid,timestamptz,timestamptz,boolean)'),
                                   'cma.speed_to_lead_of(uuid,timestamptz,timestamptz)'::regprocedure));
  if position('''closed_before_first_call''' in v_txt) = 0 or position('not_called_closed' in v_txt) > 0
     or position('''not_called_open''' in v_txt) = 0 or position('''called''' in v_txt) = 0 then
    v_bad := v_bad || 'cma.speed_to_lead_of does not name the three status values alone; ';
  end if;
  if (select s.value_type || ':' || s.default_value from cma.setting s where s.key = 'speed_to_lead.next_day_cutoff') is distinct from 'time:12:00' then
    v_bad := v_bad || 'the setting speed_to_lead.next_day_cutoff is not time 12:00; ';
  end if;
  foreach v_txt in array array['cma.speed_to_lead_summary(date,date,text,text)', 'cma.next_business_noon_in(text,integer[],date[],timestamptz,time)',
                               'cma.speed_to_lead_of(uuid,timestamptz,timestamptz)', 'cma.speed_to_lead_rows(date,date)',
                               'cma.next_business_noon_of(uuid,text,timestamptz)', 'cma.open_leads_of(uuid)',
                               'cma.attempts_per_deal_of(uuid,timestamptz,timestamptz,timestamptz)'] loop
    if to_regprocedure(v_txt) is null then
      v_bad := v_bad || v_txt || ' missing; ';
    elsif not has_function_privilege('cma_app', v_txt, 'execute') or has_function_privilege('public', v_txt, 'execute')
          or has_function_privilege('cma_readonly', v_txt, 'execute') then
      v_bad := v_bad || v_txt || ' not the application''s only; ';
    end if;
  end loop;
  if to_regprocedure('cma.speed_to_lead_summary(date,date,text)') is not null
     or to_regprocedure('cma.next_business_noon_in(text,integer[],date[],timestamptz)') is not null then
    v_bad := v_bad || 'a replaced form is still there; ';
  end if;
  if not has_table_privilege('cma_readonly', 'cma_read.speed_to_lead', 'select') then
    v_bad := v_bad || 'readers cannot read cma_read.speed_to_lead; ';
  end if;
  rows_ := rows_ || pg_temp.v9zp_row(1, 'V1', 'structure: the addition, the row type and the view, the status values, the setting, the grants',
                                     v_ok and v_bad = '', case when not v_ok then '0009zq or 0009zp not recorded; ' else '' end
                                                          || coalesce(nullif(v_bad, ''), '34 columns, the four new last; the view the same; three status values; time 12:00; grants as designed'));
  insert into verify_0009zq (ord, check_name, result, detail)
  select rows_[4 * i - 3]::integer, rows_[4 * i - 2], rows_[4 * i - 1], rows_[4 * i] from generate_series(1, cardinality(rows_) / 4) i;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- V1 (the fixture's status values) to V13, on two throwaway tenants (rolled back)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  rows_ text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_anna uuid; v_bram uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid;
  v_crm uuid; v_tel uuid; v_crm2 uuid; v_shopa uuid; v_shopb uuid; v_shopc uuid;
  v_from timestamptz := '2026-10-04 22:00:00+00';   -- Monday 5 October 2026, 00:00 in Amsterdam
  v_to   timestamptz := '2026-10-12 22:00:00+00';   -- Tuesday 13 October, 00:00 in Amsterdam
  v_ok boolean; v_ok2 boolean; v_txt text; v_txt2 text; v_n integer; v_m integer; r record; d text;
  v_a text; v_b text;
  v_path text := current_setting('search_path');
begin
  begin
    -- tenants, people and roles (as the owner)
    v_t1 := cma.create_tenant('verify-0009zq-one', 'Verify 0009zq one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0009zq-two', 'Verify 0009zq two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-anna@example.invalid', 'Anna Verify') returning id into v_anna;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-bram@example.invalid', 'Bram Verify') returning id into v_bram;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_anna, 'agent'), (v_t1, v_bram, 'agent'),
                 (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifycrm', 'Verify 0009zq CRM', 'portal-1') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifytel', 'Verify 0009zq telephony', 'tel-1') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verifycrm', 'Verify 0009zq CRM two', 'portal-2') returning id into v_crm2;
    -- V13's stores: two of one system, one of another
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifyshop', 'Verify 0009zq shop A', 'shop-a.example.invalid') returning id into v_shopa;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifyshop', 'Verify 0009zq shop B', 'shop-b.example.invalid') returning id into v_shopb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'othershop', 'Verify 0009zq shop C', 'shop-c.example.invalid') returning id into v_shopc;
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): NL Monday to Friday 09:00-17:00, GB open around the clock, the settings, the
    -- owners (o-1 Anna, o-2 Bram) and the telephony user tu-1 (Anna; tu-9 is nobody)
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.set_business_hours('*', x::smallint, '09:00-17:00') from generate_series(1, 5) x;
    perform cma.set_business_hours('GB', x::smallint, '00:00-24:00') from generate_series(1, 7) x;
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform cma.set_tenant_setting('speed_to_lead.pre_window_minutes', '10');
    perform cma.set_tenant_setting('speed_to_lead.target_minutes', '60');
    perform cma.set_user_external_id(v_anna, 'verifycrm_owner', 'o-1');
    perform cma.set_user_external_id(v_bram, 'verifycrm_owner', 'o-2');
    perform cma.set_user_external_id(v_anna, 'verifytel_user', 'tu-1');

    -- the catalogs (the Ingest user), the counted line (the admin)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false, "outcome": null},
         {"stageId": "sl", "label": "Lost", "order": 9, "isClosed": true, "outcome": "lost"}]},
      {"recordType": "deal", "pipelineId": "selfserve", "label": "Self Serve", "stages": [{"stageId": "o1", "label": "Won", "order": 1, "isClosed": true, "outcome": "won"}]}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"}]');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);
    -- Self Serve: an order pipeline, no lead pipeline; a holiday on Thursday 8 October in NL
    perform cma.set_pipeline_order(v_crm, 'deal', 'selfserve', true);
    perform cma.set_pipeline_lead(v_crm, 'deal', 'selfserve', false);
    perform cma.set_business_holiday('NL', '2026-10-08', 'Verify holiday');

    -- the deals (UTC; Amsterdam is UTC+2 until 25 October); dO and dN in GB, three days and a minute before now
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_crm, '[
      {"recordType": "deal", "sourceId": "dA", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-2", "contactId": "kA", "market": "NL", "createdAt": "2026-10-05T08:00:00Z", "updatedAt": "2026-10-05T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dH", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-1", "contactId": "kH", "market": "NL", "createdAt": "2026-10-05T09:00:00Z", "updatedAt": "2026-10-05T09:00:00Z"},
      {"recordType": "deal", "sourceId": "dP", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-1", "contactId": "kP", "market": "NL", "createdAt": "2026-10-05T10:00:00Z", "updatedAt": "2026-10-05T10:00:00Z"},
      {"recordType": "deal", "sourceId": "dC", "pipelineId": "sales", "stageId": "sl", "ownerRef": "o-1", "contactId": "kC", "market": "NL", "createdAt": "2026-10-06T08:00:00Z", "closedAt": "2026-10-06T12:00:00Z", "updatedAt": "2026-10-06T12:00:00Z"},
      {"recordType": "deal", "sourceId": "dW", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-1", "contactId": "kW", "market": "NL", "createdAt": "2026-10-07T08:00:00Z", "updatedAt": "2026-10-07T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dF", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-1", "contactId": "kF", "market": "NL", "createdAt": "2026-10-09T13:00:00Z", "updatedAt": "2026-10-09T13:00:00Z"},
      {"recordType": "deal", "sourceId": "dX", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-1", "contactId": "kX", "market": "NL", "createdAt": "2026-10-07T09:00:00Z", "updatedAt": "2026-10-07T09:00:00Z"},
      {"recordType": "deal", "sourceId": "dXo", "pipelineId": "selfserve", "stageId": "o1", "contactId": "kX", "market": "NL", "createdAt": "2026-10-07T09:30:00Z", "closedAt": "2026-10-07T09:30:00Z", "updatedAt": "2026-10-07T09:30:00Z"}]');
    perform cma.ingest_upsert_records(v_crm, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'dO', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-1', 'contactId', 'kO', 'market', 'GB',
                         'createdAt', now() - interval '3 days', 'updatedAt', now() - interval '3 days'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'dN', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-1', 'contactId', 'kN', 'market', 'GB',
                         'createdAt', now() - interval '1 minute', 'updatedAt', now() - interval '1 minute')));
    perform cma.ingest_upsert_contacts(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', k, 'country', 'NL', 'updatedAt', '2026-10-01T00:00:00Z'))
      from unnest(array['kA', 'kH', 'kP', 'kC', 'kW', 'kF', 'kX', 'kO', 'kN']) k));
    -- the CRM calls, each on its deal's contact, all outbound; a hash where an Aircall call logged it. cA0 and cH1 were
    -- logged without one (D10); cP0 is before the pre-window, cP1 within it; cC1 after dC's close; cW1 placed by tu-9;
    -- cX1 after dX's contact ordered through Self Serve (the attempts' window ended at the order, speed to lead's did not)
    perform cma.ingest_upsert_calls(v_crm, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('sourceId', c.id, 'occurredAt', c.at, 'direction', 'outbound', 'ownerRef', c.owner,
                                                            'counterpartHash', case when c.linked then md5(c.id) || md5(c.id || 'x') end,
                                                            'updatedAt', c.at)))
      from (values
        ('cA0', '2026-10-05T08:05:00Z', 'o-1', false),
        ('cA1', '2026-10-05T09:00:00Z', 'o-1', true),
        ('cH1', '2026-10-05T09:10:00Z', 'o-1', false),
        ('cP0', '2026-10-05T09:44:00Z', 'o-1', true),
        ('cP1', '2026-10-05T09:55:00Z', 'o-1', true),
        ('cC1', '2026-10-06T13:00:00Z', 'o-1', true),
        ('cW1', '2026-10-07T08:30:00Z', 'o-1', true),
        ('cF1', '2026-10-12T07:30:00Z', 'o-1', true),
        ('cX1', '2026-10-07T10:00:00Z', 'o-1', true)) c(id, at, owner, linked)));
    perform cma.ingest_upsert_associations(v_crm, (
      select jsonb_agg(jsonb_build_object('fromType', 'crm_call', 'fromId', a.c, 'toType', 'contact', 'toId', a.k, 'removed', false,
                                          'changedAt', '2026-10-01T00:00:00Z'))
      from (values ('cA0', 'kA'), ('cA1', 'kA'), ('cH1', 'kH'), ('cP0', 'kP'), ('cP1', 'kP'), ('cC1', 'kC'), ('cW1', 'kW'), ('cF1', 'kF'), ('cX1', 'kX')) a(c, k)));
    -- the Aircall calls that logged them, 10 seconds earlier, with the same hash
    perform cma.ingest_upsert_telephony_calls(v_tel, (
      select jsonb_agg(jsonb_build_object(
               'sourceId', 't' || t.c, 'direction', 'outbound', 'startedAt', t.started - interval '10 seconds',
               'endedAt', t.started + interval '20 seconds', 'numberRef', 'n-nl', 'userRef', t.usr,
               'counterpartHash', md5(t.c) || md5(t.c || 'x'), 'versionAt', t.started + interval '1 hour'))
      from (values
        ('cA1', timestamptz '2026-10-05T09:00:00Z', 'tu-1'),
        ('cP0', timestamptz '2026-10-05T09:44:00Z', 'tu-1'),
        ('cP1', timestamptz '2026-10-05T09:55:00Z', 'tu-1'),
        ('cC1', timestamptz '2026-10-06T13:00:00Z', 'tu-1'),
        ('cW1', timestamptz '2026-10-07T08:30:00Z', 'tu-9'),
        ('cF1', timestamptz '2026-10-12T07:30:00Z', 'tu-1'),
        ('cX1', timestamptz '2026-10-07T10:00:00Z', 'tu-1')) t(c, started, usr)));
    perform cma.link_calls('2026-09-01T00:00:00Z');

    -- V13's store data, all before the week (so no deal's window ends at it): dA's contact holds verifyshop c-1, dH's
    -- verifyshop c-2 and othershop c-1; c-1 bought in shop A and shop B, and once in shop C; shop A also holds a test,
    -- a cancelled and (c-2's) a deleted order
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_commerce_store(v_shopa, 'verify-a', 'Verify A', 'NL', 'EUR', 'Europe/Amsterdam');
    perform cma.upsert_commerce_store(v_shopb, 'verify-b', 'Verify B', 'NL', 'EUR', 'Europe/Amsterdam');
    perform cma.upsert_commerce_store(v_shopc, 'verify-c', 'Verify C', 'NL', 'EUR', 'Europe/Amsterdam');
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_contacts(v_crm, '[
      {"sourceId": "kA", "country": "NL", "refs": {"verifyshop": ["c-1"]}, "updatedAt": "2026-10-01T00:00:00Z"},
      {"sourceId": "kH", "country": "NL", "refs": {"verifyshop": ["c-2"], "othershop": ["c-1"]}, "updatedAt": "2026-10-01T00:00:00Z"}]');
    perform cma.ingest_upsert_commerce_customers(v_shopa, '[{"sourceId": "c-1", "updatedAt": "2026-09-01T00:00:00Z"}, {"sourceId": "c-2", "updatedAt": "2026-09-01T00:00:00Z"}]');
    perform cma.ingest_upsert_commerce_customers(v_shopb, '[{"sourceId": "c-1", "updatedAt": "2026-09-01T00:00:00Z"}]');
    perform cma.ingest_upsert_commerce_customers(v_shopc, '[{"sourceId": "c-1", "updatedAt": "2026-09-01T00:00:00Z"}]');
    perform cma.ingest_upsert_commerce_orders(v_shopa, '[
      {"sourceId": "o1", "customerId": "c-1", "createdAt": "2026-09-02T10:00:00Z", "updatedAt": "2026-09-02T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "o3", "customerId": "c-1", "createdAt": "2026-09-03T10:00:00Z", "updatedAt": "2026-09-03T10:00:00Z", "isTest": true, "priorOrdersCount": 1},
      {"sourceId": "o4", "customerId": "c-1", "createdAt": "2026-09-04T10:00:00Z", "updatedAt": "2026-09-04T11:00:00Z", "cancelledAt": "2026-09-04T11:00:00Z", "priorOrdersCount": 1},
      {"sourceId": "o6", "customerId": "c-2", "createdAt": "2026-09-05T10:00:00Z", "updatedAt": "2026-09-05T10:00:00Z", "priorOrdersCount": 0}]');
    perform cma.ingest_upsert_commerce_orders(v_shopa, '[{"sourceId": "o6", "deletedAt": "2026-09-05T11:00:00Z"}]');
    perform cma.ingest_upsert_commerce_orders(v_shopb, '[{"sourceId": "o2", "customerId": "c-1", "createdAt": "2026-09-06T10:00:00Z", "updatedAt": "2026-09-06T10:00:00Z", "priorOrdersCount": 0}]');
    perform cma.ingest_upsert_commerce_orders(v_shopc, '[{"sourceId": "o5", "customerId": "c-1", "createdAt": "2026-09-07T10:00:00Z", "updatedAt": "2026-09-07T10:00:00Z", "priorOrdersCount": 0}]');

    -- tenant two: NL, the same source id dA (open, never called) and dB (closed before any call)
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_business_hours('*', x::smallint, '09:00-17:00') from generate_series(1, 5) x;
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_pipelines(v_crm2, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false, "outcome": null},
         {"stageId": "sl", "label": "Lost", "order": 9, "isClosed": true, "outcome": "lost"}]}]');
    perform cma.ingest_upsert_records(v_crm2, '[
      {"recordType": "deal", "sourceId": "dA", "pipelineId": "sales", "stageId": "s1", "contactId": "kA", "market": "NL", "createdAt": "2026-10-05T08:00:00Z", "updatedAt": "2026-10-05T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dB", "pipelineId": "sales", "stageId": "sl", "contactId": "kB", "market": "NL", "createdAt": "2026-10-06T08:00:00Z", "closedAt": "2026-10-06T09:00:00Z", "updatedAt": "2026-10-06T09:00:00Z"}]');

    -- the reads as tenant one's analyst (the application's role, row-level security)
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);

    -- V1 (the fixture): exactly the three status values occur
    select string_agg(distinct x.status collate "C", ',' order by x.status collate "C") into v_txt from cma.speed_to_lead_of(v_t1, null, null) x;
    rows_ := rows_ || pg_temp.v9zp_row(2, 'V1', 'the fixture''s rows hold exactly the three status values',
                                       v_txt = 'called,closed_before_first_call,not_called_open', v_txt);

    -- V2. dA: a CRM call without a telephony call (cA0, 08:05) before the Aircall attempt (cA1, 08:59:50): the end is the
    --     attempt, 3590 business seconds; cA0 stays the first outbound CRM call shown. dH: only such a call, not called
    select * into r from cma.speed_to_lead_of(v_t1, v_from, v_to) x where x.deal_source_id = 'dA';
    v_txt := format('dA %s %s at %s, %s s, first call %s linked %s, attempts %s', r.status, r.first_attempt_call_id is not null,
                    r.first_attempt_at, r.business_seconds, r.first_call_source_id, r.first_call_linked, r.attempts_so_far);
    v_ok := r.status = 'called' and r.first_attempt_at = '2026-10-05T08:59:50Z' and r.business_seconds = 3590 and r.elapsed_seconds = 3590
            and r.first_call_source_id = 'cA0' and r.first_call_linked is false and r.attempts_so_far = 1
            and r.first_attempt_call_id = (select c.id from cma.crm_call c where c.tenant_id = v_t1 and c.source_id = 'cA1');
    select * into r from cma.speed_to_lead_of(v_t1, v_from, v_to) x where x.deal_source_id = 'dH';
    v_txt := v_txt || format('; dH %s, first call %s, attempt %s, attempts %s', r.status, r.first_call_source_id, r.first_attempt_at, r.attempts_so_far);
    v_ok := v_ok and r.status = 'not_called_open' and r.first_call_source_id = 'cH1' and r.first_attempt_at is null
            and r.first_attempt_call_id is null and r.attempts_so_far = 0 and r.business_seconds is null;
    rows_ := rows_ || pg_temp.v9zp_row(3, 'V2', 'a CRM call without a telephony call never ends speed to lead; the Aircall attempt does', v_ok, v_txt);

    -- V3. dP: the attempt 5 minutes before the creation (within the 10-minute pre-window) is 0 seconds and within the
    --     target; the one 16 minutes before is not counted
    select * into r from cma.speed_to_lead_of(v_t1, v_from, v_to) x where x.deal_source_id = 'dP';
    rows_ := rows_ || pg_temp.v9zp_row(4, 'V3', 'an attempt in the pre-window: 0 business seconds, within the target',
      r.status = 'called' and r.business_seconds = 0 and r.elapsed_seconds = 0 and r.within_target and r.before_next_noon
        and r.first_attempt_at = '2026-10-05T09:54:50Z' and r.attempts_so_far = 1,
      format('dP %s, %s s, elapsed %s, within %s, at %s, attempts %s', r.status, r.business_seconds, r.elapsed_seconds, r.within_target,
             r.first_attempt_at, r.attempts_so_far));

    -- V4. dC: closed at 12:00 UTC, its only attempt at 13:00: closed before the first call, nothing measured, out of both
    --     shares; the week's summary counts it and dX (V12) apart and in no percentage (within: dA, dP, dW of dA, dP, dW, dF,
    --     dH = 60.0; before the cutoff: dA, dP, dW, dF of the same five = 80.0; with dC and dX counted late, 42.9 and 57.1)
    select * into r from cma.speed_to_lead_of(v_t1, v_from, v_to) x where x.deal_source_id = 'dC';
    v_txt := format('dC %s, within %s, noon %s, waiting %s, seconds %s, attempts %s', r.status, r.within_target, r.before_next_noon,
                    r.waiting_business_seconds, r.business_seconds, r.attempts_so_far);
    v_ok := r.status = 'closed_before_first_call' and r.within_target is null and r.before_next_noon is null and r.waiting_business_seconds is null
            and r.business_seconds is null and r.first_attempt_at is null and r.attempts_so_far = 0;
    select format('%s deals, %s called, %s open, %s closed before, within %s, before %s', s.deals, s.called, s.open_not_called,
                  s.closed_before_first_call, s.within_target_pct, s.before_next_noon_pct),
           s.closed_before_first_call = 2 and s.within_target_pct = 60.0 and s.before_next_noon_pct = 80.0
      into v_txt2, v_ok2 from cma.speed_to_lead_summary('2026-10-05', '2026-10-12', 'total') s;
    rows_ := rows_ || pg_temp.v9zp_row(5, 'V4', 'a deal closed before its first attempt: shown apart, out of both percentages',
                                       v_ok and v_ok2, v_txt || '; summary ' || v_txt2);

    -- V5. the clock, in GB (open around the clock): dO, three days old, late on both; dN, a minute old, neither known yet
    select * into r from cma.speed_to_lead_of(v_t1, null, null) x where x.deal_source_id = 'dO';
    v_txt := format('dO %s within %s before %s waiting %s', r.status, r.within_target, r.before_next_noon, r.waiting_business_seconds);
    v_ok := r.status = 'not_called_open' and r.within_target is false and r.before_next_noon is false and r.waiting_business_seconds > 3600;
    select * into r from cma.speed_to_lead_of(v_t1, null, null) x where x.deal_source_id = 'dN';
    v_txt := v_txt || format('; dN %s within %s before %s cutoff %s waiting %s', r.status, r.within_target, r.before_next_noon,
                             r.next_business_noon, r.waiting_business_seconds);
    v_ok := v_ok and r.status = 'not_called_open' and r.within_target is null and r.before_next_noon is null
            and r.next_business_noon > now() and r.waiting_business_seconds between 0 and 3600;
    rows_ := rows_ || pg_temp.v9zp_row(6, 'V5', 'an open deal not called: late once past the target and the cutoff, unknown before', v_ok, v_txt);

    -- V6. next_day_cutoff 10:00: dA (Monday) Tuesday 10:00 local, dF (Friday) Monday 10:00 local, as the _of function
    --     answers; by default (12:00) 12:00; 'noon' and '25:00' refused
    -- at the default cutoff the two functions answer as their bases (40's _of, 178's _in) on every market of tenant one
    -- and an unknown one, over a year of instants around the DST changes, the year's turn and the holiday
    select count(*) filter (where y.n_of is distinct from y.b_of) + count(*) filter (where y.n_in is distinct from y.b_in), count(*)
      into v_n, v_m
    from (select cma.next_business_noon_of(v_t1, mk.code, g.at) as n_of, pg_temp.v9zp_noon_of_40(v_t1, mk.code, g.at) as b_of,
                 cma.next_business_noon_in(c.time_zone, c.weekdays, c.holidays, g.at, cma.setting_of(v_t1, 'speed_to_lead.next_day_cutoff')::time) as n_in,
                 pg_temp.v9zp_noon_in_178(c.time_zone, c.weekdays, c.holidays, g.at) as b_in
          from (select m.code from cma.market m where m.tenant_id = v_t1 union all select 'XX') mk
          left join cma.business_calendar_of(v_t1) c on c.market = mk.code
          cross join (select x as at from generate_series(timestamptz '2025-12-29 06:17+00', timestamptz '2026-12-31 06:17+00', interval '2 days 7 hours 13 minutes') x
                      union select timestamptz '2026-03-29 00:30+00' union select timestamptz '2026-10-25 00:30+00'
                      union select timestamptz '2026-10-07 11:30+00') g) y;
    v_txt2 := format('at 12:00 %s of %s answers off the bases', v_n, v_m);
    v_ok2 := v_n = 0 and v_m > 0;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('speed_to_lead.next_day_cutoff', '10:00');
    perform set_config('app.user_id', v_analyst1::text, true);
    select string_agg(x.deal_source_id || ':' || to_char(x.next_business_noon at time zone 'Europe/Amsterdam', 'Dy DD HH24:MI') || ':' || x.before_next_noon
                      || ':' || (x.next_business_noon = cma.next_business_noon_of(v_t1, 'NL', x.created_at)), ' ' order by x.deal_source_id collate "C")
      into v_txt from cma.speed_to_lead_of(v_t1, v_from, v_to) x where x.deal_source_id in ('dA', 'dF');
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt2 := v_txt2 || ' | ' || pg_temp.v9zp_code('select cma.set_tenant_setting(''speed_to_lead.next_day_cutoff'', ''noon'')') || ','
              || pg_temp.v9zp_code('select cma.set_tenant_setting(''speed_to_lead.next_day_cutoff'', ''25:00'')');
    perform cma.set_tenant_setting('speed_to_lead.next_day_cutoff', '12:00');
    perform set_config('app.user_id', v_analyst1::text, true);
    select v_txt || ' | default ' || string_agg(to_char(x.next_business_noon at time zone 'Europe/Amsterdam', 'Dy DD HH24:MI'), ' ' order by x.deal_source_id collate "C")
      into v_txt from cma.speed_to_lead_of(v_t1, v_from, v_to) x where x.deal_source_id in ('dA', 'dF');
    rows_ := rows_ || pg_temp.v9zp_row(7, 'V6', 'next_day_cutoff moves the cutoff; a value that is no time is refused (CMA04)',
      v_txt = 'dA:Tue 06 10:00:true:true dF:Mon 12 10:00:true:true | default Tue 06 12:00 Mon 12 12:00' and v_ok2
        and v_txt2 like '% | CMA04,CMA04',
      v_txt || ' | ' || v_txt2);

    -- V7. the agent: dA's attempt by tu-1 (Anna), its CRM calls owned by o-1, the deal by o-2 (Bram); dW's attempt by tu-9
    --     (nobody), its deal and call by o-1: no agent, never the owner. By agent over the week: Anna dA, dP, dF; unknown dW;
    --     no_attempt dH, dC, dX without a label
    select string_agg(format('%s:%s:%s:%s:%s', x.deal_source_id,
                             case x.agent_user_id when v_anna then 'anna' when v_bram then 'bram' else coalesce(x.agent_user_id::text, '-') end,
                             coalesce(x.agent_ref, '-'), coalesce(x.agent_from, '-'),
                             case x.deal_owner_user_id when v_anna then 'anna' when v_bram then 'bram' else coalesce(x.deal_owner_user_id::text, '-') end),
                      ' ' order by x.deal_source_id collate "C")
      into v_txt from cma.speed_to_lead_of(v_t1, v_from, v_to) x where x.deal_source_id in ('dA', 'dW', 'dH');
    select string_agg(format('%s:%s:%s:%s', case s.group_key when v_anna::text then 'anna' else s.group_key end, coalesce(s.group_label, '-'), s.deals, s.called),
                      ' ' order by s.group_key collate "C")
      into v_txt2 from cma.speed_to_lead_summary('2026-10-05', '2026-10-12', 'agent') s;
    rows_ := rows_ || pg_temp.v9zp_row(8, 'V7', 'the agent is the first attempt''s telephony user; the owner apart; no_attempt and unknown groups',
      v_txt = 'dA:anna:tu-1:call:bram dH:-:-:-:anna dW:-:tu-9:call:anna'
        and v_txt2 = 'anna:Anna Verify:3:3 no_attempt:-:3:0 unknown:unknown:1:1',
      v_txt || ' | ' || v_txt2);

    -- V8. one function, on both tenants: Attempts per deal's speed to lead and called-before-the-cutoff per deal equal
    --     cma.speed_to_lead_of's on every deal (except all both ways), since both windows end at the earliest of the close,
    --     the first order and now; cma.open_leads_of's deals and owners are the not_called_open rows' deals and deal owners
    v_txt := '';
    v_ok := true;
    foreach d in array array[v_t1::text, v_t2::text] loop
      perform set_config('app.tenant_id', d, true);
      perform set_config('app.user_id', case when d = v_t1::text then v_analyst1 else v_analyst2 end::text, true);
      with a as (select x.deal_id, x.speed_to_lead_seconds as s, x.called_before_next_noon as n
                 from cma.attempts_per_deal_of(d::uuid, v_from, v_to, now()) x),
           b as (select x.deal_id, x.business_seconds as s, x.before_next_noon as n
                 from cma.speed_to_lead_of(d::uuid, v_from, v_to) x where x.deal_id in (select a.deal_id from a))
      select (select count(*) from (select * from a except all select * from b) y) + (select count(*) from (select * from b except all select * from a) y),
             (select count(*) from a)
        into v_n, v_m;
      v_txt := v_txt || format('%s: %s deals, %s differ; ', case when d = v_t1::text then 'one' else 'two' end, v_m, v_n);
      v_ok := v_ok and v_n = 0 and v_m > 0;
      with o as (select x.deal_id, x.owner_user_id, x.owner_ref from cma.open_leads_of(d::uuid) x),
           s2 as (select x.deal_id, x.deal_owner_user_id, cr.owner_ref from cma.speed_to_lead_of(d::uuid, null, null) x
                  join cma.crm_record cr on cr.tenant_id = d::uuid and cr.id = x.deal_id where x.status = 'not_called_open')
      select (select count(*) from (select * from o except all select * from s2) y) + (select count(*) from (select * from s2 except all select * from o) y),
             (select count(*) from o)
        into v_n, v_m;
      v_txt := v_txt || format('open leads %s with their owners, %s differ; ', v_m, v_n);
      v_ok := v_ok and v_n = 0 and v_m > 0;
    end loop;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    rows_ := rows_ || pg_temp.v9zp_row(9, 'V8', 'one function: Attempts per deal and the open leads read cma.speed_to_lead_of', v_ok, v_txt);

    -- V12. dX, open, its contact ordered through Self Serve at 09:30 UTC, its only attempt at 10:00: closed before the first
    --      call in both reads (Martin, 24 Nov 2026): no attempt in the window, nothing measured, out of the open leads; in
    --      Attempts per deal no attempt, no speed to lead and no answer before the cutoff, the window ended by the order
    select * into r from cma.speed_to_lead_of(v_t1, v_from, v_to) x where x.deal_source_id = 'dX';
    v_txt := format('speed to lead: %s, attempt %s, attempts %s, seconds %s, within %s, before %s', r.status, r.first_attempt_at, r.attempts_so_far,
                    r.business_seconds, r.within_target, r.before_next_noon);
    v_ok := r.status = 'closed_before_first_call' and r.first_attempt_at is null and r.attempts_so_far = 0 and r.business_seconds is null
            and r.within_target is null and r.before_next_noon is null and r.waiting_business_seconds is null;
    select v_txt || format('; attempts per deal: %s attempts, first %s, seconds %s, before %s, window %s, outcome %s', x.attempts,
                           x.first_attempt_at, x.speed_to_lead_seconds, x.called_before_next_noon, x.window_end_reason, x.outcome),
           v_ok and x.attempts = 0 and x.first_attempt_at is null and x.speed_to_lead_seconds is null and x.called_before_next_noon is null
             and x.window_end_reason = 'ordered'
      into v_txt, v_ok from cma.attempts_per_deal_of(v_t1, v_from, v_to, now()) x where x.deal_source_id = 'dX';
    v_ok := coalesce(v_ok, false) and not exists (select 1 from cma.open_leads_of(v_t1) o where o.deal_source_id = 'dX');
    rows_ := rows_ || pg_temp.v9zp_row(13, 'V12', 'a deal whose contact ordered before its first attempt is closed before the first call in both reads', v_ok, v_txt);

    -- V13. cma.contact_store_orders_of as 0009zq writes it (probed per store connection) gives 94's rows, except all both
    --      ways, on both fixture tenants and on every tenant of the database, as the application acting for each; on
    --      tenant one exactly kA's o1 (shop A) and o2 (shop B), and kH's o5 (othershop); no test, cancelled or deleted order
    -- (as the application, as the checks around it run: the role stays cma_app)
    v_txt := ''; v_ok := true;
    for d in select te.id::text from cma.tenant te order by te.id loop
      perform set_config('app.tenant_id', d, true);
      with a as (select * from cma.contact_store_orders_of(d::uuid)), b as (select * from pg_temp.v9zp_cso_94(d::uuid))
      select (select count(*) from (select * from a except all select * from b) y) + (select count(*) from (select * from b except all select * from a) y),
             (select count(*) from a)
        into v_n, v_m;
      v_ok := v_ok and v_n = 0;
      if d in (v_t1::text, v_t2::text) then
        v_txt := v_txt || format('%s: %s rows, %s differ; ', case when d = v_t1::text then 'one' else 'two' end, v_m, v_n);
      else
        v_txt := v_txt || format('tenant: %s rows, %s differ; ', v_m, v_n);
      end if;
    end loop;
    perform set_config('app.tenant_id', v_t1::text, true);
    select string_agg(x.contact_source_id || ':' || x.order_source_id, ' ' order by x.contact_source_id collate "C", x.order_source_id collate "C")
      into v_txt2 from cma.contact_store_orders_of(v_t1) x;
    v_ok := v_ok and v_txt2 = 'kA:o1 kA:o2 kH:o5';
    rows_ := rows_ || pg_temp.v9zp_row(14, 'V13', 'cma.contact_store_orders_of probed per store connection gives 94''s rows', v_ok, v_txt || 'tenant one: ' || coalesce(v_txt2, '-'));

    -- V9. total: one row equal to the sums of the market rows; one row for a week without deals; the decided median (dP 0,
    --     dW 1790, dA 3590, dF 8990: 2690 s, 44.8 minutes); p_market narrows every group to NL's seven deals or GB's none
    select format('%s:%s:%s:%s:%s', count(*), sum(s.deals), sum(s.called), sum(s.open_not_called), sum(s.closed_before_first_call))
      into v_txt from cma.speed_to_lead_summary('2026-10-05', '2026-10-12', 'market') s;
    select v_txt || format(' total %s:%s:%s:%s:%s median %s', count(*), sum(s.deals), sum(s.called), sum(s.open_not_called),
                           sum(s.closed_before_first_call), max(s.median_business_minutes))
      into v_txt from cma.speed_to_lead_summary('2026-10-05', '2026-10-12', 'total') s;
    select v_txt || format(' empty %s:%s', count(*), sum(s.deals)) into v_txt from cma.speed_to_lead_summary('2026-09-07', '2026-09-13', 'total') s;
    v_txt2 := '';
    foreach d in array array['day', 'market', 'agent', 'pipeline', 'total'] loop
      select v_txt2 || format('%s %s/%s ', d,
                              (select coalesce(sum(s.deals), 0) from cma.speed_to_lead_summary('2026-10-05', '2026-10-12', d, 'NL') s),
                              (select coalesce(sum(s.deals), 0) from cma.speed_to_lead_summary('2026-10-05', '2026-10-12', d, 'GB') s))
        into v_txt2;
    end loop;
    rows_ := rows_ || pg_temp.v9zp_row(10, 'V9', 'the group total is one row adding up; p_market narrows every group',
      v_txt = '1:7:4:1:2 total 1:7:4:1:2 median 44.8 empty 1:0'
        and v_txt2 = 'day 7/0 market 7/0 agent 7/0 pipeline 7/0 total 7/0 ',
      v_txt || ' | ' || v_txt2);

    -- V10. tenant two's reads hold none of tenant one's deals; a reader limited to tenant one sees the application's rows,
    --      limited to tenant two none of tenant one's
    select md5(string_agg(x::text, '|' order by x.deal_id)) into v_a from cma.speed_to_lead_of(v_t1, null, null) x;
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    select format('two: %s rows, %s of one; total %s; of one as two %s', count(*), count(*) filter (where x.tenant_id = v_t1),
                  (select s.deals from cma.speed_to_lead_summary('2026-10-05', '2026-10-12', 'total') s),
                  (select count(*) from cma.speed_to_lead_of(v_t1, null, null)))
      into v_txt from cma.speed_to_lead_rows('2026-10-05', '2026-10-12') x;
    perform set_config('role', 'cma_readonly', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    select md5(string_agg(x::text, '|' order by x.deal_id)) into v_b from cma_read.speed_to_lead x;
    perform set_config('app.tenant_id', v_t2::text, true);
    select v_txt || format('; reader as two: %s rows, %s of one', count(*), count(*) filter (where x.tenant_id = v_t1))
      into v_txt from cma_read.speed_to_lead x;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    rows_ := rows_ || pg_temp.v9zp_row(11, 'V10', 'tenant isolation on the summary, the rows and cma_read.speed_to_lead',
      v_txt = 'two: 2 rows, 0 of one; total 2; of one as two 0; reader as two: 2 rows, 0 of one' and v_a = v_b,
      v_txt || case when v_a is distinct from v_b then '; the reader''s view differs from the application''s rows' else '; the reader''s view equals the application''s rows' end);

    -- V11. 191's copy: the printed definition carries the header 191 replaces, and a copy with now() as a parameter
    --      equals the function at now() (provoked: a day later); cma.open_leads_of calls it as 191 expects
    perform set_config('role', 'cma_owner', true);
    perform set_config('search_path', 'pg_catalog', true);
    v_txt2 := pg_get_functiondef('cma.open_leads_of(uuid)'::regprocedure);
    if to_regprocedure('cma.speed_to_lead_rows_of(uuid,timestamptz,timestamptz,boolean)') is not null then
      -- 0009zr (236, which edits this check): the body and its open-only bound in cma.speed_to_lead_rows_of, which 191 copies
      v_txt := pg_get_functiondef('cma.speed_to_lead_rows_of(uuid,timestamptz,timestamptz,boolean)'::regprocedure);
      v_ok := position('FUNCTION cma.speed_to_lead_rows_of(p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_open_only boolean)' in v_txt) > 0
              and position('cma.speed_to_lead_rows_of(p_tenant_id, null, null, true)' in v_txt2) > 0;
      if v_ok then
        execute replace(replace(v_txt, 'FUNCTION cma.speed_to_lead_rows_of(p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_open_only boolean)',
                                       'FUNCTION pg_temp.v9zp_speed_to_lead_rows_at(p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_open_only boolean, p_at timestamp with time zone)'),
                        'now()', 'p_at');
        execute 'create or replace function pg_temp.v9zp_speed_to_lead_at(p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_at timestamp with time zone)
                 returns setof cma.speed_to_lead_row language sql stable
                 as $f$ select * from pg_temp.v9zp_speed_to_lead_rows_at(p_tenant_id, p_from, p_to, false, p_at) $f$';
      end if;
    else
    v_txt := pg_get_functiondef('cma.speed_to_lead_of(uuid,timestamptz,timestamptz)'::regprocedure);
    v_ok := position('FUNCTION cma.speed_to_lead_of(p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)' in v_txt) > 0
            and (position('cma.speed_to_lead_of(p_tenant_id, NULL::timestamp with time zone, NULL::timestamp with time zone)' in v_txt2) > 0
                 or position('cma.speed_to_lead_of(p_tenant_id, null, null)' in v_txt2) > 0);
    if v_ok then
      execute replace(replace(v_txt, 'FUNCTION cma.speed_to_lead_of(p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)',
                                     'FUNCTION pg_temp.v9zp_speed_to_lead_at(p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_at timestamp with time zone)'),
                      'now()', 'p_at');
    end if;
    end if;
    perform set_config('search_path', v_path, true);
    if v_ok then
      perform set_config('role', 'cma_app', true);
      select md5(string_agg(x::text, '|' order by x.deal_id)) into v_a from cma.speed_to_lead_of(v_t1, null, null) x;
      execute format('select md5(string_agg(x::text, ''|'' order by x.deal_id)) from pg_temp.v9zp_speed_to_lead_at(%L, null, null, %L) x',
                     v_t1, now() + case when v_provoke then interval '1 day' else interval '0' end)
        into v_b;
      perform set_config('role', 'cma_owner', true);
    end if;
    rows_ := rows_ || pg_temp.v9zp_row(12, 'V11', '191''s clock-at-read copy: the header it replaces, the copy equal at now(), the call in open_leads_of',
      v_ok and v_a = v_b, case when not v_ok then 'the header or the call 191 replaces is not in the printed definitions'
                               when v_a is distinct from v_b then 'the copy at now() differs from the function'
                               else 'the copy at now() equals the function row for row' end);

    raise exception using errcode = 'CMAOK';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || array['99', 'block ended early', 'FAIL', 'FAIL block: error ' || sqlstate || ': ' || sqlerrm];
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('search_path', v_path, true);
  insert into verify_0009zq (ord, check_name, result, detail)
  select rows_[4 * i - 3]::integer, rows_[4 * i - 2], rows_[4 * i - 1], rows_[4 * i] from generate_series(1, cardinality(rows_) / 4) i;
  insert into verify_0009zq values (98, 'ran to the end',
    case when v_provoke or cardinality(rows_) / 4 <> 13 or '99' = any (rows_) then 'FAIL' else 'OK' end,
    format('%s fixture rows', cardinality(rows_) / 4));
end
$$;

drop function if exists pg_temp.v9zp_speed_to_lead_at(uuid, timestamptz, timestamptz, timestamptz);
drop function if exists pg_temp.v9zp_speed_to_lead_rows_at(uuid, timestamptz, timestamptz, boolean, timestamptz);
drop function if exists pg_temp.v9zp_code(text);
drop function if exists pg_temp.v9zp_noon_of_40(uuid, text, timestamptz);
drop function if exists pg_temp.v9zp_cso_94(uuid);
drop function if exists pg_temp.v9zp_noon_in_178(text, integer[], date[], timestamptz);
drop function if exists pg_temp.v9zp_row(integer, text, text, boolean, text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009zq
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009zq where result <> 'OK') then 'FAIL'
                  when (select count(*) from pg_temp.verify_0009zq where result = 'OK') <> 15 then 'FAIL'
                  else 'PASS 0009zq' end,
             format('235_verify_speed_to_lead_one: %s OK, %s FAIL', (select count(*) from pg_temp.verify_0009zq where result = 'OK'),
                    (select count(*) from pg_temp.verify_0009zq where result <> 'OK'))) x
order by ord;
