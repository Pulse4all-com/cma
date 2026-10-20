-- =============================================================================================
-- 99_verify_funnel.sql: verifies addition 0008zb, reasons, record kinds and the funnel reports
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure and privileges;
-- blocks B and C work on throwaway tenants inside subtransactions that are always rolled back. Universal otherwise:
-- nothing of the seed is used; adapters, pipelines, stages, reasons, kinds, deals, tickets, contacts and owners are
-- invented data values, and no row carries a name of a customer, an address or a phone number. Every check writes one
-- row, PASS or FAIL, and the last result lists them with the verdict, because Cloud SQL Studio shows no notices. Run as
-- your own IAM login in dev, after 98_funnel.sql, from the Terminal (block C builds a tenant at about twice prod's
-- volume and times every page read); then 97, 95, 93, 91, 85, 81, 73 and 41 again.
--   A  structure and privileges: the addition row after 0008za; the three tables' columns, keys and checks; row-level
--      security with the tenant policy, the audit trigger, no delete for the application and nothing for the readers on
--      them; the reason field (deals and tickets only), source_type and checked_at, crm_record.reason; every function
--      the application's only and in the caller's rights, the readers' functions definer, the owner's, pinned, theirs
--      only; the reporting views' exact columns with no name, address, email, phone, hash or raw; the two settings and
--      the row type; the definitions written once (0008z's sales deals, the kind rule, the period cut); nothing twice
--   B  behaviour, on two throwaway tenants (Europe/Amsterdam; intake from 1 September 2026; markets NL and GB). Tenant
--      one holds a CRM connection with two lead pipelines (Sales: New, Quote, Won, Lost; Sales two: one stage), an order
--      pipeline, an uncounted deal pipeline and three ticket pipelines (cancellations, support, an uncounted one); owners
--      o-1 Anna and o-2 Bram linked, o-3 not; the reason fields first mapped to a text property, then to enumerations;
--      the deals of 28 September to 11 October 2026 with their stage times and reasons; the tickets of 1 to 12 October;
--      the kinds cancellation (by pipeline, and by category on support) and complaint (by pipeline and category).
--      Tenant two has a lost deal of the same source id. Checked as of fixed instants: the text property refused and
--      the enumeration stored, the data-quality flag kept by a refresh, the field's and the kinds' refusals, the kinds
--      by pipeline, by category and by both, the setting, the funnel per pipeline and per stage with the previous
--      period, the filters, like for like, lost reasons per reason, market (top 3), source and period with the
--      data-quality block and no reason, cancellations with their reasons and history start, no kind and an archived
--      one, per person with amounts per currency never summed, its gate, the parameters and permissions, the reporting
--      views, tenant isolation, the funnel's deals as 0008z's sales deals, the audit
--   C  speed: a throwaway tenant at about twice prod's volume of 19 October 2026 (4,000 sales deals over three months
--      with 13,000 stage times, 3,500 order deals, 6,000 contacts, 2,000 store orders, 8,000 tickets of which 2,000
--      cancellations); every page read of October as the application (row-level security on) under verify.max_ms,
--      the best of three
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED instead of PASS.
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
select set_config('verify.max_ms', '1000', false);     -- a month's page read, as the application

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the session, so every
-- block below stops at once and the verdict says REFUSED, also where the client carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 99 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008zb;
create temp table verify_0008zb (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zb_code(p_sql text)
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

-- The fastest of p_runs runs of a read, in milliseconds, every row fetched (as 91)
create or replace function pg_temp.v0008zb_best_ms(p_sql text, p_runs integer)
returns numeric
language plpgsql
as $$
declare
  v_t0   timestamptz;
  v_ms   numeric;
  v_best numeric;
  r      record;
begin
  for i in 1 .. p_runs loop
    v_t0 := clock_timestamp();
    for r in execute p_sql loop
      null;
    end loop;
    v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    v_best := least(coalesce(v_best, v_ms), v_ms);
  end loop;
  return v_best;
end
$$;

-- A pipeline's funnel figures as one line: created/won/lost/win rate/median days to won/to lost (- for none)
create or replace function pg_temp.v0008zb_fig(j jsonb)
returns text
language sql
as $$
  select concat_ws('/', j ->> 'created', j ->> 'won', j ->> 'lost', coalesce(j ->> 'win_rate', '-'), coalesce(j ->> 'median_days_to_won', '-'),
                   coalesce(j ->> 'median_days_to_lost', '-'))
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
  v_t       text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008za
  insert into verify_0008zb values (1, 'A1 addition 0008zb recorded, after 0008za',
    case when exists (select 1 from cma.schema_migration where version = '0008zb')
              and exists (select 1 from cma.schema_migration where version = '0008za') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the tables: columns with types and nullability, keys, checks and foreign keys
  v_bad := '';
  if (select string_agg(column_name || ':' || udt_name || ':' || is_nullable, ',' order by ordinal_position)
      from information_schema.columns where table_schema = 'cma' and table_name = 'record_kind')
     is distinct from 'id:uuid:NO,tenant_id:uuid:NO,key:text:NO,label:text:NO,record_type:text:NO,status:text:NO,sort_order:int4:NO,'
                      || 'created_at:timestamptz:NO,updated_at:timestamptz:NO' then
    v_bad := v_bad || 'record_kind columns; ';
  end if;
  if (select string_agg(column_name || ':' || udt_name || ':' || is_nullable, ',' order by ordinal_position)
      from information_schema.columns where table_schema = 'cma' and table_name = 'connection_record_kind')
     is distinct from 'id:uuid:NO,tenant_id:uuid:NO,connection_id:uuid:NO,kind_key:text:NO,pipeline_id:text:YES,category:text:YES,status:text:NO,'
                      || 'created_at:timestamptz:NO,updated_at:timestamptz:NO' then
    v_bad := v_bad || 'connection_record_kind columns; ';
  end if;
  if (select string_agg(column_name || ':' || udt_name || ':' || is_nullable, ',' order by ordinal_position)
      from information_schema.columns where table_schema = 'cma' and table_name = 'connection_reason')
     is distinct from 'tenant_id:uuid:NO,connection_id:uuid:NO,record_type:text:NO,value:text:NO,label:text:NO,sort_order:int4:NO,'
                      || 'is_data_quality:bool:NO,status:text:NO,refreshed_at:timestamptz:NO,updated_at:timestamptz:NO' then
    v_bad := v_bad || 'connection_reason columns; ';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.record_kind'::regclass and contype = 'u' and pg_get_constraintdef(oid) = 'UNIQUE (tenant_id, key)')
     or not exists (select 1 from pg_constraint where conrelid = 'cma.record_kind'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%^[a-z][a-z0-9_-]{1,40}$%')
     or not exists (select 1 from pg_constraint where conrelid = 'cma.record_kind'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%deal%ticket%')
     or not exists (select 1 from pg_constraint where conrelid = 'cma.connection_record_kind'::regclass and contype = 'u'
                    and pg_get_constraintdef(oid) = 'UNIQUE NULLS NOT DISTINCT (tenant_id, connection_id, kind_key, pipeline_id, category)')
     or not exists (select 1 from pg_constraint where conrelid = 'cma.connection_record_kind'::regclass and contype = 'c'
                    and pg_get_constraintdef(oid) like '%pipeline_id IS NOT NULL%category IS NOT NULL%')
     or not exists (select 1 from pg_constraint where conrelid = 'cma.connection_record_kind'::regclass and contype = 'f' and confrelid = 'cma.record_kind'::regclass)
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.connection_reason'::regclass and contype = 'p')
        is distinct from 'PRIMARY KEY (tenant_id, connection_id, record_type, value)' then
    v_bad := v_bad || 'keys or checks; ';
  end if;
  insert into verify_0008zb values (2, 'A2 the kind, rule and reason tables: columns, keys, checks and foreign keys',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. tenant-aware as every table: row-level security with the tenant policy, the audit trigger; the application may
  --     read, add and change, never delete; the readers nothing on the tables
  v_bad := '';
  foreach v_t in array array['cma.record_kind', 'cma.connection_record_kind', 'cma.connection_reason'] loop
    if not (select relrowsecurity from pg_class where oid = v_t::regclass)
       or not exists (select 1 from pg_policy where polrelid = v_t::regclass and polname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = v_t::regclass and tgname = 'audit' and not tgisinternal)
       or not has_table_privilege('cma_app', v_t, 'select') or not has_table_privilege('cma_app', v_t, 'insert')
       or not has_table_privilege('cma_app', v_t, 'update') or has_table_privilege('cma_app', v_t, 'delete')
       or has_table_privilege('cma_readonly', v_t, 'select') then
      v_bad := v_bad || v_t || '; ';
    end if;
  end loop;
  insert into verify_0008zb values (3, 'A3 row-level security, the audit trigger, no delete for the application, nothing for the readers',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the reason field: connection_field takes reason for deals and tickets only; source_type and checked_at; the
  --     record's reason at most 100 characters
  v_bad := '';
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_entity_field_check')
     not like '%reason%deal%ticket%' then
    v_bad := v_bad || 'entity check; ';
  end if;
  if (select string_agg(column_name || ':' || udt_name || ':' || is_nullable, ',' order by column_name) from information_schema.columns
      where table_schema = 'cma' and table_name = 'connection_field' and column_name in ('source_type', 'checked_at'))
     is distinct from 'checked_at:timestamptz:YES,source_type:text:YES' then
    v_bad := v_bad || 'source_type, checked_at; ';
  end if;
  if (select udt_name || ':' || is_nullable from information_schema.columns where table_schema = 'cma' and table_name = 'crm_record' and column_name = 'reason')
     is distinct from 'text:YES'
     or not exists (select 1 from pg_constraint where conrelid = 'cma.crm_record'::regclass and conname = 'crm_record_reason_check'
                    and pg_get_constraintdef(oid) like '%100%') then
    v_bad := v_bad || 'crm_record.reason; ';
  end if;
  insert into verify_0008zb values (4, 'A4 the reason field for deals and tickets, its checked type, the record''s reason',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. every function the application's only and in the caller's rights; the readers' functions definer, the owner's,
  --     search path pinned with pg_temp last, the readers' only
  v_bad := '';
  foreach v_fn in array array[
    'cma.kind_rule_matches(text,text,text,text)', 'cma.record_kind_of(uuid,uuid,text,text,text)', 'cma.set_record_kind(text,text,text,integer)',
    'cma.set_record_kind_status(text,text)', 'cma.set_record_kind_rule(uuid,text,text,text,boolean)', 'cma.record_kinds()',
    'cma.is_per_person_list(text)', 'cma.set_connection_field(uuid,text,text,text,text,smallint)', 'cma.ingest_upsert_records(uuid,jsonb)',
    'cma.ingest_upsert_reasons(uuid,jsonb)', 'cma.set_reason_data_quality(uuid,text,text,boolean)', 'cma.reason_state_of(text,text)',
    'cma.connection_config(uuid)', 'cma.funnel_deals_of(uuid,timestamptz)', 'cma.funnel_rows_of(uuid,timestamptz)',
    'cma.in_period(date,time,date,date,time)', 'cma.funnel_filters_check(text,text,text,text)', 'cma.funnel_filter(cma.funnel_deal[],text,text,text)',
    'cma.funnel_filter_lists_from(cma.funnel_deal[])', 'cma.funnel_figures_from(cma.funnel_deal[],date,date,time)',
    'cma.funnel_pipelines_from(cma.funnel_deal[],date,date,date,date,time)', 'cma.funnel_stages_of(uuid,cma.funnel_deal[],text,date,date,date,date,time)',
    'cma.funnel_history_start_of(uuid,cma.funnel_deal[])', 'cma.deal_funnel_page_of(uuid,date,date,text,text,text,timestamptz)',
    'cma.funnel_lost_in(cma.funnel_deal[],date,date,time)', 'cma.deal_reasons_of(uuid)', 'cma.reason_field_state_of(uuid,text)',
    'cma.lost_figures_from(uuid,cma.funnel_deal[])', 'cma.lost_reasons_from(uuid,cma.funnel_deal[],text,integer)',
    'cma.lost_reasons_page_of(uuid,date,date,text,text,text,text,integer,timestamptz)', 'cma.cancellation_records_of(uuid,timestamptz,timestamptz)',
    'cma.cancellation_figures_from(jsonb,date,date,time)', 'cma.cancellations_page_of(uuid,date,date,text,text,integer,timestamptz)',
    'cma.deal_person_figures_from(cma.funnel_deal[])', 'cma.deals_per_person_of(uuid,date,date,text,text,text,timestamptz)',
    'cma.deal_funnel_page(date,date,text,text,text)', 'cma.lost_reasons_page(date,date,text,text,text,text)',
    'cma.cancellations_page(date,date,text,text)', 'cma.deals_per_person_page(date,date,text,text,text)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  foreach v_fn in array array['cma_read.deal_funnel_rows_of()', 'cma_read.cancellation_rows_of()'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
          or (select array_to_string(proconfig, ',') from pg_proc where oid = to_regprocedure(v_fn)) is distinct from 'search_path=pg_catalog, cma, pg_temp'
          or not has_function_privilege('cma_readonly', v_fn, 'execute') or has_function_privilege('cma_app', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  insert into verify_0008zb values (5, 'A5 every function the application''s only and invoker; the readers'' functions definer, the owner''s, pinned, theirs only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A6. the reporting views' exact columns, readable by the readers; no name, address, email, phone, hash or raw
  v_bad := '';
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'deal_funnel_rows')
     is distinct from 'tenant_id,deal_id,connection_id,deal_source_id,pipeline_id,current_stage_id,created_at,closed_at,stage_outcome,outcome,reason,'
                      || 'market,stage_id,entered_at,exited_at' then
    v_bad := v_bad || 'deal_funnel_rows; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'cancellation_rows')
     is distinct from 'tenant_id,kind_key,record_id,connection_id,record_type,source_id,pipeline_id,stage_id,created_at,is_closed,closed_at,reason,market' then
    v_bad := v_bad || 'cancellation_rows; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'connection_reason')
     is distinct from 'tenant_id,connection_id,record_type,value,label,sort_order,is_data_quality,status,refreshed_at,updated_at'
     or (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
         where table_schema = 'cma_read' and table_name = 'record_kind')
        is distinct from 'id,tenant_id,key,label,record_type,status,sort_order,created_at,updated_at'
     or (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
         where table_schema = 'cma_read' and table_name = 'connection_record_kind')
        is distinct from 'id,tenant_id,connection_id,kind_key,pipeline_id,category,status,created_at,updated_at'
     or (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
         where table_schema = 'cma_read' and table_name = 'crm_record_detail')
        is distinct from 'id,tenant_id,connection_id,record_type,source_id,amount,currency,source_channel,category,reason' then
    v_bad := v_bad || 'the catalog views or crm_record_detail; ';
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'cma_read' and table_name in ('deal_funnel_rows', 'cancellation_rows', 'connection_reason', 'record_kind', 'connection_record_kind')
               and (column_name ~ '(name|address|email|phone|hash|raw|subject|body|owner_ref)')) then
    v_bad := v_bad || 'a personal or raw column; ';
  end if;
  if not has_table_privilege('cma_readonly', 'cma_read.deal_funnel_rows', 'select') or not has_table_privilege('cma_readonly', 'cma_read.cancellation_rows', 'select')
     or not has_table_privilege('cma_readonly', 'cma_read.connection_reason', 'select') or not has_table_privilege('cma_readonly', 'cma_read.record_kind', 'select')
     or not has_table_privilege('cma_readonly', 'cma_read.connection_record_kind', 'select') then
    v_bad := v_bad || 'the readers'' privileges; ';
  end if;
  insert into verify_0008zb values (6, 'A6 the reporting views'' exact columns; no name, address, email, phone, hash or raw',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A7. the settings in the catalog (reports.cancellation_kind text, empty by default; reports.per_person naming deals and
  --     attempts); the row type's 24 fields; nothing twice
  v_bad := '';
  if (select string_agg(s.key || ':' || s.value_type || ':' || coalesce(s.default_value, '-'), ' ' order by s.key) from cma.setting s
      where s.key in ('reports.cancellation_kind', 'reports.per_person')) is distinct from 'reports.cancellation_kind:text: reports.per_person:text:'
     or (select s.description from cma.setting s where s.key = 'reports.per_person') not like '%attempts and deals%' then
    v_bad := v_bad || 'settings; ';
  end if;
  if (select count(*) from pg_attribute a where a.attrelid = (select t.typrelid from pg_type t where t.oid = to_regtype('cma.funnel_deal'))
      and a.attnum > 0 and not a.attisdropped) <> 24
     or (select count(*) from cma.schema_migration where version = '0008zb') <> 1
     or (select count(*) from cma.setting where key = 'reports.cancellation_kind') <> 1 then
    v_bad := v_bad || 'the row type or something twice; ';
  end if;
  if not cma.is_per_person_list('email,orders,attempts,deals') or cma.is_per_person_list('deals,deals') or cma.is_per_person_list('deal') then
    v_bad := v_bad || 'the per-person list; ';
  end if;
  insert into verify_0008zb values (7, 'A7 the two settings, the row type''s 24 fields, nothing twice, the per-person list takes deals',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A8. the definitions written once: the funnel's deals are 0008z's sales deals; the kinds read the rule's match; the
  --     periods cut by cma.in_period; the reason stored only for an enumeration
  v_bad := '';
  if (select prosrc from pg_proc where oid = 'cma.funnel_deals_of(uuid,timestamptz)'::regprocedure) !~ 'cma\.sales_deals_of\(' then
    v_bad := v_bad || 'funnel_deals_of; ';
  end if;
  if (select prosrc from pg_proc where oid = 'cma.record_kind_of(uuid,uuid,text,text,text)'::regprocedure) !~ 'cma\.kind_rule_matches\('
     or (select prosrc from pg_proc where oid = 'cma.cancellation_records_of(uuid,timestamptz,timestamptz)'::regprocedure) !~ 'cma\.kind_rule_matches\(' then
    v_bad := v_bad || 'the kind rule; ';
  end if;
  if (select prosrc from pg_proc where oid = 'cma.funnel_figures_from(cma.funnel_deal[],date,date,time)'::regprocedure) !~ 'cma\.in_period\('
     or (select prosrc from pg_proc where oid = 'cma.funnel_stages_of(uuid,cma.funnel_deal[],text,date,date,date,date,time)'::regprocedure) !~ 'cma\.in_period\('
     or (select prosrc from pg_proc where oid = 'cma.funnel_lost_in(cma.funnel_deal[],date,date,time)'::regprocedure) !~ 'cma\.in_period\('
     or (select prosrc from pg_proc where oid = 'cma.cancellation_figures_from(jsonb,date,date,time)'::regprocedure) !~ 'cma\.in_period\(' then
    v_bad := v_bad || 'the period cut; ';
  end if;
  if (select prosrc from pg_proc where oid = 'cma.ingest_upsert_records(uuid,jsonb)'::regprocedure) !~ 'source_type = ''enumeration''' then
    v_bad := v_bad || 'the enumeration rule; ';
  end if;
  insert into verify_0008zb values (8, 'A8 written once: 0008z''s sales deals, the kind rule, the period cut, the enumeration rule',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_reader1 uuid; v_super1 uuid; v_agent1 uuid; v_anna uuid; v_bram uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid;
  v_crm uuid; v_crm2 uuid;
  v_role uuid;
  v_txt text; v_a text; v_b text; v_c text;
  j jsonb; k jsonb;
  r record;
  v_now  timestamptz := '2026-10-14 10:00:00+00';   -- Wednesday 14 October 2026, 12:00 in Amsterdam
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people and roles (as the owner)
    v_t1 := cma.create_tenant('verify-0008zb-one', 'Verify 0008zb one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zb-two', 'Verify 0008zb two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader1@example.invalid', 'reader1') returning id into v_reader1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-super1@example.invalid', 'super1') returning id into v_super1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-anna@example.invalid', 'Anna Verify') returning id into v_anna;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-bram@example.invalid', 'Bram Verify') returning id into v_bram;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_reader1, 'verify_reader'), (v_t1, v_super1, 'supervisor'),
                 (v_t1, v_agent1, 'agent'), (v_t1, v_anna, 'agent'), (v_t1, v_bram, 'agent'),
                 (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, settings)
    values (v_t1, 'verifycrm', 'Verify funnel CRM', 'portal-1',
            '{"record_url_deal": "https://crm.example.invalid/{account}/deal/{id}", "record_url_ticket": "https://crm.example.invalid/{account}/ticket/{id}"}')
    returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verifycrm', 'Verify funnel CRM two', 'portal-2') returning id into v_crm2;
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): markets, settings, the owners
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform cma.set_tenant_setting('reports.per_person', 'deals');
    perform cma.set_user_external_id(v_anna, 'verifycrm_owner', 'o-1');
    perform cma.set_user_external_id(v_bram, 'verifycrm_owner', 'o-2');

    -- the catalogs from the source (the Ingest user)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "New", "order": 1, "isClosed": false, "outcome": null},
         {"stageId": "s2", "label": "Quote", "order": 2, "isClosed": false, "outcome": null},
         {"stageId": "sw", "label": "Won", "order": 8, "isClosed": true, "outcome": "won"},
         {"stageId": "sl", "label": "Lost", "order": 9, "isClosed": true, "outcome": "lost"}]},
      {"recordType": "deal", "pipelineId": "sales2", "label": "Sales two", "stages": [
         {"stageId": "q1", "label": "Open", "order": 1, "isClosed": false, "outcome": null},
         {"stageId": "qw", "label": "Won", "order": 8, "isClosed": true, "outcome": "won"}]},
      {"recordType": "deal", "pipelineId": "selfserve", "label": "Self Serve", "stages": [{"stageId": "o1", "label": "Won", "order": 1, "isClosed": true, "outcome": "won"}]},
      {"recordType": "deal", "pipelineId": "test", "label": "Test", "stages": [{"stageId": "x1", "label": "Open", "order": 1, "isClosed": false}]},
      {"recordType": "ticket", "pipelineId": "cancel", "label": "Cancellations", "stages": [{"stageId": "c1", "label": "New", "order": 1, "isClosed": false},
         {"stageId": "c4", "label": "Closed", "order": 4, "isClosed": true}]},
      {"recordType": "ticket", "pipelineId": "support", "label": "Support", "stages": [{"stageId": "t1", "label": "New", "order": 1, "isClosed": false},
         {"stageId": "t4", "label": "Closed", "order": 4, "isClosed": true}]},
      {"recordType": "ticket", "pipelineId": "spam", "label": "Spam", "stages": [{"stageId": "p1", "label": "New", "order": 1, "isClosed": false}]}]');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_pipeline_order(v_crm, 'deal', 'selfserve', true);
    perform cma.set_connection_pipeline(v_crm, 'deal', 'test', false, false, null);
    perform cma.set_connection_pipeline(v_crm, 'ticket', 'spam', false, false, null);
    perform cma.set_stage_read_times(v_crm, 'deal', 'sales', 'sl', false);

    -- B1. the deal reason mapped to a text property: the adapter reads its type (string), Sources says refused, and a deal
    --     read with a value stores none
    perform cma.set_connection_field(v_crm, 'deal', 'reason', '', 'lost_text', 1::smallint);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_reasons(v_crm, '[{"recordType": "deal", "property": "lost_text", "type": "string"}]');
    perform cma.ingest_upsert_records(v_crm, '[{"recordType": "deal", "sourceId": "dRef", "pipelineId": "test", "stageId": "x1", "reason": "a text a person typed",
      "createdAt": "2026-10-07T10:00:00Z", "updatedAt": "2026-10-07T10:00:00Z"}]');
    perform set_config('app.user_id', v_admin1::text, true);
    j := cma.connection_config(v_crm);
    select string_agg(format('%s/%s/%s', f ->> 'property', coalesce(f ->> 'sourceType', '-'), f ->> 'state'), ' ') into v_txt
    from jsonb_array_elements(j -> 'fields') f where f ->> 'field' = 'reason';
    v_txt := v_txt || ' ' || coalesce((select r2.reason from cma.crm_record r2 where r2.tenant_id = v_t1 and r2.source_id = 'dRef'), 'none')
             || ' ' || (select count(*) from cma.connection_reason cr where cr.tenant_id = v_t1);
    v_rows := v_rows || array['11', 'B1 a text property refused: its type read, the state refused, no reason stored, no catalog',
      case when v_txt = 'lost_text/string/refused none 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. remapped to an enumeration: the check cleared (unchecked) until the adapter reads it; then enumeration, the
    --     options in the catalog and the option's value stored (at most 100 characters); the ticket reason likewise
    perform cma.set_connection_field(v_crm, 'deal', 'reason', '', 'lost_dropdown', 1::smallint);
    select f ->> 'state' into v_a from jsonb_array_elements(cma.connection_config(v_crm) -> 'fields') f where f ->> 'field' = 'reason';
    perform cma.set_connection_field(v_crm, 'ticket', 'reason', '', 'cancel_reason', 1::smallint);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_reasons(v_crm, '[
      {"recordType": "deal", "property": "LOST_DROPDOWN", "type": "enumeration", "options": [
         {"value": "too_expensive", "label": "Too Expensive", "order": 1}, {"value": "bad_timing", "label": "Bad Timing", "order": 2},
         {"value": "bad_fit", "label": "Bad Fit", "order": 3}, {"value": "ordered_elsewhere", "label": "Ordered Elsewhere", "order": 4},
         {"value": "garbage", "label": "Garbage", "order": 5}, {"value": "duplicate", "label": "Duplicate", "order": 6},
         {"value": "wrong_phone", "label": "Wrong Phone", "order": 7}]},
      {"recordType": "ticket", "property": "cancel_reason", "type": "enumeration", "options": [
         {"value": "price", "label": "Price", "order": 1}, {"value": "moving", "label": "Moving", "order": 2}]},
      {"recordType": "ticket", "property": "not_mapped", "type": "enumeration", "options": [{"value": "x", "label": "X"}]}]');
    perform cma.ingest_upsert_records(v_crm, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'dRef', 'pipelineId', 'test', 'stageId', 'x1', 'reason', '  bad_fit ',
                         'createdAt', '2026-10-07T10:00:00Z', 'updatedAt', '2026-10-07T11:00:00Z'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'dRef2', 'pipelineId', 'test', 'stageId', 'x1', 'reason', repeat('v', 120),
                         'createdAt', '2026-10-07T10:00:00Z', 'updatedAt', '2026-10-07T11:00:00Z')));
    perform set_config('app.user_id', v_admin1::text, true);
    select string_agg(format('%s:%s', f ->> 'entity', f ->> 'state'), ' ' order by f ->> 'entity') into v_b
    from jsonb_array_elements(cma.connection_config(v_crm) -> 'fields') f where f ->> 'field' = 'reason';
    v_txt := v_a || ' ' || v_b || ' ' || (select count(*) from cma.connection_reason cr where cr.tenant_id = v_t1)
             || ' ' || (select r2.reason from cma.crm_record r2 where r2.tenant_id = v_t1 and r2.source_id = 'dRef')
             || ' ' || (select length(r2.reason) from cma.crm_record r2 where r2.tenant_id = v_t1 and r2.source_id = 'dRef2');
    v_rows := v_rows || array['12', 'B2 an enumeration: unchecked until read, then its options and values stored',
      case when v_txt = 'unchecked deal:enumeration ticket:enumeration 9 bad_fit 100' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. a person's data-quality flag survives a refresh that changes labels and order and drops an option (archived, its
    --     flag kept); the refusals of the flag
    perform cma.set_reason_data_quality(v_crm, 'deal', 'garbage', true);
    perform cma.set_reason_data_quality(v_crm, 'deal', 'duplicate', true);
    perform cma.set_reason_data_quality(v_crm, 'deal', 'wrong_phone', true);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_reasons(v_crm, '[
      {"recordType": "deal", "property": "lost_dropdown", "type": "enumeration", "options": [
         {"value": "too_expensive", "label": "Too expensive", "order": 9}, {"value": "bad_timing", "label": "Bad Timing", "order": 2},
         {"value": "bad_fit", "label": "Bad Fit", "order": 3}, {"value": "ordered_elsewhere", "label": "Ordered Elsewhere", "order": 4},
         {"value": "garbage", "label": "Garbage", "order": 5}, {"value": "duplicate", "label": "Duplicate", "order": 6}]}]');
    v_txt := pg_temp.v0008zb_code(format('select cma.set_reason_data_quality(%L, ''deal'', ''garbage'', false)', v_crm));
    perform set_config('app.user_id', v_admin1::text, true);
    select string_agg(format('%s=%s/%s/%s/%s', cr.value, cr.label, cr.sort_order, cr.is_data_quality::text, cr.status), ' ' order by cr.value) into v_a
    from cma.connection_reason cr where cr.tenant_id = v_t1 and cr.record_type = 'deal' and cr.value in ('too_expensive', 'garbage', 'wrong_phone');
    v_txt := v_a || ' ' || v_txt
      || ' ' || pg_temp.v0008zb_code(format('select cma.set_reason_data_quality(%L, ''deal'', ''nope'', true)', v_crm))
      || ' ' || pg_temp.v0008zb_code(format('select cma.set_reason_data_quality(%L, ''deal'', ''garbage'', null)', v_crm))
      || ' ' || pg_temp.v0008zb_code(format('select cma.set_reason_data_quality(%L, ''deal'', ''garbage'', true)', v_crm2));
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zb_code(format('select cma.set_reason_data_quality(%L, ''deal'', ''garbage'', false)', v_crm));
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['13', 'B3 the data-quality flag kept by a refresh, an option gone archived; the flag''s refusals',
      case when v_txt = 'garbage=Garbage/5/true/active too_expensive=Too expensive/9/false/active wrong_phone=Wrong Phone/7/true/archived CMA06 CMA02 CMA04 CMA02 CMA06'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. the reason field for deals and tickets only, and the adapter's malformed answers refused
    v_txt := pg_temp.v0008zb_code(format('select cma.set_connection_field(%L, ''contact'', ''reason'', '''', ''x'', 1::smallint)', v_crm))
      || ' ' || pg_temp.v0008zb_code(format('select cma.set_connection_field(%L, ''task'', ''reason'', '''', ''x'', 1::smallint)', v_crm));
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt
      || ' ' || pg_temp.v0008zb_code(format('select cma.ingest_upsert_reasons(%L, ''[{"recordType": "contact", "property": "x", "type": "enumeration", "options": []}]'')', v_crm))
      || ' ' || pg_temp.v0008zb_code(format('select cma.ingest_upsert_reasons(%L, ''[{"recordType": "deal", "property": "lost_dropdown", "type": "enumeration"}]'')', v_crm))
      || ' ' || pg_temp.v0008zb_code(format('select cma.ingest_upsert_reasons(%L, ''[{"recordType": "deal", "property": "lost_dropdown", "type": "enumeration", "options": [{"label": "no value"}]}]'')', v_crm));
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zb_code(format('select cma.ingest_upsert_reasons(%L, ''[]'')', v_crm));
    v_rows := v_rows || array['14', 'B4 reason for deals and tickets only; malformed reason properties and a person without ingest.write refused',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA06' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- the kinds and their rules (the admin); the setting with spaces
    perform cma.set_record_kind('cancellation', 'Cancellation request', 'ticket', 10);
    perform cma.set_record_kind('complaint', ' Complaint ', 'ticket', 20);
    perform cma.set_record_kind_rule(v_crm, 'cancellation', 'cancel', null, true);
    perform cma.set_record_kind_rule(v_crm, 'cancellation', '', 'Cancellation', true);
    perform cma.set_record_kind_rule(v_crm, 'complaint', 'support', 'Complaint', true);
    perform cma.set_tenant_setting('reports.cancellation_kind', ' cancellation ');

    -- B5. the kinds' refusals
    v_txt := pg_temp.v0008zb_code('select cma.set_record_kind(''X'', ''X'', ''ticket'', null)')
      || ' ' || pg_temp.v0008zb_code('select cma.set_record_kind(''other'', '' '', ''ticket'', null)')
      || ' ' || pg_temp.v0008zb_code('select cma.set_record_kind(''other'', ''Other'', ''contact'', null)')
      || ' ' || pg_temp.v0008zb_code('select cma.set_record_kind(''complaint'', ''Complaint'', ''deal'', null)')
      || ' ' || pg_temp.v0008zb_code('select cma.set_record_kind_status(''complaint'', ''gone'')')
      || ' ' || pg_temp.v0008zb_code('select cma.set_record_kind_status(''nope'', ''archived'')')
      || ' ' || pg_temp.v0008zb_code(format('select cma.set_record_kind_rule(%L, ''complaint'', '''', '' '', true)', v_crm))
      || ' ' || pg_temp.v0008zb_code(format('select cma.set_record_kind_rule(%L, ''nope'', ''support'', null, true)', v_crm))
      || ' ' || pg_temp.v0008zb_code(format('select cma.set_record_kind_rule(%L, ''complaint'', ''sales'', null, true)', v_crm))
      || ' ' || pg_temp.v0008zb_code(format('select cma.set_record_kind_rule(%L, ''complaint'', ''support'', null, true)', v_crm2));
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zb_code('select cma.set_record_kind(''other'', ''Other'', ''ticket'', null)')
      || ' ' || pg_temp.v0008zb_code('select cma.record_kinds()');
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['15', 'B5 the kinds'' refusals: key, label, record type, a changed type, status, a rule''s values, kind and pipeline, the permission',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA03 CMA04 CMA02 CMA04 CMA02 CMA02 CMA02 CMA06 CMA06' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. a record's kinds by pipeline, by category and by both; an archived rule and an archived kind match nothing; the
    --     read of the kinds with their rules
    v_a := concat_ws(' ', array_to_string(cma.record_kind_of(v_t1, v_crm, 'ticket', 'cancel', null), ','),
                     array_to_string(cma.record_kind_of(v_t1, v_crm, 'ticket', 'support', 'Cancellation'), ','),
                     array_to_string(cma.record_kind_of(v_t1, v_crm, 'ticket', 'support', 'Complaint'), ','),
                     array_to_string(cma.record_kind_of(v_t1, v_crm, 'ticket', 'cancel', 'Complaint'), ','),
                     '[' || array_to_string(cma.record_kind_of(v_t1, v_crm, 'ticket', 'support', null), ',') || ']',
                     '[' || array_to_string(cma.record_kind_of(v_t1, v_crm, 'deal', 'cancel', null), ',') || ']',
                     '[' || array_to_string(cma.record_kind_of(v_t1, v_crm2, 'ticket', 'cancel', null), ',') || ']');
    perform cma.set_record_kind_rule(v_crm, 'complaint', 'support', 'Complaint', false);
    v_b := '[' || array_to_string(cma.record_kind_of(v_t1, v_crm, 'ticket', 'support', 'Complaint'), ',') || ']';
    perform cma.set_record_kind_rule(v_crm, 'complaint', 'support', 'Complaint', true);
    perform cma.set_record_kind_status('complaint', 'archived');
    v_b := v_b || '[' || array_to_string(cma.record_kind_of(v_t1, v_crm, 'ticket', 'support', 'Complaint'), ',') || ']';
    perform cma.set_record_kind_status('complaint', 'active');
    v_b := v_b || array_to_string(cma.record_kind_of(v_t1, v_crm, 'ticket', 'support', 'Complaint'), ',');
    j := cma.record_kinds();
    select string_agg(format('%s:%s:%s:%s:%s', x ->> 'key', x ->> 'label', x ->> 'recordType', x ->> 'isCancellationKind',
                             jsonb_array_length(x -> 'rules')), ' ' order by x ->> 'key') into v_c
    from jsonb_array_elements(j) x;
    v_txt := v_a || ' | ' || v_b || ' | ' || v_c;
    v_rows := v_rows || array['16', 'B6 a record''s kinds by pipeline, category and both; archived rules and kinds match nothing; the read',
      case when v_txt = 'cancellation cancellation complaint cancellation [] [] [] | [][]complaint | cancellation:Cancellation request:ticket:true:2 complaint:Complaint:ticket:false:1'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. reports.cancellation_kind: trimmed; an unknown kind, an archived kind and another tenant's kind refused; empty
    --     allowed
    v_a := cma.setting_of(v_t1, 'reports.cancellation_kind');
    perform cma.set_record_kind_status('complaint', 'archived');
    v_txt := v_a
      || ' ' || pg_temp.v0008zb_code('select cma.set_tenant_setting(''reports.cancellation_kind'', ''nope'')')
      || ' ' || pg_temp.v0008zb_code('select cma.set_tenant_setting(''reports.cancellation_kind'', ''complaint'')')
      || ' ' || pg_temp.v0008zb_code('select cma.set_tenant_setting(''reports.cancellation_kind'', '''')');
    perform cma.set_record_kind_status('complaint', 'active');
    perform cma.set_tenant_setting('reports.cancellation_kind', 'cancellation');
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zb_code('select cma.set_tenant_setting(''reports.cancellation_kind'', ''cancellation'')')
      || ' ' || (select count(*) from cma.record_kind);
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['17', 'B7 reports.cancellation_kind trimmed; an unknown, an archived and another tenant''s kind refused',
      case when v_txt = 'cancellation CMA04 CMA04 ok CMA04 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- the deals (the Ingest user; UTC, Amsterdam is UTC+2 until 25 October), their stage times and the tickets
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_crm, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'recordType', 'deal', 'sourceId', d.id, 'pipelineId', d.pipeline, 'stageId', d.stage, 'ownerRef', d.owner, 'market', d.market,
               'sourceChannel', d.channel, 'contactId', 'k' || d.id, 'createdAt', d.created, 'closedAt', d.closed, 'reason', d.reason,
               'amount', d.amount, 'currency', d.currency, 'updatedAt', '2026-10-12T00:00:00Z')))
      from (values
        ('dA', 'sales', 'sw', 'o-1', 'NL', 'PAID_SEARCH', '2026-10-05T08:00:00Z', '2026-10-08T12:00:00Z', null, 100, 'EUR'),
        ('dB', 'sales', 'sl', 'o-2', 'GB', 'PAID_SEARCH', '2026-10-05T09:00:00Z', '2026-10-07T09:00:00Z', 'too_expensive', 50, 'GBP'),
        ('dC', 'sales', 'sl', 'o-1', 'NL', 'DIRECT', '2026-10-06T10:00:00Z', '2026-10-09T10:00:00Z', 'garbage', null, null),
        ('dD', 'sales', 'sl', 'o-3', 'NL', 'DIRECT', '2026-10-06T11:00:00Z', '2026-10-10T11:00:00Z', null, null, null),
        ('dE', 'sales', 's2', 'o-2', 'NL', 'PAID_SEARCH', '2026-10-07T08:00:00Z', null, null, null, null),
        ('dF', 'sales', 's1', 'o-1', 'NL', 'PAID_SEARCH', '2026-10-08T08:00:00Z', null, null, null, null),
        ('dG', 'sales', 'sw', 'o-1', 'NL', 'PAID_SEARCH', '2026-09-29T08:00:00Z', '2026-10-06T08:00:00Z', null, 200, null),
        ('dH', 'sales', 'sl', 'o-2', 'NL', 'PAID_SEARCH', '2026-09-30T09:00:00Z', '2026-10-01T09:00:00Z', 'too_expensive', null, null),
        ('dJ', 'sales', 'sw', 'o-1', 'GB', 'PAID_SEARCH', '2026-10-09T10:00:00Z', '2026-10-10T10:00:00Z', null, 80, 'GBP'),
        ('dM', 'sales', 'sl', 'o-2', 'GB', 'PAID_SEARCH', '2026-10-08T09:00:00Z', '2026-10-11T09:00:00Z', 'bad_timing', null, null),
        ('dN', 'sales', 'sl', 'o-2', 'GB', 'PAID_SEARCH', '2026-10-08T10:00:00Z', '2026-10-10T12:00:00Z', 'duplicate', null, null),
        ('dO', 'sales', 'sl', 'o-1', 'NL', 'PAID_SEARCH', '2026-10-07T12:00:00Z', '2026-10-09T12:00:00Z', 'too_expensive', null, null),
        ('dP', 'sales', 'sl', 'o-1', 'NL', 'PAID_SEARCH', '2026-10-07T13:00:00Z', '2026-10-08T13:00:00Z', 'ordered_elsewhere', null, null),
        ('dQ', 'sales', 'sl', 'o-2', 'NL', null, '2026-10-09T07:00:00Z', '2026-10-09T08:00:00Z', 'bad_timing', null, null),
        ('dR', 'sales', 'sl', 'o-1', 'NL', 'PAID_SEARCH', '2026-10-08T11:00:00Z', '2026-10-11T08:00:00Z', 'too_expensive', null, null),
        ('dS', 'sales', 'sl', 'o-2', 'NL', 'PAID_SEARCH', '2026-10-09T11:00:00Z', '2026-10-10T09:00:00Z', 'bad_fit', null, null),
        ('dT', 'sales2', 'q1', 'o-1', 'NL', 'PAID_SEARCH', '2026-10-06T09:00:00Z', null, null, null, null),
        ('dU', 'sales', 's1', 'o-1', 'NL', 'PAID_SEARCH', '2026-10-11T07:00:00Z', null, null, null, null),
        ('dV', 'sales', 's1', 'o-1', 'NL', 'PAID_SEARCH', '2026-10-11T12:00:00Z', null, null, null, null),
        ('dX', 'selfserve', 'o1', null, 'NL', null, '2026-10-07T10:00:00Z', '2026-10-07T10:00:00Z', null, 90, 'EUR'),
        ('dY', 'test', 'x1', 'o-1', 'NL', 'PAID_SEARCH', '2026-10-07T10:00:00Z', null, null, null, null),
        ('dZ', 'sales', 'sl', 'o-1', 'NL', 'PAID_SEARCH', '2026-08-31T10:00:00Z', '2026-10-06T10:00:00Z', 'too_expensive', null, null))
        d(id, pipeline, stage, owner, market, channel, created, closed, reason, amount, currency)));
    for r in
      select s.deal, jsonb_agg(jsonb_strip_nulls(jsonb_build_object('pipelineId', s.pipeline, 'stageId', s.stage, 'enteredAt', s.entered, 'exitedAt', s.exited))) as st
      from (values
        ('dA', 'sales', 's1', '2026-10-05T08:00:00Z', '2026-10-06T08:00:00Z'), ('dA', 'sales', 's2', '2026-10-06T08:00:00Z', '2026-10-08T12:00:00Z'),
        ('dA', 'sales', 'sw', '2026-10-08T12:00:00Z', null),
        ('dB', 'sales', 's1', '2026-10-05T09:00:00Z', '2026-10-07T09:00:00Z'), ('dB', 'sales', 'sl', '2026-10-07T09:00:00Z', null),
        ('dC', 'sales', 's1', '2026-10-06T10:00:00Z', '2026-10-09T10:00:00Z'), ('dC', 'sales', 'sl', '2026-10-09T10:00:00Z', null),
        ('dD', 'sales', 's1', '2026-10-06T11:00:00Z', '2026-10-07T11:00:00Z'), ('dD', 'sales', 's2', '2026-10-07T11:00:00Z', '2026-10-10T11:00:00Z'),
        ('dD', 'sales', 'sl', '2026-10-10T11:00:00Z', null),
        ('dE', 'sales', 's1', '2026-10-07T08:00:00Z', '2026-10-08T08:00:00Z'), ('dE', 'sales', 's2', '2026-10-08T08:00:00Z', null),
        ('dF', 'sales', 's1', '2026-10-08T08:00:00Z', null),
        ('dG', 'sales', 's1', '2026-09-29T08:00:00Z', '2026-10-02T08:00:00Z'), ('dG', 'sales', 's2', '2026-10-02T08:00:00Z', '2026-10-06T08:00:00Z'),
        ('dG', 'sales', 'sw', '2026-10-06T08:00:00Z', null),
        ('dH', 'sales', 's1', '2026-09-30T09:00:00Z', '2026-10-01T09:00:00Z'), ('dH', 'sales', 'sl', '2026-10-01T09:00:00Z', null),
        ('dJ', 'sales', 's1', '2026-10-09T10:00:00Z', '2026-10-10T10:00:00Z'), ('dJ', 'sales', 'sw', '2026-10-10T10:00:00Z', null),
        ('dT', 'sales2', 'q1', '2026-10-06T09:00:00Z', null),
        ('dU', 'sales', 's1', '2026-10-11T07:00:00Z', null), ('dV', 'sales', 's1', '2026-10-11T12:00:00Z', null),
        ('dY', 'test', 'x1', '2026-10-07T10:00:00Z', null)) s(deal, pipeline, stage, entered, exited)
      group by s.deal
    loop
      perform cma.ingest_record_stages(v_crm, 'deal', r.deal, jsonb_build_object('updatedAt', '2026-10-12T00:00:00Z', 'stages', r.st));
    end loop;
    perform cma.ingest_upsert_records(v_crm, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'recordType', 'ticket', 'sourceId', t.id, 'pipelineId', t.pipeline, 'stageId', t.stage, 'market', t.market, 'category', t.category,
               'contactId', 'k' || t.id, 'createdAt', t.created, 'closedAt', t.closed, 'reason', t.reason, 'updatedAt', '2026-10-12T00:00:00Z')))
      from (values
        ('tA', 'cancel', 'c4', null, null, '2026-10-05T08:00:00Z', '2026-10-07T08:00:00Z', 'price'),
        ('tB', 'cancel', 'c1', 'GB', null, '2026-10-06T09:00:00Z', null, 'moving'),
        ('tC', 'support', 't4', null, 'Cancellation', '2026-10-08T10:00:00Z', '2026-10-08T22:00:00Z', null),
        ('tD', 'support', 't1', 'NL', 'Complaint', '2026-10-08T11:00:00Z', null, null),
        ('tE', 'spam', 'p1', 'NL', 'Cancellation', '2026-10-08T12:00:00Z', null, null),
        ('tF', 'cancel', 'c1', 'NL', null, '2026-10-01T08:00:00Z', null, null),
        ('tG', 'cancel', 'c1', 'NL', null, '2026-10-12T08:00:00Z', null, null),
        ('tH', 'cancel', 'c1', null, null, '2026-10-09T09:00:00Z', null, null),
        ('tI', 'cancel', 'c1', 'NL', null, '2026-10-07T08:00:00Z', null, null)) t(id, pipeline, stage, market, category, created, closed, reason)));
    perform cma.ingest_upsert_records(v_crm, '[{"recordType": "ticket", "sourceId": "tI", "deletedAt": "2026-10-07T09:00:00Z"}]');
    -- the tickets' contacts, held now that the tickets point to them (0006)
    perform cma.ingest_upsert_contacts(v_crm, '[{"sourceId": "ktA", "country": "NL", "updatedAt": "2026-10-01T00:00:00Z"},
      {"sourceId": "ktC", "country": "NL", "updatedAt": "2026-10-01T00:00:00Z"}, {"sourceId": "ktH", "updatedAt": "2026-10-01T00:00:00Z"}]');

    -- tenant two: a lost deal of the same source id, its reason field unmapped
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_pipelines(v_crm2, '[{"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
      {"stageId": "s1", "label": "New", "order": 1, "isClosed": false}, {"stageId": "sl", "label": "Lost", "order": 9, "isClosed": true, "outcome": "lost"}]}]');
    perform cma.ingest_upsert_records(v_crm2, '[{"recordType": "deal", "sourceId": "dA", "pipelineId": "sales", "stageId": "sl", "reason": "too_expensive",
      "createdAt": "2026-10-05T08:00:00Z", "closedAt": "2026-10-06T08:00:00Z", "updatedAt": "2026-10-06T08:00:00Z"}]');
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);

    -- B8. the funnel per pipeline and in total, with the previous period (a period that ended: the whole previous span)
    j := cma.deal_funnel_page_of(v_t1, date '2026-10-05', date '2026-10-11', null, null, null, v_now);
    select string_agg(format('%s:%s|%s', x ->> 'label', pg_temp.v0008zb_fig(x -> 'current'), pg_temp.v0008zb_fig(x -> 'previous')), ' '
                      order by x ->> 'label') into v_txt
    from jsonb_array_elements(j -> 'by_pipeline' -> 'rows') x;
    v_txt := v_txt || format(' total:%s|%s %s..%s %s', pg_temp.v0008zb_fig(j -> 'by_pipeline' -> 'total' -> 'current'),
                             pg_temp.v0008zb_fig(j -> 'by_pipeline' -> 'total' -> 'previous'), j ->> 'previous_from', j ->> 'previous_to', j ->> 'previous_partial');
    v_rows := v_rows || array['18', 'B8 per pipeline: created, won, lost, the win rate by close date, the median days to won and to lost, the previous period',
      case when v_txt = 'Sales:16/3/10/0.2308/3.2/2.0|2/0/1/0.0000/-/1.0 Sales two:1/0/0/-/-/-|0/0/0/-/-/- total:17/3/10/0.2308/3.2/2.0|2/0/1/0.0000/-/1.0 2026-09-28..2026-10-04 false'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. per stage: entered, still there, moved on, timed, the median days, reached won and its share, entered in the
    --     previous period; a stage that reads no times without figures; the history starts and timed stages. The median
    --     only: no stage carries an 80th percentile or any other key (Decision log, 15 October 2026)
    select string_agg(format('%s:%s/%s/%s/%s/%s/%s/%s/%s', x ->> 'stage_id', coalesce(x ->> 'entered', '-'), coalesce(x ->> 'still_there', '-'),
                             coalesce(x ->> 'moved_on', '-'), coalesce(x ->> 'timed', '-'), coalesce(x ->> 'median_days', '-'),
                             coalesce(x ->> 'reached_won', '-'), coalesce(x ->> 'won_share', '-'), coalesce(x ->> 'entered_previous', '-')), ' ' order by o.n) into v_txt
    from jsonb_array_elements(j -> 'stages') with ordinality o(x, n);
    v_txt := v_txt || format(' %s/%s %s keys:%s', j -> 'history_start' ->> 'deals', j -> 'history_start' ->> 'stages', j ->> 'timed_stages',
                             (select string_agg(distinct sk, ',' order by sk) from jsonb_array_elements(j -> 'stages') x, jsonb_object_keys(x) sk
                               where sk not in ('pipeline', 'pipeline_label', 'stage_id', 'label', 'order', 'is_closed', 'outcome', 'reads_times', 'entered',
                                               'still_there', 'moved_on', 'timed', 'median_days', 'reached_won', 'won_share', 'entered_previous')));
    v_rows := v_rows || array['19', 'B9 per stage: entered, still there, moved on, the median days in stage, reached won, the previous period; a stage off without figures; no 80th percentile',
      case when v_txt = 's1:9/3/6/6/1.0/2/0.2222/2 s2:3/1/2/2/2.6/1/0.3333/1 sw:3/3/0/0/-/3/1.0000/0 sl:-/-/-/-/-/-/-/- '
                        || 'q1:1/1/0/0/-/0/0.0000/0 qw:0/0/0/0/-/0/-/0 2026-09-29/2026-09-29 6 keys:'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. the filters: a market (GB), a source channel (DIRECT), a pipeline (Sales two); the filter lists without them
    k := cma.deal_funnel_page_of(v_t1, date '2026-10-05', date '2026-10-11', null, 'GB', null, v_now);
    v_a := pg_temp.v0008zb_fig(k -> 'by_pipeline' -> 'total' -> 'current') || ' '
           || (select format('%s/%s/%s/%s/%s', x ->> 'entered', x ->> 'still_there', x ->> 'moved_on', x ->> 'median_days', x ->> 'won_share')
               from jsonb_array_elements(k -> 'stages') x where x ->> 'stage_id' = 's1');
    k := cma.deal_funnel_page_of(v_t1, date '2026-10-05', date '2026-10-11', null, null, 'DIRECT', v_now);
    v_a := v_a || ' ' || pg_temp.v0008zb_fig(k -> 'by_pipeline' -> 'total' -> 'current');
    k := cma.deal_funnel_page_of(v_t1, date '2026-10-05', date '2026-10-11', v_crm::text || ':sales2', null, null, v_now);
    v_a := v_a || ' ' || (select string_agg(x ->> 'label', ',') from jsonb_array_elements(k -> 'by_pipeline' -> 'rows') x)
           || ' ' || (select string_agg(x ->> 'stage_id', ',') from jsonb_array_elements(k -> 'stages') x)
           || ' ' || (k ->> 'markets') || ' ' || (select string_agg(x ->> 'label', ',') from jsonb_array_elements(k -> 'pipelines') x)
           || ' ' || (k ->> 'source_channels');
    v_txt := v_a;
    v_rows := v_rows || array['20', 'B10 the filters (market, source channel, pipeline) narrow every figure; the filter lists without them',
      case when v_txt = '4/1/3/0.2500/1.0/2.1 2/0/2/1.5/0.5000 2/0/2/0.0000/-/3.5 Sales two q1,qw ["GB", "NL"] Sales,Sales two ["DIRECT", "PAID_SEARCH"]'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. like for like: a period that reaches today against the same elapsed dates, the last cut at the time of day
    k := cma.deal_funnel_page_of(v_t1, date '2026-10-12', date '2026-10-14', null, null, null, v_now);
    v_txt := format('%s|%s %s..%s %s s1prev:%s', pg_temp.v0008zb_fig(k -> 'by_pipeline' -> 'total' -> 'current'),
                    pg_temp.v0008zb_fig(k -> 'by_pipeline' -> 'total' -> 'previous'), k ->> 'previous_from', k ->> 'previous_to', k ->> 'previous_partial',
                    (select x ->> 'entered_previous' from jsonb_array_elements(k -> 'stages') x where x ->> 'stage_id' = 's1'));
    v_rows := v_rows || array['21', 'B11 like for like: the previous span''s last date cut at the time of day',
      case when v_txt = '0/0/0/-/-/-|4/1/8/0.1111/1.0/2.5 2026-10-09..2026-10-11 true s1prev:2' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B12. lost reasons: the figures and the previous period; the real reasons with their share of the real lost deals; the
    --      data-quality reasons apart; no reason as its own row; the state of the field
    j := cma.lost_reasons_page_of(v_t1, date '2026-10-05', date '2026-10-11', null, null, null, 'week', 100, v_now);
    v_txt := format('%s/%s/%s/%s/%s|%s/%s/%s/%s/%s', j -> 'current' ->> 'lost', j -> 'current' ->> 'with_reason', j -> 'current' ->> 'no_reason',
                    j -> 'current' ->> 'data_quality', j -> 'current' ->> 'real', j -> 'previous' ->> 'lost', j -> 'previous' ->> 'with_reason',
                    j -> 'previous' ->> 'no_reason', j -> 'previous' ->> 'data_quality', j -> 'previous' ->> 'real')
      || ' ' || (select string_agg(format('%s=%s/%s', x ->> 'label', x ->> 'deals', x ->> 'share'), ',' order by o.n)
                 from jsonb_array_elements(j -> 'reasons') with ordinality o(x, n))
      || ' dq:' || (select string_agg(format('%s=%s/%s', x ->> 'label', x ->> 'deals', x ->> 'share'), ',' order by o.n)
                    from jsonb_array_elements(j -> 'data_quality_reasons') with ordinality o(x, n))
      || ' none:' || (j -> 'no_reason' ->> 'deals') || '/' || (j -> 'no_reason' ->> 'share') || ' ' || (j ->> 'reason_state') || ' ' || (j ->> 'history_start');
    v_rows := v_rows || array['22', 'B12 lost reasons: the real reasons and their share, the data-quality block, no reason, the previous period',
      case when v_txt = '10/9/1/2/7|1/1/0/0/1 Too expensive=3/0.4286,Bad Timing=2/0.2857,Bad Fit=1/0.1429,Ordered Elsewhere=1/0.1429 '
                        || 'dq:Duplicate=1/0.1000,Garbage=1/0.1000 none:1/0.1000 enumeration 2026-09-29'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B13. per market with the top 3 real reasons, per source channel (none last)
    select string_agg(format('%s:%s/%s/%s/%s[%s]', x ->> 'market', x ->> 'lost', x ->> 'real', x ->> 'no_reason', x ->> 'data_quality',
                             (select string_agg(format('%s=%s', t ->> 'label', t ->> 'deals'), ',' order by p.n)
                              from jsonb_array_elements(x -> 'top') with ordinality p(t, n))), ' ' order by o.n) into v_a
    from jsonb_array_elements(j -> 'by_market') with ordinality o(x, n);
    select string_agg(format('%s:%s/%s/%s/%s[%s]', coalesce(x ->> 'source_channel', 'none'), x ->> 'lost', x ->> 'real', x ->> 'no_reason', x ->> 'data_quality',
                             (select string_agg(format('%s=%s', t ->> 'label', t ->> 'deals'), ',' order by p.n)
                              from jsonb_array_elements(x -> 'top') with ordinality p(t, n))), ' ' order by o.n) into v_b
    from jsonb_array_elements(j -> 'by_source') with ordinality o(x, n);
    v_txt := v_a || ' | ' || v_b;
    v_rows := v_rows || array['23', 'B13 per market with the top 3 real reasons, per source channel',
      case when v_txt = 'GB:3/2/0/1[Bad Timing=1,Too expensive=1] NL:7/5/1/1[Too expensive=2,Bad Fit=1,Bad Timing=1] | '
                        || 'DIRECT:2/0/1/1[] PAID_SEARCH:7/6/0/1[Too expensive=3,Bad Fit=1,Bad Timing=1] none:1/1/0/0[Bad Timing=1]'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B14. per ISO week and per day; the lost deals without a reason as a list with the link; a market filter
    select string_agg(format('%s:%s/%s/%s/%s%s', x ->> 'key', x ->> 'lost', x ->> 'real', x ->> 'no_reason', x ->> 'data_quality', x -> 'reasons'), ' ') into v_a
    from jsonb_array_elements(j -> 'by_period') x;
    k := cma.lost_reasons_page_of(v_t1, date '2026-10-05', date '2026-10-11', null, null, null, 'day', 100, v_now);
    select string_agg(format('%s:%s/%s/%s/%s', to_char((x ->> 'key')::date, 'MM-DD'), x ->> 'lost', x ->> 'real', x ->> 'no_reason', x ->> 'data_quality'), ' ' order by o.n) into v_b
    from jsonb_array_elements(k -> 'by_period') with ordinality o(x, n);
    v_c := (j -> 'list' ->> 'total') || ' ' || (select string_agg(format('%s %s', x ->> 'deal_source_id', x ->> 'record_url'), ',') from jsonb_array_elements(j -> 'list' -> 'rows') x);
    k := cma.lost_reasons_page_of(v_t1, date '2026-10-05', date '2026-10-11', null, 'GB', null, 'week', 100, v_now);
    v_c := v_c || ' GB:' || (k -> 'current' ->> 'lost') || ' ' || (select string_agg(format('%s=%s', x ->> 'label', x ->> 'share'), ',' order by o.n)
                                                              from jsonb_array_elements(k -> 'reasons') with ordinality o(x, n));
    v_txt := v_a || ' | ' || v_b || ' | ' || v_c;
    v_rows := v_rows || array['24', 'B14 lost per ISO week and per day; the list without a reason with its link; the market filter',
      case when v_txt = '2026-10-05:10/7/1/2{"bad_fit": 1, "bad_timing": 2, "too_expensive": 3, "ordered_elsewhere": 1} | '
                        || '10-07:1/1/0/0 10-08:1/1/0/0 10-09:3/2/0/1 10-10:3/1/1/1 10-11:2/2/0/0 | '
                        || '1 dD https://crm.example.invalid/portal-1/deal/dD GB:3 Bad Timing=0.5000,Too expensive=0.5000'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B15. cancellations: the requests of the kind (by pipeline and by category; an uncounted pipeline, a deleted ticket,
    --      another kind, the previous span and a later date out), open, closed, the median days to close, per market and week,
    --      the reasons (mapped), the newest requests with their links, the history start
    j := cma.cancellations_page_of(v_t1, date '2026-10-05', date '2026-10-11', null, 'week', 3, v_now);
    v_txt := format('%s:%s %s/%s/%s/%s|%s/%s/%s/%s', j -> 'kind' ->> 'key', j -> 'kind' ->> 'label',
                    j -> 'current' ->> 'requests', j -> 'current' ->> 'open', j -> 'current' ->> 'closed', coalesce(j -> 'current' ->> 'median_days_to_close', '-'),
                    j -> 'previous' ->> 'requests', j -> 'previous' ->> 'open', j -> 'previous' ->> 'closed', coalesce(j -> 'previous' ->> 'median_days_to_close', '-'))
      || ' ' || (select string_agg(format('%s:%s/%s/%s/%s', x ->> 'market', x ->> 'requests', x ->> 'open', x ->> 'closed', coalesce(x ->> 'median_days_to_close', '-')),
                                   ' ' order by o.n) from jsonb_array_elements(j -> 'by_market') with ordinality o(x, n))
      || ' ' || (select string_agg(format('%s/%s=%s', x ->> 'key', x ->> 'market', x ->> 'requests'), ' ' order by o.n)
                 from jsonb_array_elements(j -> 'by_period') with ordinality o(x, n))
      || ' ' || (j ->> 'reason_state') || ' ' || (select string_agg(format('%s=%s', coalesce(x ->> 'label', '-'), x ->> 'requests'), ' ' order by o.n)
                                                  from jsonb_array_elements(j -> 'reasons') with ordinality o(x, n))
      || ' ' || (j -> 'list' ->> 'total') || ':' || (select string_agg(x ->> 'source_id', ',' order by o.n) from jsonb_array_elements(j -> 'list' -> 'rows') with ordinality o(x, n))
      || ' ' || (select x ->> 'record_url' from jsonb_array_elements(j -> 'list' -> 'rows') x limit 1)
      || ' ' || (j ->> 'markets') || ' ' || (j ->> 'history_start');
    v_rows := v_rows || array['25', 'B15 cancellations: the kind''s requests, open, closed, days to close, per market and week, reasons, the list, the history start',
      case when v_txt = 'cancellation:Cancellation request 4/2/2/1.3|1/1/0/- GB:1/1/0/- NL:2/0/2/1.3 unknown:1/1/0/- 2026-10-05/GB=1 2026-10-05/NL=2 2026-10-05/unknown=1 '
                        || 'enumeration Moving=1 Price=1 -=2 4:tH,tC,tB https://crm.example.invalid/portal-1/ticket/tH ["GB", "NL", "unknown"] 2026-10-01'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B16. cancellations with a market filter and by day; no kind set (none counted, the page says so); the kind archived
    k := cma.cancellations_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'NL', 'day', 100, v_now);
    v_txt := format('%s/%s', k -> 'current' ->> 'requests', (select string_agg(to_char((x ->> 'key')::date, 'MM-DD') || '=' || (x ->> 'requests'), ',' order by o.n)
                                                             from jsonb_array_elements(k -> 'by_period') with ordinality o(x, n)));
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('reports.cancellation_kind', '');
    k := cma.cancellations_page_of(v_t1, date '2026-10-05', date '2026-10-11', null, 'week', 100, v_now);
    v_txt := v_txt || format(' %s/%s/%s', coalesce(k ->> 'kind', 'none'), k -> 'current' ->> 'requests', k ->> 'reason_state');
    perform cma.set_tenant_setting('reports.cancellation_kind', 'cancellation');
    perform cma.set_record_kind_status('cancellation', 'archived');
    k := cma.cancellations_page_of(v_t1, date '2026-10-05', date '2026-10-11', null, 'week', 100, v_now);
    v_txt := v_txt || format(' %s/%s', k -> 'kind' ->> 'status', k -> 'current' ->> 'requests');
    perform cma.set_record_kind_status('cancellation', 'active');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['26', 'B16 cancellations by market and day; no kind set; the kind archived',
      case when v_txt = '2/10-05=1,10-08=1 none/0/none archived/0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B17. per person: won, lost and the amount won per currency (the deal's currency, else its market's), never summed across
    --      currencies, by name, never ranked; the owners without a person as one row; the total
    j := cma.deals_per_person_of(v_t1, date '2026-10-05', date '2026-10-11', null, null, null, v_now);
    select string_agg(format('%s:%s/%s[%s]', x ->> 'display_name', x ->> 'won', x ->> 'lost',
                             (select string_agg(format('%s %s (%s)', a ->> 'currency', a ->> 'amount', a ->> 'deals'), ',' order by p.n)
                              from jsonb_array_elements(x -> 'amounts') with ordinality p(a, n))), ' ' order by o.n) into v_txt
    from jsonb_array_elements(j -> 'rows') with ordinality o(x, n);
    v_txt := v_txt || format(' not_linked(%s):%s/%s total:%s/%s[%s]', j -> 'not_linked' ->> 'unlinked_owners', j -> 'not_linked' ->> 'won', j -> 'not_linked' ->> 'lost',
                             j -> 'total' ->> 'won', j -> 'total' ->> 'lost',
                             (select string_agg(format('%s %s (%s)', a ->> 'currency', a ->> 'amount', a ->> 'deals'), ',' order by p.n)
                              from jsonb_array_elements(j -> 'total' -> 'amounts') with ordinality p(a, n)));
    v_rows := v_rows || array['27', 'B17 per person: won, lost, amounts per currency never summed; the not-linked owners; the total',
      case when v_txt = 'Anna Verify:3/4[EUR 300.00 (2),GBP 80.00 (1)] Bram Verify:0/5[] not_linked(1):0/1 total:3/10[EUR 300.00 (2),GBP 80.00 (1)]'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B18. per person's gate: for performance.team while reports.per_person holds deals; refused (CMA06) for reports.view alone and
    --      once the setting drops deals, which hides the figures
    perform set_config('app.user_id', v_super1::text, true);
    v_txt := pg_temp.v0008zb_code('select cma.deals_per_person_page(''2026-10-05'', ''2026-10-11'')');
    perform set_config('app.user_id', v_reader1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zb_code('select cma.deals_per_person_page(''2026-10-05'', ''2026-10-11'')');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('reports.per_person', 'email,orders,attempts');
    perform set_config('app.user_id', v_super1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zb_code('select cma.deals_per_person_page(''2026-10-05'', ''2026-10-11'')');
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zb_code('select cma.set_tenant_setting(''reports.per_person'', ''deals,attempts,orders,email'')')
      || ' ' || pg_temp.v0008zb_code('select cma.set_tenant_setting(''reports.per_person'', ''deals,deals'')');
    perform cma.set_tenant_setting('reports.per_person', 'deals');
    v_rows := v_rows || array['28', 'B18 per person for performance.team with deals in reports.per_person; off hides it',
      case when v_txt = 'ok CMA06 CMA06 ok CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B19. the parameters refused (92 days, the market, the pipeline, the source channel, the group); the pages for their
    --      permissions (an agent refused, no acting user, the reader with reports.view alone)
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := pg_temp.v0008zb_code('select cma.deal_funnel_page(''2026-10-01'', ''2027-01-31'')')
      || ' ' || pg_temp.v0008zb_code('select cma.deal_funnel_page(''2026-10-01'', ''2026-10-31'', null, ''gb'')')
      || ' ' || pg_temp.v0008zb_code('select cma.deal_funnel_page(''2026-10-01'', ''2026-10-31'', ''sales'')')
      || ' ' || pg_temp.v0008zb_code(format('select cma.deal_funnel_page(''2026-10-01'', ''2026-10-31'', null, null, %L)', repeat('a', 101)))
      || ' ' || pg_temp.v0008zb_code('select cma.lost_reasons_page(''2026-10-01'', ''2026-10-31'', null, null, null, ''month'')')
      || ' ' || pg_temp.v0008zb_code('select cma.lost_reasons_page(''2026-10-01'', ''2026-10-31'', null, null, null, null)')
      || ' ' || pg_temp.v0008zb_code('select cma.cancellations_page(''2026-10-01'', ''2026-10-31'', null, ''month'')')
      || ' ' || pg_temp.v0008zb_code('select cma.cancellations_page(''2026-10-01'', ''2026-10-31'', ''NLD'')');
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zb_code('select cma.deal_funnel_page(''2026-10-01'', ''2026-10-31'')')
      || ' ' || pg_temp.v0008zb_code('select cma.lost_reasons_page(''2026-10-01'', ''2026-10-31'')')
      || ' ' || pg_temp.v0008zb_code('select cma.cancellations_page(''2026-10-01'', ''2026-10-31'')')
      || ' ' || pg_temp.v0008zb_code('select cma.deals_per_person_page(''2026-10-01'', ''2026-10-31'')');
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || ' ' || pg_temp.v0008zb_code('select cma.deal_funnel_page(''2026-10-01'', ''2026-10-31'')');
    perform set_config('app.user_id', v_reader1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zb_code('select cma.deal_funnel_page(''2026-10-01'', ''2026-10-31'', null, ''NL'', ''PAID_SEARCH'')')
      || ' ' || pg_temp.v0008zb_code('select cma.lost_reasons_page(''2026-10-01'', ''2026-10-31'', null, null, null, ''day'')')
      || ' ' || pg_temp.v0008zb_code('select cma.cancellations_page(''2026-10-01'', ''2026-10-31'', ''unknown'', ''week'')');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['29', 'B19 the parameters refused; the pages for reports.view or performance.team only',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA06 CMA06 CMA06 CMA06 CMA01 ok ok ok' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B20. the reporting views equal the application's rows for a reader scoped to tenant one and show none of tenant two's
    select string_agg(concat_ws('|', d.deal_source_id, d.reason, d.market, rs.source_stage_id, rs.entered_at, rs.exited_at), ';'
                      order by d.deal_source_id, rs.source_stage_id) into v_a
    from cma.funnel_deals_of(v_t1, now()) d
    left join cma.crm_record_stage rs on rs.tenant_id = v_t1 and rs.connection_id = d.connection_id and rs.record_type = 'deal' and rs.source_id = d.deal_source_id;
    select string_agg(concat_ws('|', c.source_id, c.kind_key, c.market, c.reason, c.is_closed), ';' order by c.source_id) into v_b
    from cma.cancellation_records_of(v_t1, null, null) c;
    perform set_config('role', 'cma_readonly', true);
    select format('%s/%s/%s', count(*), count(distinct v.deal_id), (v_a = string_agg(concat_ws('|', v.deal_source_id, v.reason, v.market, v.stage_id, v.entered_at, v.exited_at), ';'
                                                                                     order by v.deal_source_id, v.stage_id))::text)
      into v_txt
    from cma_read.deal_funnel_rows v where v.tenant_id = v_t1;
    select v_txt || format(' %s/%s', count(*), (v_b = string_agg(concat_ws('|', v.source_id, v.kind_key, v.market, v.reason, v.is_closed), ';' order by v.source_id))::text)
      into v_txt
    from cma_read.cancellation_rows v where v.tenant_id = v_t1;
    v_txt := v_txt || ' ' || (select count(*) from cma_read.connection_reason v where v.tenant_id = v_t1)
      || '/' || (select count(*) from cma_read.record_kind v where v.tenant_id = v_t1)
      || '/' || (select count(*) from cma_read.connection_record_kind v where v.tenant_id = v_t1)
      || '/' || (select v.reason from cma_read.crm_record_detail v where v.tenant_id = v_t1 and v.source_id = 'dB');
    perform set_config('app.tenant_id', v_t2::text, true);
    v_txt := v_txt || ' ' || (select count(*) from cma_read.deal_funnel_rows v where v.tenant_id = v_t1)
      || '/' || (select count(*) from cma_read.cancellation_rows v where v.tenant_id = v_t1)
      || '/' || (select count(*) from cma_read.deal_funnel_rows v where v.tenant_id = v_t2);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['30', 'B20 the reporting views equal the application''s rows for a reader scoped to one tenant',
      case when v_txt = '30/19/true 6/true 9/2/3/too_expensive 0/0/1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B21. tenant isolation: tenant two's deal of the same source id (its reason not mapped, so none stored) counts in its own
    --      pages only; tenant one's pages read none of it
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    j := cma.lost_reasons_page_of(v_t2, date '2026-10-05', date '2026-10-11', null, null, null, 'week', 100, v_now);
    v_txt := format('%s/%s/%s %s', j -> 'current' ->> 'lost', j -> 'current' ->> 'no_reason', j ->> 'reason_state',
                    (select r2.reason from cma.crm_record r2 where r2.tenant_id = v_t2 and r2.source_id = 'dA') is null)
      || ' ' || pg_temp.v0008zb_fig(cma.deal_funnel_page_of(v_t2, date '2026-10-05', date '2026-10-11', null, null, null, v_now) -> 'by_pipeline' -> 'total' -> 'current')
      || ' ' || (select count(*) from cma.funnel_deals_of(v_t1, v_now));
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || (select count(*) from cma.funnel_deals_of(v_t1, v_now))
      || ' ' || (select count(*) from cma.funnel_deals_of(v_t1, v_now) x where x.deal_source_id = 'dA');
    v_rows := v_rows || array['31', 'B21 tenant isolation for the funnel, the reasons and the deals',
      case when v_txt = '1/1/none t 1/0/1/0.0000/-/1.0 0 19 1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B22. the funnel's deals are 0008z's sales deals, with the same outcome; the order pipeline, the uncounted one and a deal
    --      before the intake start out
    select format('%s/%s/%s', count(*), count(*) filter (where s.deal_id is null), count(*) filter (where f.outcome is distinct from s.outcome)) into v_txt
    from cma.funnel_deals_of(v_t1, v_now) f
    full join cma.sales_deals_of(v_t1, null, null, v_now) s on s.deal_id = f.deal_id;
    v_txt := v_txt || ' ' || (select string_agg(x.deal_source_id, ',' order by x.deal_source_id) from cma.funnel_deals_of(v_t1, v_now) x
                              where x.deal_source_id in ('dX', 'dY', 'dZ', 'dRef', 'dA'));
    v_rows := v_rows || array['32', 'B22 the funnel''s deals are 0008z''s sales deals with their outcome',
      case when v_txt = '19/0/0 dA' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B23. the audit names the person: the kinds, the rules and the data-quality flags (the admin), the reasons' refresh (the
    --      Ingest user)
    select format('%s/%s/%s/%s',
                  (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'record_kind' and a.action = 'insert' and a.actor_user_id = v_admin1),
                  (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'connection_record_kind' and a.action = 'insert' and a.actor_user_id = v_admin1),
                  (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'connection_reason' and a.action = 'update'
                     and a.actor_user_id = v_admin1 and (a.new_row ->> 'is_data_quality')::boolean),
                  (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'connection_reason' and a.action = 'insert' and a.actor_user_id = v_ing1))
      into v_txt;
    v_rows := v_rows || array['33', 'B23 the audit names the admin for the kinds, rules and flags and the Ingest user for the options',
      case when v_txt = '2/3/3/9' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zb (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zb values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- C. Speed at about twice prod's volume (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_max      numeric := current_setting('verify.max_ms')::numeric;
  v_rows     text[] := '{}';
  v_t uuid; v_admin uuid; v_crm uuid; v_shop uuid;
  v_q text; v_name text; v_ms numeric; v_slow text := ''; v_times text := ''; v_txt text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t := cma.create_tenant('verify-0008zb-volume', 'Verify 0008zb volume', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-volume-admin@example.invalid', 'volume admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'admin';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, settings)
    values (v_t, 'verifycrm', 'Verify volume CRM', 'portal-v',
            '{"record_url_deal": "https://crm.example.invalid/{account}/deal/{id}", "record_url_ticket": "https://crm.example.invalid/{account}/ticket/{id}"}')
    returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyshop', 'Verify volume shop', 'shop-v')
    returning id into v_shop;
    -- the configuration (the admin)
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.upsert_market('DE', 'Germany', 'Europe/Berlin', 'de', 'EUR');
    perform cma.set_tenant_setting('intake.start_date', '2026-08-01');
    perform cma.set_tenant_setting('reports.per_person', 'deals');
    perform cma.set_record_kind('cancellation', 'Cancellation request', 'ticket', 10);
    perform set_config('role', 'cma_owner', true);

    -- the catalogs and the data (as the owner, set-based)
    insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_order)
    values (v_t, v_crm, 'deal', 'sales-nl', 'Sales NL', false), (v_t, v_crm, 'deal', 'sales-gb', 'Sales GB', false),
           (v_t, v_crm, 'deal', 'selfserve', 'Self Serve', true), (v_t, v_crm, 'ticket', 'support', 'Support', false),
           (v_t, v_crm, 'ticket', 'cancel', 'Cancellations', false);
    insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, display_order, is_closed, outcome, outcome_source)
    select v_t, v_crm, 'deal', p, s.id, s.label, s.ord, s.closed, s.outcome, case when s.outcome is not null then 'source' end
    from unnest(array['sales-nl', 'sales-gb']) p
    cross join (values ('new', 'New', 1, false, null), ('contacted', 'Contacted', 2, false, null), ('quote', 'Quote', 3, false, null),
                       ('won', 'Won', 8, true, 'won'), ('lost', 'Lost', 9, true, 'lost')) s(id, label, ord, closed, outcome);
    -- stage ids are unique per pipeline in this fixture's key: the GB pipeline's carry a suffix
    update cma.connection_stage set source_stage_id = source_stage_id || '-gb' where tenant_id = v_t and source_pipeline_id = 'sales-gb';
    insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, display_order, is_closed, outcome, outcome_source)
    values (v_t, v_crm, 'deal', 'selfserve', 'o1', 'Won', 1, true, 'won', 'source'),
           (v_t, v_crm, 'ticket', 'support', 't1', 'New', 1, false, null, null), (v_t, v_crm, 'ticket', 'support', 't4', 'Closed', 4, true, null, null),
           (v_t, v_crm, 'ticket', 'cancel', 'c1', 'New', 1, false, null, null), (v_t, v_crm, 'ticket', 'cancel', 'c4', 'Closed', 4, true, null, null);
    insert into cma.connection_field (tenant_id, connection_id, entity, field, source_property, source_type, checked_at)
    values (v_t, v_crm, 'deal', 'reason', 'lost_dropdown', 'enumeration', now()), (v_t, v_crm, 'ticket', 'reason', 'cancel_reason', 'enumeration', now());
    insert into cma.connection_reason (tenant_id, connection_id, record_type, value, label, sort_order, is_data_quality)
    select v_t, v_crm, 'deal', 'r' || g, 'Reason ' || g, g, g in (7, 8) from generate_series(1, 8) g
    union all
    select v_t, v_crm, 'ticket', 'c' || g, 'Cancel reason ' || g, g, false from generate_series(1, 5) g;
    insert into cma.connection_record_kind (tenant_id, connection_id, kind_key, pipeline_id, category)
    values (v_t, v_crm, 'cancellation', 'cancel', null), (v_t, v_crm, 'cancellation', null, 'Cancellation');
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'reports.cancellation_kind', 'cancellation');
    insert into cma.app_user (tenant_id, email, display_name)
    select v_t, 'verify-volume-owner' || g || '@example.invalid', 'Owner ' || g from generate_series(0, 9) g;
    insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
    select v_t, u.id, 'verifycrm_owner', 'o-' || substring(u.email from 'owner([0-9]+)@')
    from cma.app_user u where u.tenant_id = v_t and u.email like 'verify-volume-owner%';
    insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country)
    select v_t, v_crm, 'verifycrm', 'k' || g, (array['NL', 'GB', 'DE'])[1 + g % 3] from generate_series(1, 6000) g;
    insert into cma.crm_contact_ref (tenant_id, contact_id, system, external_id)
    select v_t, c.id, 'verifyshop', 'cu' || substr(c.source_id, 2) from cma.crm_contact c
    where c.tenant_id = v_t and substr(c.source_id, 2)::integer % 3 = 0;
    insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, customer_source_id, source_created_at, currency, total_amount, order_kind)
    select v_t, v_shop, 'verifyshop', 'so' || g, 'cu' || (3 * (1 + g % 2000)), timestamptz '2026-08-01 08:00+00' + (g * interval '66 minutes'), 'EUR', 99, 'first'
    from generate_series(1, 2000) g;
    -- 4,000 sales deals over August to October: a quarter won, 45 % lost (a reason, none for every ninth), the rest open
    insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref, contact_source_id,
                                market, is_closed, closed_at, source_created_at, source_updated_at, amount, currency, source_channel, reason)
    select v_t, v_crm, 'verifycrm', 'deal', 'd' || g, p.pipeline, p.stage || p.sfx, 'o-' || (g % 20), 'k' || (1 + g % 6000),
           (array['NL', 'GB', 'DE'])[1 + g % 3], p.closed, case when p.closed then p.created + make_interval(hours => 6 + (g % 19) * 20) end,
           p.created, p.created + interval '30 days', case when p.stage = 'won' then 100 + g % 400 end,
           case when p.stage = 'won' then (array['EUR', 'GBP', 'EUR'])[1 + g % 3] end,
           (array['PAID_SEARCH', 'ORGANIC_SEARCH', 'DIRECT_TRAFFIC', 'REFERRALS', 'SOCIAL_MEDIA', 'OFFLINE'])[1 + g % 6],
           case when p.stage = 'lost' and g % 9 <> 0 then 'r' || (1 + g % 8) end
    from generate_series(1, 4000) g
    cross join lateral (select case when g % 2 = 0 then 'sales-nl' else 'sales-gb' end as pipeline,
                               case when g % 2 = 0 then '' else '-gb' end as sfx,
                               timestamptz '2026-08-01 07:00+00' + (g * interval '33 minutes') as created,
                               case when g % 20 < 5 then 'won' when g % 20 < 14 then 'lost' else (array['new', 'contacted', 'quote'])[1 + g % 3] end as stage,
                               g % 20 < 14 as closed) p;
    -- their stage times: New for every deal, Contacted and Quote for those that got there, Won or Lost at the close
    insert into cma.crm_record_stage (tenant_id, connection_id, record_type, source_id, source_pipeline_id, source_stage_id, entered_at, exited_at)
    select v_t, v_crm, 'deal', d.source_id, d.pipeline_id, s.stage || case when d.pipeline_id = 'sales-gb' then '-gb' else '' end, s.entered, s.exited
    from cma.crm_record d
    cross join lateral (values
      ('new', d.source_created_at, case when d.stage_id not in ('new', 'new-gb') then d.source_created_at + interval '4 hours' end, true),
      ('contacted', d.source_created_at + interval '4 hours', case when d.stage_id not in ('new', 'new-gb', 'contacted', 'contacted-gb')
                                                                    then d.source_created_at + interval '30 hours' end,
       d.stage_id not in ('new', 'new-gb')),
      ('quote', d.source_created_at + interval '30 hours', d.closed_at, d.is_closed and substr(d.source_id, 2)::integer % 2 = 0 or d.stage_id in ('quote', 'quote-gb')),
      (case when d.stage_id like 'won%' then 'won' else 'lost' end, d.closed_at, null, d.is_closed)) s(stage, entered, exited, keep)
    where d.tenant_id = v_t and d.record_type = 'deal' and s.keep;
    -- 3,500 won order deals on the same contacts
    insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, contact_source_id, market,
                                is_closed, closed_at, source_created_at, source_updated_at, amount, currency)
    select v_t, v_crm, 'verifycrm', 'deal', 'od' || g, 'selfserve', 'o1', 'k' || (1 + (g * 7) % 6000), (array['NL', 'GB', 'DE'])[1 + g % 3],
           true, timestamptz '2026-08-01 09:00+00' + (g * interval '37 minutes'), timestamptz '2026-08-01 09:00+00' + (g * interval '37 minutes'),
           timestamptz '2026-08-01 09:00+00' + (g * interval '37 minutes'), 120, 'EUR'
    from generate_series(1, 3500) g;
    -- 8,000 tickets: 6,000 in support (one in ten of the category Cancellation), 2,000 in the cancellation pipeline; 70 % closed
    insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, contact_source_id, market,
                                is_closed, closed_at, source_created_at, source_updated_at, category, reason)
    select v_t, v_crm, 'verifycrm', 'ticket', 't' || g, case when g <= 6000 then 'support' else 'cancel' end,
           case when g % 10 < 7 then (case when g <= 6000 then 't4' else 'c4' end) else (case when g <= 6000 then 't1' else 'c1' end) end,
           'k' || (1 + (g * 11) % 6000), case when g % 4 = 0 then null else (array['NL', 'GB', 'DE'])[1 + g % 3] end,
           g % 10 < 7, case when g % 10 < 7 then timestamptz '2026-08-01 08:00+00' + (g * interval '16 minutes') + make_interval(hours => 2 + g % 200) end,
           timestamptz '2026-08-01 08:00+00' + (g * interval '16 minutes'), timestamptz '2026-08-01 08:00+00' + (g * interval '16 minutes') + interval '20 days',
           case when g <= 6000 then (array['Cancellation', 'Subscription', 'Order Change', 'Complaint', 'Sales', 'Other', 'Payment & Billing', 'Deployment', 'Exchange', 'Incident'])[1 + g % 10] end,
           case when g > 6000 and g % 3 <> 0 then 'c' || (1 + g % 5) end
    from generate_series(1, 8000) g;
    analyze cma.crm_record;
    analyze cma.crm_record_stage;
    analyze cma.crm_contact;
    analyze cma.crm_contact_ref;
    analyze cma.commerce_order;

    -- C1. the fixture's volume
    select format('%s sales deals, %s order deals, %s stage times, %s tickets (%s cancellations), %s contacts, %s store orders',
                  count(*) filter (where r.record_type = 'deal' and r.pipeline_id like 'sales%'), count(*) filter (where r.pipeline_id = 'selfserve'),
                  (select count(*) from cma.crm_record_stage s where s.tenant_id = v_t), count(*) filter (where r.record_type = 'ticket'),
                  (select count(*) from cma.cancellation_records_of(v_t, null, null)),
                  (select count(*) from cma.crm_contact c where c.tenant_id = v_t), (select count(*) from cma.commerce_order o where o.tenant_id = v_t))
      into v_txt
    from cma.crm_record r where r.tenant_id = v_t;
    v_rows := v_rows || array['71', 'C1 the volume tenant: twice prod''s deals, with stage times, order deals, tickets and store orders',
      case when v_txt like '4000 sales deals, 3500 order deals, % stage times, 8000 tickets (2600 cancellations), 6000 contacts, 2000 store orders'
                and (select count(*) from cma.crm_record_stage s where s.tenant_id = v_t) > 12000 and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- C2. every page read of October as the application (row-level security on), the best of three, under verify.max_ms
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    foreach v_q in array array[
      'deal_funnel_page|select cma.deal_funnel_page(''2026-10-01'', ''2026-10-31'')',
      'deal_funnel_page NL|select cma.deal_funnel_page(''2026-10-01'', ''2026-10-31'', null, ''NL'')',
      'deal_funnel_page pipeline|' || format('select cma.deal_funnel_page(''2026-10-01'', ''2026-10-31'', %L)', v_crm::text || ':sales-nl'),
      'deal_funnel_page source|select cma.deal_funnel_page(''2026-10-01'', ''2026-10-31'', null, null, ''DIRECT_TRAFFIC'')',
      'lost_reasons_page week|select cma.lost_reasons_page(''2026-10-01'', ''2026-10-31'')',
      'lost_reasons_page day GB|select cma.lost_reasons_page(''2026-10-01'', ''2026-10-31'', null, ''GB'', null, ''day'')',
      'cancellations_page week|select cma.cancellations_page(''2026-10-01'', ''2026-10-31'')',
      'cancellations_page day NL|select cma.cancellations_page(''2026-10-01'', ''2026-10-31'', ''NL'', ''day'')',
      'deals_per_person_page|select cma.deals_per_person_page(''2026-10-01'', ''2026-10-31'')',
      'deal_funnel_page 92 days|select cma.deal_funnel_page(''2026-08-01'', ''2026-10-31'')'] loop
      v_name := split_part(v_q, '|', 1);
      v_ms := pg_temp.v0008zb_best_ms(split_part(v_q, '|', 2), 3);
      v_times := v_times || v_name || ' ' || v_ms || ' ms; ';
      if v_ms >= v_max then
        v_slow := v_slow || v_name || ' ' || v_ms || ' ms; ';
      end if;
    end loop;
    v_rows := v_rows || array['72', format('C2 every page read of a month as the application under %s ms (best of three)', v_max),
      case when v_slow = '' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(nullif('too slow: ' || v_slow, 'too slow: '), v_times)];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['79', 'C the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zb (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zb values (79, 'C the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zb
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008zb where result = 'PASS') = 33
                       and not exists (select 1 from verify_0008zb where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008zb where result = 'PASS'),
                                        (select count(*) from verify_0008zb where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008zb_code(text);
drop function if exists pg_temp.v0008zb_best_ms(text, integer);
drop function if exists pg_temp.v0008zb_fig(jsonb);
