-- =============================================================================================
-- 195_verify_audit_bookkeeping.sql: verifies addition 0009w, prod's slowdown part 1 (pg_stat_statements, audit_log's
-- statistics, the bookkeeping no longer audited)
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Reads the catalog, and writes on one throwaway tenant in a
-- step that is always rolled back (no row of it remains, its audit rows included). Run as your own IAM login, after 194.
-- Output: role, table, trigger and setting names, counts and times only.
--
-- Checks
--   S1  the addition 0009w is recorded once, after 0009v
--   P1  pg_stat_statements is installed, cma_owner holds pg_read_all_stats and reads the view as cma_owner without an
--       error (the role tools/perf/prod-slowdown-diagnosis.sql switches to). FAIL until the Studio step as postgres has
--       run where the login may not create it
--   P2  info: pg_stat_statements.track (all once the Cloud SQL flag is set; top is the default, which leaves out the
--       statements inside the functions); never FAIL but under provoke
--   A1  audit_log's storage parameters: exactly autovacuum_analyze_scale_factor 0, autovacuum_analyze_threshold 40000,
--       autovacuum_vacuum_insert_scale_factor 0, autovacuum_vacuum_insert_threshold 40000
--   A2  audit_log analyzed (by hand or by autovacuum) since 0009w was recorded
--   T1  sync_cursor, sync_run and ingest_event: no trigger runs cma.audit_row()
--   T2  connection_form, connection_form_field and connection_stage: exactly two triggers run cma.audit_row(), both
--       enabled, row-level, after: audit on insert or delete without a condition, audit_change on update with a condition
--       naming the refresh's times
--   T3  every other table whose trigger audit ran on insert, update and delete at 0009v (the 92 below) still has it so,
--       enabled, without a condition
--   B1  on a throwaway tenant, rolled back: a write, an update and a delete of each bookkeeping table make no audit row; a
--       configuration cache's insert, a real change and a delete make one each, an update of its refresh's times alone none; a
--       business write (a market, a pipeline) one each
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id:
-- that check alone compares with a deliberate difference.
-- Collation: every ordering that feeds a compared text says collate "C".
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'B1'

drop table if exists pg_temp.verify_0009w;
create temporary table verify_0009w (ord integer, check_name text, result text, detail text);

create or replace function pg_temp.v0009w_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- The triggers that run cma.audit_row() on one table, as text: name:events:condition, in name order ("C")
create or replace function pg_temp.v0009w_triggers(p_table regclass)
returns text
language sql stable
as $$
  select coalesce(string_agg(t.tgname || ':'
           || concat_ws('+', case when t.tgtype & 4 <> 0 then 'insert' end, case when t.tgtype & 16 <> 0 then 'update' end,
                        case when t.tgtype & 8 <> 0 then 'delete' end)
           || case when t.tgtype & 1 = 0 then ':statement' else '' end
           || case when t.tgtype & 2 <> 0 then ':before' else '' end
           || case when t.tgenabled = 'D' then ':disabled' else '' end
           || case when t.tgqual is not null then ':when' else '' end, ',' order by t.tgname collate "C"), 'none')
  from pg_trigger t
  where t.tgrelid = p_table and not t.tgisinternal and t.tgfoid = 'cma.audit_row()'::regprocedure
$$;

-- ---------------------------------------------------------------------------------------------
-- S1, P1, P2, A1, A2
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_txt    text;
  v_ok     boolean;
  v_schema text;
  v_n      bigint;
  v_err    text;
begin
  -- S1
  select format('0009w %s time(s), after 0009v %s', count(*) filter (where m.version = '0009w'),
                coalesce((max(m.applied_at) filter (where m.version = '0009w') > max(m.applied_at) filter (where m.version = '0009v'))::text, 'no'))
    into v_txt
  from cma.schema_migration m where m.version in ('0009v', '0009w');
  insert into pg_temp.verify_0009w values (1, 'S1 the addition 0009w is recorded once, after 0009v',
    case when v_txt = '0009w 1 time(s), after 0009v true' and not pg_temp.v0009w_p('S1') then 'PASS' else 'FAIL' end, v_txt);

  -- P1
  select n.nspname into v_schema from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pg_stat_statements';
  if v_schema is not null then
    begin
      execute format('select count(*) from %I.pg_stat_statements', v_schema) into v_n;
    exception when others then v_err := sqlstate;
    end;
  end if;
  v_ok := v_schema is not null and v_err is null and pg_has_role('cma_owner', 'pg_read_all_stats', 'member');
  insert into pg_temp.verify_0009w values (10, 'P1 pg_stat_statements installed and readable by cma_owner with pg_read_all_stats',
    case when v_ok and not pg_temp.v0009w_p('P1') then 'PASS' else 'FAIL' end,
    format('extension %s; cma_owner holds pg_read_all_stats %s; read as cma_owner %s',
           coalesce('in schema ' || v_schema, 'not installed'), pg_has_role('cma_owner', 'pg_read_all_stats', 'member'),
           case when v_schema is null then 'not tried' when v_err is null then v_n || ' statement(s)' else 'refused (' || v_err || ')' end));

  -- P2
  v_txt := coalesce(current_setting('pg_stat_statements.track', true), 'not loaded');
  insert into pg_temp.verify_0009w values (11, 'P2 pg_stat_statements.track (all once the flag is set)',
    case when pg_temp.v0009w_p('P2') then 'FAIL' else 'info' end, v_txt);

  -- A1
  select coalesce(array_to_string(array(select o from unnest(c.reloptions) o order by o collate "C"), ', '), 'none') into v_txt
  from pg_class c where c.oid = 'cma.audit_log'::regclass;
  insert into pg_temp.verify_0009w values (20, 'A1 audit_log''s autovacuum: analyze and insert vacuum after 40,000 rows',
    case when v_txt = 'autovacuum_analyze_scale_factor=0, autovacuum_analyze_threshold=40000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_insert_threshold=40000'
              and not pg_temp.v0009w_p('A1') then 'PASS' else 'FAIL' end, v_txt);

  -- A2
  select greatest(s.last_analyze, s.last_autoanalyze) >= (select m.applied_at from cma.schema_migration m where m.version = '0009w'),
         format('last analyze %s, last autoanalyze %s, %s rows changed since', coalesce(to_char(s.last_analyze at time zone 'UTC', 'YYYY-MM-DD HH24:MI'), 'never'),
                coalesce(to_char(s.last_autoanalyze at time zone 'UTC', 'YYYY-MM-DD HH24:MI'), 'never'), s.n_mod_since_analyze)
    into v_ok, v_txt
  from pg_stat_all_tables s where s.relid = 'cma.audit_log'::regclass;
  insert into pg_temp.verify_0009w values (21, 'A2 audit_log analyzed since 0009w was recorded (UTC)',
    case when coalesce(v_ok, false) and not pg_temp.v0009w_p('A2') then 'PASS' else 'FAIL' end, v_txt);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- T1, T2, T3: the triggers
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_txt  text;
  v_bad  text;
  v_def  text;
  v_kept text[] := array[
    'absence_type', 'app_link', 'app_role', 'app_user', 'app_user_external_id', 'business_holiday', 'business_hours', 'call_link',
    'channel', 'commerce_customer', 'commerce_order', 'commerce_order_line', 'commerce_store', 'connection_call_outcome',
    'connection_email_rule', 'connection_field', 'connection_inbox', 'connection_inbox_account', 'connection_inbox_channel',
    'connection_pipeline', 'connection_reason', 'connection_record_kind', 'connection_task_status', 'connection_task_type',
    'coverage_target', 'crm_association', 'crm_call', 'crm_contact', 'crm_contact_ref', 'crm_record', 'crm_record_stage', 'crm_task',
    'device', 'device_component', 'device_component_kind', 'device_import_row', 'device_language_alias', 'device_model',
    'device_status', 'email_message', 'email_thread', 'email_thread_event', 'flash_snapshot', 'flash_snapshot_run',
    'flash_watch_finding', 'form_category', 'form_submission', 'import_batch', 'import_day', 'import_person_map', 'import_session',
    'integration_connection', 'invitation', 'journey', 'legacy_call_batch', 'legacy_call_outcome', 'maintenance_rule', 'market',
    'market_alias', 'message', 'message_delivery', 'message_rule', 'organisation', 'outbox_action', 'pledge_loan',
    'pledge_model_value', 'pledge_snapshot', 'record_kind', 'review', 'review_channel', 'role_permission', 'roster_entry',
    'roster_publication', 'roster_week', 'skill', 'skill_level', 'subscription', 'subscription_event', 'team', 'team_member',
    'telephony_call', 'telephony_call_tag', 'telephony_missed_reason', 'telephony_number', 'telephony_tag', 'tenant_setting',
    'time_event', 'user_role', 'user_skill', 'work_status', 'workday', 'writeback_field'];
  t text;
begin
  -- T1
  select string_agg(x.t || ' ' || pg_temp.v0009w_triggers(('cma.' || x.t)::regclass), '; ' order by x.t collate "C") into v_txt
  from unnest(array['sync_cursor', 'sync_run', 'ingest_event']) x(t);
  insert into pg_temp.verify_0009w values (30, 'T1 the bookkeeping (sync_cursor, sync_run, ingest_event): no audit trigger',
    case when v_txt = 'ingest_event none; sync_cursor none; sync_run none' and not pg_temp.v0009w_p('T1') then 'PASS' else 'FAIL' end, v_txt);

  -- T2: the triggers, and audit_change's condition names the refresh's times of each table
  select string_agg(x.t || ' ' || pg_temp.v0009w_triggers(('cma.' || x.t)::regclass), '; ' order by x.t collate "C") into v_txt
  from unnest(array['connection_form', 'connection_form_field', 'connection_stage']) x(t);
  v_bad := '';
  foreach t in array array['connection_form:refreshed_at,fields_refreshed_at,updated_at', 'connection_form_field:refreshed_at,updated_at',
                           'connection_stage:refreshed_at'] loop
    select pg_get_triggerdef(g.oid) into v_def from pg_trigger g
    where g.tgrelid = ('cma.' || split_part(t, ':', 1))::regclass and g.tgname = 'audit_change';
    if v_def is null or exists (select 1 from unnest(string_to_array(split_part(t, ':', 2), ',')) c(n) where position('''' || c.n || '''' in v_def) = 0) then
      v_bad := v_bad || ' ' || split_part(t, ':', 1) || '''s condition';
    end if;
  end loop;
  insert into pg_temp.verify_0009w values (31, 'T2 the configuration caches: audit on insert and delete, audit_change on a real update',
    case when v_txt = 'connection_form audit:insert+delete,audit_change:update:when; connection_form_field audit:insert+delete,audit_change:update:when; connection_stage audit:insert+delete,audit_change:update:when'
              and v_bad = '' and not pg_temp.v0009w_p('T2') then 'PASS' else 'FAIL' end, v_txt || coalesce(nullif(';' || v_bad, ';'), ''));

  -- T3
  select string_agg(x.t || ' ' || case when to_regclass('cma.' || x.t) is null then 'missing' else pg_temp.v0009w_triggers(('cma.' || x.t)::regclass) end,
                    '; ' order by x.t collate "C")
    into v_txt
  from unnest(v_kept) x(t)
  where to_regclass('cma.' || x.t) is null or pg_temp.v0009w_triggers(('cma.' || x.t)::regclass) <> 'audit:insert+update+delete';
  insert into pg_temp.verify_0009w values (32, 'T3 every other table audited at 0009v still is, on insert, update and delete',
    case when v_txt is null and not pg_temp.v0009w_p('T3') then 'PASS' else 'FAIL' end,
    coalesce('differing: ' || v_txt, cardinality(v_kept) || ' tables, each with audit on insert, update and delete'));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B1: the writes, on a throwaway tenant, rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_t    uuid;
  v_c    uuid;
  v_run  uuid;
  v_ev   uuid;
  v_txt  text;
  v_res  text;
  v_want text := 'sync_cursor 0, sync_run 0, ingest_event 0; connection_form 2, connection_form_field 3, connection_stage 2; market 1, connection_pipeline 1';
begin
  begin
    v_t := cma.create_tenant('verify-0009w', 'Verify 0009w', 'Europe/Amsterdam');
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifycrm', 'Verify CRM', 'portal-0009w', 'crm') returning id into v_c;
    -- the bookkeeping: a cursor set twice, a run started and finished, an event received, processed and removed
    insert into cma.sync_cursor (tenant_id, connection_id, stream, cursor) values (v_t, v_c, 'verify', '{"after": 1}');
    update cma.sync_cursor set cursor = '{"after": 2}' where tenant_id = v_t and connection_id = v_c;
    insert into cma.sync_run (tenant_id, connection_id, job, stream) values (v_t, v_c, 'reconcile', 'verify') returning id into v_run;
    update cma.sync_run set status = 'succeeded', finished_at = now() where tenant_id = v_t and id = v_run;
    insert into cma.ingest_event (tenant_id, connection_id, event_key, source_type, kind, object_type, object_id, occurred_at)
    values (v_t, v_c, 'verify:0009w:1', 'deal', 'created', 'deal', 'd-1', now()) returning id into v_ev;
    update cma.ingest_event set status = 'processed', processed_at = now() where tenant_id = v_t and id = v_ev;
    delete from cma.ingest_event where tenant_id = v_t and id = v_ev;
    -- the configuration caches: an insert, the refresh's times alone, a real change
    insert into cma.connection_form (tenant_id, connection_id, source_form_id, name, refreshed_at) values (v_t, v_c, 'f-1', 'Form 1', now());
    update cma.connection_form set refreshed_at = now() + interval '1 minute', fields_refreshed_at = now() + interval '1 minute'
    where tenant_id = v_t and connection_id = v_c;
    update cma.connection_form set market = 'NL' where tenant_id = v_t and connection_id = v_c;
    insert into cma.connection_form_field (tenant_id, connection_id, source_form_id, name, kind, options, refreshed_at)
    values (v_t, v_c, 'f-1', 'interest', 'dropdown', array['a', 'b'], now());
    update cma.connection_form_field set refreshed_at = now() + interval '1 minute' where tenant_id = v_t and connection_id = v_c;
    update cma.connection_form_field set options = array['a', 'b', 'c'] where tenant_id = v_t and connection_id = v_c;
    delete from cma.connection_form_field where tenant_id = v_t and connection_id = v_c;
    -- a business write: a market and a pipeline (a stage needs one)
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order)
    values (v_t, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 10);
    insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, refreshed_at)
    values (v_t, v_c, 'deal', 'p-1', 'Pipeline 1', now());
    insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, is_closed)
    values (v_t, v_c, 'deal', 'p-1', 's-1', 'Stage 1', false);
    update cma.connection_stage set refreshed_at = now() + interval '1 minute' where tenant_id = v_t and connection_id = v_c;
    update cma.connection_stage set outcome = 'won', outcome_source = 'person' where tenant_id = v_t and connection_id = v_c;
    select format('sync_cursor %s, sync_run %s, ingest_event %s; connection_form %s, connection_form_field %s, connection_stage %s; market %s, connection_pipeline %s',
                  count(*) filter (where a.table_name = 'sync_cursor'), count(*) filter (where a.table_name = 'sync_run'),
                  count(*) filter (where a.table_name = 'ingest_event'), count(*) filter (where a.table_name = 'connection_form'),
                  count(*) filter (where a.table_name = 'connection_form_field'), count(*) filter (where a.table_name = 'connection_stage'),
                  count(*) filter (where a.table_name = 'market'), count(*) filter (where a.table_name = 'connection_pipeline'))
      into v_txt
    from cma.audit_log a where a.tenant_id = v_t;
    -- the result leaves the step in a variable: the step's own rows, the temporary table's included, are rolled back
    v_res := case when v_txt = v_want || case when pg_temp.v0009w_p('B1') then ' (provoked)' else '' end then 'PASS' else 'FAIL' end;
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_res := 'FAIL';
      v_txt := 'the step stopped: ' || sqlstate || ' ' || sqlerrm;
  end;
  insert into pg_temp.verify_0009w values (40, 'B1 audit rows: none for the bookkeeping, one per real change of a cache, one per business write',
    coalesce(v_res, 'FAIL'), coalesce(v_txt, 'no result'));
  -- the step left nothing behind
  insert into pg_temp.verify_0009w values (41, 'B2 the throwaway tenant and its rows are gone',
    case when not exists (select 1 from cma.tenant where slug = 'verify-0009w') and not pg_temp.v0009w_p('B2') then 'PASS' else 'FAIL' end,
    (select count(*) from cma.tenant where slug = 'verify-0009w') || ' tenant(s) verify-0009w');
end
$$;

drop function if exists pg_temp.v0009w_triggers(regclass);
drop function if exists pg_temp.v0009w_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009w
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009w where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009w where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('195_verify_audit_bookkeeping: %s PASS, %s FAIL, %s info', (select count(*) from pg_temp.verify_0009w where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009w where result = 'FAIL'), (select count(*) from pg_temp.verify_0009w where result = 'info'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0009w;
reset role;
