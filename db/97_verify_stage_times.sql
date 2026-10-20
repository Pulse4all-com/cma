-- =============================================================================================
-- 97_verify_stage_times.sql: verifies addition 0008za, stage times
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure and privileges;
-- block B works on two throwaway tenants inside a subtransaction that is always rolled back. Universal otherwise:
-- nothing of the seed is used; adapters, pipelines, stages and deals are invented data values, and no row carries
-- customer data. Every check writes one row, PASS or FAIL, and the last result lists them with the verdict, because
-- Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after 96_stage_times.sql.
--   A  structure and privileges: the addition row after 0008z; the table's columns, key, the record's foreign key and
--      the entered index; row-level security with the tenant policy, the audit trigger, no delete for the application
--      and nothing for the readers on the table; every function the application's only and in the caller's rights;
--      the reader view's exact columns; read_times a nullable boolean without a default; cma_read.connection_stage
--      unchanged
--   B  behaviour. Tenant one holds a CRM connection with a counted deal pipeline (three stages, one with a hyphen in
--      its id), an uncounted deal pipeline and a counted ticket pipeline; tenant two a CRM connection with a deal of
--      the same source id. Checked: the read_times defaults (on for a counted pipeline's stages, off for an uncounted
--      one's, following a pipeline switched off), a person's choice kept by a pipelines read and put back to the
--      default, its refusals (an unknown stage, another tenant's connection, an analyst, the Ingest user); the write
--      inserting, the same answer again changing nothing (no audit row), a missing or empty time not a clear, a
--      newer entry replacing the time, the stale guard (older, missing and equal source times), an unknown record,
--      the malformed answers and the permission; the audit row naming the Ingest user; row-level security across
--      the two tenants; no delete for the application; the reader view equal to the table, scoped to one tenant
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

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the session, so every
-- block below stops at once and the verdict says REFUSED, also where the client carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 97 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008za;
create temp table verify_0008za (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008za_code(p_sql text)
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

-- A record's stage times as one line: stage:entered/exited (HH24:MI of UTC, - for none), in stage order
create or replace function pg_temp.v0008za_times(p_tenant uuid, p_source text)
returns text
language sql
as $$
  select coalesce(string_agg(format('%s:%s/%s', s.source_stage_id, coalesce(to_char(s.entered_at at time zone 'UTC', 'DD HH24:MI'), '-'),
                                    coalesce(to_char(s.exited_at at time zone 'UTC', 'DD HH24:MI'), '-')), ' ' order by s.source_stage_id), 'none')
  from cma.crm_record_stage s
  where s.tenant_id = p_tenant and s.source_id = p_source
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008z
  insert into verify_0008za values (1, 'A1 addition 0008za recorded, after 0008z',
    case when exists (select 1 from cma.schema_migration where version = '0008za')
              and exists (select 1 from cma.schema_migration where version = '0008z') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the table: its columns with types and nullability, the key on tenant, connection, record type, source id and
  --     stage, the record's foreign key, the entered index
  v_bad := '';
  if (select string_agg(column_name || ':' || udt_name || ':' || is_nullable, ',' order by ordinal_position)
      from information_schema.columns where table_schema = 'cma' and table_name = 'crm_record_stage')
     is distinct from 'tenant_id:uuid:NO,connection_id:uuid:NO,record_type:text:NO,source_id:text:NO,source_pipeline_id:text:NO,'
                      || 'source_stage_id:text:NO,entered_at:timestamptz:YES,exited_at:timestamptz:YES,synced_at:timestamptz:NO' then
    v_bad := v_bad || 'columns; ';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.crm_record_stage'::regclass and contype = 'p')
     is distinct from 'PRIMARY KEY (tenant_id, connection_id, record_type, source_id, source_stage_id)' then
    v_bad := v_bad || 'key; ';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.crm_record_stage'::regclass and contype = 'f'
                 and confrelid = 'cma.crm_record'::regclass
                 and pg_get_constraintdef(oid) like 'FOREIGN KEY (tenant_id, connection_id, record_type, source_id)%') then
    v_bad := v_bad || 'the record''s foreign key; ';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'cma' and tablename = 'crm_record_stage'
                 and indexdef like '%(tenant_id, entered_at)%') then
    v_bad := v_bad || 'the entered index; ';
  end if;
  insert into verify_0008za values (2, 'A2 the stage times table: columns, the key, the record''s foreign key, the entered index',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. tenant-aware as every table: row-level security with the tenant policy, the audit trigger; the application may
  --     read, add and change, never delete; the readers nothing on the table
  v_bad := '';
  if not (select relrowsecurity from pg_class where oid = 'cma.crm_record_stage'::regclass)
     or not exists (select 1 from pg_policy where polrelid = 'cma.crm_record_stage'::regclass and polname = 'tenant_app') then
    v_bad := v_bad || 'row-level security; ';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'cma.crm_record_stage'::regclass and tgname = 'audit' and not tgisinternal) then
    v_bad := v_bad || 'audit trigger; ';
  end if;
  if not has_table_privilege('cma_app', 'cma.crm_record_stage', 'select') or not has_table_privilege('cma_app', 'cma.crm_record_stage', 'insert')
     or not has_table_privilege('cma_app', 'cma.crm_record_stage', 'update') or has_table_privilege('cma_app', 'cma.crm_record_stage', 'delete')
     or has_table_privilege('cma_readonly', 'cma.crm_record_stage', 'select') then
    v_bad := v_bad || 'privileges; ';
  end if;
  insert into verify_0008za values (3, 'A3 row-level security, the audit trigger, no delete for the application, nothing for the readers',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. every function of the addition the application's only, in the caller's rights, none for PUBLIC or the readers
  v_bad := '';
  foreach v_fn in array array['cma.read_times_of(boolean,boolean)', 'cma.set_stage_read_times(uuid,text,text,text,boolean)',
                              'cma.connection_config(uuid)', 'cma.ingest_record_stages(uuid,text,text,jsonb)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  insert into verify_0008za values (4, 'A4 every function the application''s only and in the caller''s rights',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. read_times: a nullable boolean without a default; the reader view's exact columns; cma_read.connection_stage
  --     keeps 0008u's columns (85 pins them)
  v_bad := '';
  if (select udt_name || ':' || is_nullable || ':' || coalesce(column_default, 'none') from information_schema.columns
      where table_schema = 'cma' and table_name = 'connection_stage' and column_name = 'read_times') is distinct from 'bool:YES:none' then
    v_bad := v_bad || 'read_times column; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'crm_record_stage')
     is distinct from 'tenant_id,connection_id,record_type,source_id,source_pipeline_id,source_stage_id,entered_at,exited_at,synced_at'
     or not has_table_privilege('cma_readonly', 'cma_read.crm_record_stage', 'select') then
    v_bad := v_bad || 'cma_read.crm_record_stage; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'connection_stage')
     is distinct from 'tenant_id,connection_id,record_type,source_pipeline_id,source_stage_id,label,display_order,is_closed,status,'
                      || 'refreshed_at,outcome,outcome_source' then
    v_bad := v_bad || 'cma_read.connection_stage changed; ';
  end if;
  insert into verify_0008za values (5, 'A5 read_times nullable without a default; the reader view''s columns; cma_read.connection_stage as before',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_ing1 uuid; v_admin2 uuid; v_ing2 uuid;
  v_crm uuid; v_crm2 uuid;
  v_txt text; v_a text; v_b text;
  v_n bigint; v_m bigint;
  j jsonb;
  r record;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people and roles (as the owner)
    v_t1 := cma.create_tenant('verify-0008za-one', 'Verify 0008za one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008za-two', 'Verify 0008za two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifycrm', 'Verify stage times CRM', 'portal-1') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verifycrm', 'Verify stage times CRM two', 'portal-2') returning id into v_crm2;
    perform set_config('role', 'cma_app', true);

    -- the pipelines from the source (the Ingest user): sales counted, test switched off below, a ticket pipeline
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "New", "order": 1, "isClosed": false, "outcome": null},
         {"stageId": "quote-sent", "label": "Quote sent", "order": 2, "isClosed": false, "outcome": null},
         {"stageId": "sw", "label": "Won", "order": 8, "isClosed": true, "outcome": "won"}]},
      {"recordType": "deal", "pipelineId": "test", "label": "Test", "stages": [{"stageId": "x1", "label": "Open", "order": 1, "isClosed": false}]},
      {"recordType": "ticket", "pipelineId": "support", "label": "Support", "stages": [{"stageId": "1", "label": "New", "order": 1, "isClosed": false},
         {"stageId": "4", "label": "Closed", "order": 4, "isClosed": true}]}]');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_connection_pipeline(v_crm, 'deal', 'test', false, false, null);

    -- B1. the defaults: on for the stages of a counted pipeline (deals and tickets), off for an uncounted pipeline's, none
    --     a person's choice
    j := cma.connection_config(v_crm);
    select string_agg(format('%s/%s=%s%s', p ->> 'pipelineId', s ->> 'stageId', s ->> 'readTimes', case when (s ->> 'readTimesSet')::boolean then '*' else '' end),
                      ' ' order by p ->> 'recordType', p ->> 'pipelineId', (s ->> 'order')::int)
      into v_txt
    from jsonb_array_elements(j -> 'pipelines') p, jsonb_array_elements(p -> 'stages') s;
    v_rows := v_rows || array['11', 'B1 read_times defaults: on for a counted pipeline''s stages, off for an uncounted one''s',
      case when v_txt = 'sales/s1=true sales/quote-sent=true sales/sw=true test/x1=false support/1=true support/4=true' and not v_provoke
           then 'PASS' else 'FAIL' end, v_txt];

    -- B2. a person's choice: off for the won stage, on for the uncounted pipeline's stage; kept by a pipelines read; the
    --     default again with null, which follows the pipeline switched off
    perform cma.set_stage_read_times(v_crm, 'deal', 'sales', 'sw', false);
    perform cma.set_stage_read_times(v_crm, 'deal', 'test', 'x1', true);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "New", "order": 1, "isClosed": false, "outcome": null},
         {"stageId": "quote-sent", "label": "Quote sent", "order": 2, "isClosed": false, "outcome": null},
         {"stageId": "sw", "label": "Won", "order": 8, "isClosed": true, "outcome": "won"}]},
      {"recordType": "deal", "pipelineId": "test", "label": "Test", "stages": [{"stageId": "x1", "label": "Open", "order": 1, "isClosed": false}]}]');
    perform set_config('app.user_id', v_admin1::text, true);
    j := cma.connection_config(v_crm);
    select string_agg(format('%s=%s%s', s ->> 'stageId', s ->> 'readTimes', case when (s ->> 'readTimesSet')::boolean then '*' else '' end), ' '
                      order by p ->> 'pipelineId', (s ->> 'order')::int)
      into v_a
    from jsonb_array_elements(j -> 'pipelines') p, jsonb_array_elements(p -> 'stages') s where p ->> 'recordType' = 'deal';
    perform cma.set_stage_read_times(v_crm, 'deal', 'test', 'x1', null);
    perform cma.set_connection_pipeline(v_crm, 'deal', 'sales', false, false, null);
    j := cma.connection_config(v_crm);
    select string_agg(format('%s=%s%s', s ->> 'stageId', s ->> 'readTimes', case when (s ->> 'readTimesSet')::boolean then '*' else '' end), ' '
                      order by p ->> 'pipelineId', (s ->> 'order')::int)
      into v_b
    from jsonb_array_elements(j -> 'pipelines') p, jsonb_array_elements(p -> 'stages') s where p ->> 'recordType' = 'deal';
    perform cma.set_connection_pipeline(v_crm, 'deal', 'sales', true, false, null);
    v_txt := v_a || ' | ' || v_b;
    v_rows := v_rows || array['12', 'B2 a person''s choice kept by a pipelines read; null the default again, which follows the pipeline',
      case when v_txt = 's1=true quote-sent=true sw=false* x1=true* | s1=false quote-sent=false sw=false* x1=false' and not v_provoke
           then 'PASS' else 'FAIL' end, v_txt];

    -- B3. the refusals: an unknown stage, a stage of another record type's pipeline, another tenant's connection; an analyst
    --     and the Ingest user lack tenant.configure; the Ingest user can read the configuration
    v_txt := pg_temp.v0008za_code(format('select cma.set_stage_read_times(%L, ''deal'', ''sales'', ''nope'', true)', v_crm))
             || ' ' || pg_temp.v0008za_code(format('select cma.set_stage_read_times(%L, ''ticket'', ''sales'', ''s1'', true)', v_crm))
             || ' ' || pg_temp.v0008za_code(format('select cma.set_stage_read_times(%L, ''deal'', ''sales'', ''s1'', true)', v_crm2));
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008za_code(format('select cma.set_stage_read_times(%L, ''deal'', ''sales'', ''s1'', true)', v_crm));
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008za_code(format('select cma.set_stage_read_times(%L, ''deal'', ''sales'', ''s1'', true)', v_crm))
             || ' ' || pg_temp.v0008za_code(format('select cma.connection_config(%L)', v_crm));
    v_rows := v_rows || array['13', 'B3 read_times refused for an unknown stage, another record type, another tenant, an analyst, the Ingest user',
      case when v_txt = 'CMA02 CMA02 CMA02 CMA06 CMA06 ok' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- the deals (the Ingest user): d1 updated at 10:00 on 6 October
    perform cma.ingest_upsert_records(v_crm, '[
      {"recordType": "deal", "sourceId": "d1", "pipelineId": "sales", "stageId": "quote-sent", "createdAt": "2026-10-05T08:00:00Z", "updatedAt": "2026-10-06T10:00:00Z"},
      {"recordType": "deal", "sourceId": "d2", "pipelineId": "sales", "stageId": "s1", "createdAt": "2026-10-05T09:00:00Z", "updatedAt": "2026-10-05T09:00:00Z"}]');

    -- B4. the write: two stages of d1 inserted (one with a hyphen in its id); a stage the answer holds without a time
    --     writes nothing
    select x.outcome || '/' || x.stages into v_txt
    from cma.ingest_record_stages(v_crm, 'deal', 'd1', '{"updatedAt": "2026-10-06T10:00:00Z", "stages": [
      {"pipelineId": "sales", "stageId": "s1", "enteredAt": "2026-10-05T08:00:00Z", "exitedAt": "2026-10-06T09:00:00Z"},
      {"pipelineId": "sales", "stageId": "quote-sent", "enteredAt": "2026-10-06T09:00:00Z", "exitedAt": null},
      {"pipelineId": "sales", "stageId": "sw", "enteredAt": null}]}') x;
    v_txt := v_txt || ' ' || pg_temp.v0008za_times(v_t1, 'd1');
    v_rows := v_rows || array['14', 'B4 the write inserts the stages the answer gives a time; a stage without one writes nothing',
      case when v_txt = 'written/2 quote-sent:06 09:00/- s1:05 08:00/06 09:00' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. the same answer again: unchanged, and no audit row
    select count(*) into v_n from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'crm_record_stage';
    select x.outcome || '/' || x.stages into v_txt
    from cma.ingest_record_stages(v_crm, 'deal', 'd1', '{"updatedAt": "2026-10-06T10:00:00Z", "stages": [
      {"pipelineId": "sales", "stageId": "s1", "enteredAt": "2026-10-05T08:00:00Z", "exitedAt": "2026-10-06T09:00:00Z"},
      {"pipelineId": "sales", "stageId": "quote-sent", "enteredAt": "2026-10-06T09:00:00Z"}]}') x;
    select count(*) into v_m from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'crm_record_stage';
    v_txt := v_txt || ' audit+' || (v_m - v_n);
    v_rows := v_rows || array['15', 'B5 the same answer again changes nothing and writes no audit row',
      case when v_txt = 'unchanged/0 audit+0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. a missing or empty time is not a clear: s1 answered without its entry and with an empty exit, quote-sent with its
    --     exit only; then a newer entry replaces quote-sent's (the deal entered it again)
    perform cma.ingest_upsert_records(v_crm, '[{"recordType": "deal", "sourceId": "d1", "pipelineId": "sales", "stageId": "sw", "createdAt": "2026-10-05T08:00:00Z", "updatedAt": "2026-10-07T10:00:00Z"}]');
    select x.outcome || '/' || x.stages into v_a
    from cma.ingest_record_stages(v_crm, 'deal', 'd1', '{"updatedAt": "2026-10-07T10:00:00Z", "stages": [
      {"pipelineId": "sales", "stageId": "s1", "exitedAt": null},
      {"pipelineId": "sales", "stageId": "quote-sent", "exitedAt": "2026-10-07T09:30:00Z"}]}') x;
    v_a := v_a || ' ' || pg_temp.v0008za_times(v_t1, 'd1');
    perform cma.ingest_upsert_records(v_crm, '[{"recordType": "deal", "sourceId": "d1", "pipelineId": "sales", "stageId": "quote-sent", "createdAt": "2026-10-05T08:00:00Z", "updatedAt": "2026-10-08T10:00:00Z"}]');
    select x.outcome || '/' || x.stages into v_b
    from cma.ingest_record_stages(v_crm, 'deal', 'd1', '{"updatedAt": "2026-10-08T10:00:00Z", "stages": [
      {"pipelineId": "sales", "stageId": "quote-sent", "enteredAt": "2026-10-08T09:00:00Z"}]}') x;
    v_txt := v_a || ' | ' || v_b || ' ' || pg_temp.v0008za_times(v_t1, 'd1');
    v_rows := v_rows || array['16', 'B6 a missing or empty time leaves the stored one; a newer entry replaces it',
      case when v_txt = 'written/1 quote-sent:06 09:00/07 09:30 s1:05 08:00/06 09:00 | written/1 quote-sent:08 09:00/07 09:30 s1:05 08:00/06 09:00'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. the stale guard: an answer older than the record's stored source time, or without one while the record has one,
    --     writes nothing; one as new as it writes
    select string_agg(x.outcome || '/' || x.stages, ' ') into v_txt
    from (select * from cma.ingest_record_stages(v_crm, 'deal', 'd1', '{"updatedAt": "2026-10-07T10:00:00Z", "stages": [
            {"pipelineId": "sales", "stageId": "s1", "enteredAt": "2026-10-01T08:00:00Z"}]}')
          union all
          select * from cma.ingest_record_stages(v_crm, 'deal', 'd1', '{"stages": [
            {"pipelineId": "sales", "stageId": "s1", "enteredAt": "2026-10-01T08:00:00Z"}]}')
          union all
          select * from cma.ingest_record_stages(v_crm, 'deal', 'd2', '{"updatedAt": "2026-10-05T09:00:00Z", "stages": [
            {"pipelineId": "sales", "stageId": "s1", "enteredAt": "2026-10-05T09:00:00Z"}]}')) x;
    v_txt := v_txt || ' ' || pg_temp.v0008za_times(v_t1, 'd1') || ' ' || pg_temp.v0008za_times(v_t1, 'd2');
    v_rows := v_rows || array['17', 'B7 the stale guard: an older or missing source time writes nothing, an equal one writes',
      case when v_txt = 'stale/0 stale/0 written/1 quote-sent:08 09:00/07 09:30 s1:05 08:00/06 09:00 s1:05 09:00/-' and not v_provoke
           then 'PASS' else 'FAIL' end, v_txt];

    -- B8. an unknown record; the malformed answers (no stages array, a stage without its id, a time that is no time, the
    --     contact record type, more than 500 stages); a person without ingest.write
    select x.outcome || '/' || x.stages into v_txt
    from cma.ingest_record_stages(v_crm, 'deal', 'nope', '{"updatedAt": "2026-10-06T10:00:00Z", "stages": []}') x;
    v_txt := v_txt
      || ' ' || pg_temp.v0008za_code(format('select cma.ingest_record_stages(%L, ''deal'', ''d2'', ''{"stages": {}}'')', v_crm))
      || ' ' || pg_temp.v0008za_code(format('select cma.ingest_record_stages(%L, ''deal'', ''d2'', ''{"updatedAt": "2026-10-05T09:00:00Z", "stages": [{"pipelineId": "sales", "enteredAt": "2026-10-05T09:00:00Z"}]}'')', v_crm))
      || ' ' || pg_temp.v0008za_code(format('select cma.ingest_record_stages(%L, ''deal'', ''d2'', ''{"updatedAt": "2026-10-05T09:00:00Z", "stages": [{"pipelineId": "sales", "stageId": "s1", "enteredAt": "yesterday"}]}'')', v_crm))
      || ' ' || pg_temp.v0008za_code(format('select cma.ingest_record_stages(%L, ''contact'', ''d2'', ''{"stages": []}'')', v_crm))
      || ' ' || pg_temp.v0008za_code(format('select cma.ingest_record_stages(%L, ''deal'', ''d2'', %L)', v_crm,
                  jsonb_build_object('stages', (select jsonb_agg(jsonb_build_object('pipelineId', 'sales', 'stageId', 's' || g)) from generate_series(1, 501) g))));
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008za_code(format('select cma.ingest_record_stages(%L, ''deal'', ''d2'', ''{"stages": []}'')', v_crm));
    perform set_config('app.user_id', v_ing1::text, true);
    v_rows := v_rows || array['18', 'B8 an unknown record, the malformed answers, a person without ingest.write',
      case when v_txt = 'unknown/0 CMA04 CMA04 CMA04 CMA04 CMA04 CMA06' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. the audit names the Ingest user on every stage row written
    select format('%s/%s', count(*), count(*) filter (where a.actor_user_id = v_ing1)) into v_txt
    from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'crm_record_stage';
    v_rows := v_rows || array['19', 'B9 the audit rows of the stage times name the Ingest user',
      case when v_txt = '5/5' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. row-level security across two tenants: tenant two writes its own deal of the same source id; each tenant sees its
    --      own rows only; tenant two cannot write to tenant one's connection
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_pipelines(v_crm2, '[{"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [{"stageId": "s1", "label": "New", "order": 1, "isClosed": false}]}]');
    perform cma.ingest_upsert_records(v_crm2, '[{"recordType": "deal", "sourceId": "d1", "pipelineId": "sales", "stageId": "s1", "createdAt": "2026-10-05T08:00:00Z", "updatedAt": "2026-10-05T08:00:00Z"}]');
    perform cma.ingest_record_stages(v_crm2, 'deal', 'd1', '{"updatedAt": "2026-10-05T08:00:00Z", "stages": [{"pipelineId": "sales", "stageId": "s1", "enteredAt": "2026-10-05T08:00:00Z"}]}');
    select format('%s/%s %s', (select count(*) from cma.crm_record_stage), (select count(*) from cma.crm_record_stage where tenant_id = v_t1),
                  pg_temp.v0008za_code(format('select cma.ingest_record_stages(%L, ''deal'', ''d1'', ''{"updatedAt": "2026-10-09T10:00:00Z", "stages": []}'')', v_crm)))
      into v_txt;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || format(' %s/%s', (select count(*) from cma.crm_record_stage), (select count(*) from cma.crm_record_stage where tenant_id = v_t2));
    v_rows := v_rows || array['20', 'B10 row-level security: each tenant sees and writes its own stage times only',
      case when v_txt = '1/0 CMA02 3/0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. no delete for the application, and nothing deleted
    v_txt := pg_temp.v0008za_code('delete from cma.crm_record_stage') || ' ' || (select count(*) from cma.crm_record_stage);
    v_rows := v_rows || array['21', 'B11 no delete for the application',
      case when v_txt = '42501 3' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B12. the reader view equals the table for a reader scoped to tenant one, and shows none of tenant two's
    select string_agg(concat_ws('|', t.connection_id, t.record_type, t.source_id, t.source_pipeline_id, t.source_stage_id, t.entered_at,
                                t.exited_at, t.synced_at), ';' order by t.source_id, t.source_stage_id)
      into v_a
    from cma.crm_record_stage t where t.tenant_id = v_t1;
    perform set_config('role', 'cma_readonly', true);
    select string_agg(concat_ws('|', v.connection_id, v.record_type, v.source_id, v.source_pipeline_id, v.source_stage_id, v.entered_at,
                                v.exited_at, v.synced_at), ';' order by v.source_id, v.source_stage_id)
      into v_b
    from cma_read.crm_record_stage v where v.tenant_id = v_t1;
    select format('%s/%s/%s', count(*), count(*) filter (where v.tenant_id = v_t2), (v_a = v_b)::text)
      into v_txt
    from cma_read.crm_record_stage v where v.tenant_id in (v_t1, v_t2);
    perform set_config('app.tenant_id', v_t2::text, true);
    v_txt := v_txt || ' ' || (select count(*) from cma_read.crm_record_stage v where v.tenant_id = v_t1);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['22', 'B12 the reader view equals the table for a reader scoped to one tenant',
      case when v_txt = '3/0/true 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['49', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008za (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008za values (49, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008za
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008za where result = 'PASS') = 17
                       and not exists (select 1 from verify_0008za where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008za where result = 'PASS'),
                                        (select count(*) from verify_0008za where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008za_code(text);
drop function if exists pg_temp.v0008za_times(uuid, text);
