-- =============================================================================================
-- 109_verify_legacy_call_outcome.sql: verifies addition 0008zg, legacy call outcomes
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure and privileges; block
-- B works on two throwaway tenants inside a subtransaction that is always rolled back. Universal otherwise: nothing of
-- the seed is used; connections, batches, rows, contacts, calls and people are invented data values, and no row carries
-- a name of a customer, an email, a phone number or a customer id (the hashes are made-up hex). Every check writes one
-- row, PASS or FAIL, and the last result lists them with the verdict, because Cloud SQL Studio shows no notices. Run as
-- your own IAM login in dev, after 108_legacy_call_outcome.sql; then 33, 35, 69, 71, 75, 105 and 107 again.
--   A  structure and privileges: the addition row after 0008zf; the two tables' columns; row-level security with the
--      tenant policy, the audit trigger, select, insert and update for the application and no delete, nothing for
--      the readers; the keys (one live batch per file, one row per batch and source row, the outcome's CRM connection
--      the batch's) and the checks (a contact exactly with email_phone, email, phone or customer_id; matched_at
--      exactly with a contact; the label without an @; the meaning's keys those of cma.telephony_tag.meaning); every
--      function the application's only and in the caller's rights, cma.ingest_contact_forget() carrying 0008n's
--      tasks and 0008zg's outcomes; the reporting views' exact columns, the outcomes of withdrawn batches left out;
--      the job name legacy_call_import next to the earlier ones
--   B  behaviour, on two throwaway tenants (Europe/Amsterdam). Tenant one holds a CRM connection, an inactive one, a
--      telephony connection with courtesy and other tags and a few calls, an admin, an agent and its Ingest user;
--      tenant two a CRM connection and its own Ingest user. Checked: a batch started, reused for the same file and
--      refused for another cutover, another kind of connection, an inactive one, a bad SHA-256 and an agent; the rows
--      of every match method stored; an idempotent rerun; a contact filled only where none is set, a set one kept, a
--      method changed between none and conflict, a changed fact refused; the refusals (cutover, a method the ingest may
--      not send, more than 500 rows, a bad date); the table's own checks; the finish with the per-method counts; the
--      reconciliation read (a courtesy tag on the date, a removed tag, another meaning, the tenant's day, a deleted
--      call); the privacy deletion (forgotten, kept on a rerun, withdrawn batches' rows too); the withdrawal (the
--      Ingest user and an agent refused, the admin once, audited, the rows left out of the reader view, no more rows
--      or finish, the same file again as a new batch); tenant isolation; the job's sync run; the audit
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 109 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008zg;
create temp table verify_0008zg (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zg_code(p_sql text)
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

-- One row as the import job hands it to cma.legacy_call_outcomes_upsert
create or replace function pg_temp.v0008zg_row(p_row integer, p_on text, p_meaning text, p_label text, p_contact text, p_method text)
returns jsonb
language sql
as $$
  select jsonb_build_object('sourceRow', p_row, 'occurredOn', p_on, 'meaning', p_meaning, 'sourceLabel', p_label,
                            'contactId', p_contact, 'matchMethod', p_method)
$$;

-- A batch's rows as text: source_row:method:contact (or -):whether matched_at is set
create or replace function pg_temp.v0008zg_rows(p_batch uuid)
returns text
language sql
as $$
  select coalesce(string_agg(o.source_row || ':' || o.match_method || ':' || coalesce(o.crm_contact_source_id, '-') || ':'
                             || (o.matched_at is not null)::text, ' ' order by o.source_row), 'none')
  from cma.legacy_call_outcome o where o.batch_id = p_batch
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_t       text;
  v_f       text;
  v_a       text;
  v_b       text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008zf
  insert into verify_0008zg values (1, 'A1 addition 0008zg recorded, after 0008zf',
    case when exists (select 1 from cma.schema_migration where version = '0008zg')
              and exists (select 1 from cma.schema_migration where version = '0008zf') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the tables: their columns in order with types and nullability
  v_bad := '';
  if (select string_agg(column_name || ':' || data_type || ':' || is_nullable, ', ' order by ordinal_position)
      from information_schema.columns where table_schema = 'cma' and table_name = 'legacy_call_batch')
     is distinct from 'id:uuid:NO, tenant_id:uuid:NO, source_system:text:NO, crm_connection_id:uuid:NO, file_sha256:text:NO, '
                      || 'cutover_date:date:NO, counts:jsonb:NO, started_at:timestamp with time zone:NO, '
                      || 'finished_at:timestamp with time zone:YES, withdrawn_at:timestamp with time zone:YES, withdrawn_by:uuid:YES' then
    v_bad := v_bad || 'legacy_call_batch columns; ';
  end if;
  if (select string_agg(column_name || ':' || data_type || ':' || is_nullable, ', ' order by ordinal_position)
      from information_schema.columns where table_schema = 'cma' and table_name = 'legacy_call_outcome')
     is distinct from 'id:uuid:NO, tenant_id:uuid:NO, batch_id:uuid:NO, source_row:integer:NO, occurred_on:date:NO, meaning:text:NO, '
                      || 'source_label:text:NO, crm_connection_id:uuid:NO, crm_contact_source_id:text:YES, match_method:text:NO, '
                      || 'matched_at:timestamp with time zone:YES' then
    v_bad := v_bad || 'legacy_call_outcome columns; ';
  end if;
  insert into verify_0008zg values (2, 'A2 the two tables and their columns',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. row-level security with the tenant policy and the audit trigger; the application selects, inserts and updates
  --     and never deletes; the readers see neither table
  v_bad := '';
  foreach v_t in array array['legacy_call_batch', 'legacy_call_outcome'] loop
    if not (select relrowsecurity from pg_class where oid = ('cma.' || v_t)::regclass)
       or not exists (select 1 from pg_policies where schemaname = 'cma' and tablename = v_t and policyname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = ('cma.' || v_t)::regclass and tgname = 'audit') then
      v_bad := v_bad || v_t || ' security or audit; ';
    end if;
    if not has_table_privilege('cma_app', 'cma.' || v_t, 'select') or not has_table_privilege('cma_app', 'cma.' || v_t, 'insert')
       or not has_table_privilege('cma_app', 'cma.' || v_t, 'update') or has_table_privilege('cma_app', 'cma.' || v_t, 'delete')
       or has_table_privilege('cma_readonly', 'cma.' || v_t, 'select') then
      v_bad := v_bad || v_t || ' privileges; ';
    end if;
  end loop;
  insert into verify_0008zg values (3, 'A3 row-level security, the audit, no delete for the application, nothing for readers',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the keys and checks
  v_bad := '';
  if not exists (select 1 from pg_indexes where schemaname = 'cma' and tablename = 'legacy_call_batch' and indexname = 'legacy_call_batch_file_idx'
                 and indexdef like 'CREATE UNIQUE INDEX%(tenant_id, file_sha256) WHERE (withdrawn_at IS NULL)') then
    v_bad := v_bad || 'one live batch per file; ';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.legacy_call_outcome'::regclass and contype = 'u'
                 and pg_get_constraintdef(oid) = 'UNIQUE (tenant_id, batch_id, source_row)') then
    v_bad := v_bad || 'one row per batch and source row; ';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.legacy_call_outcome'::regclass and contype = 'f'
                 and pg_get_constraintdef(oid) like 'FOREIGN KEY (tenant_id, batch_id, crm_connection_id) REFERENCES %legacy_call_batch(tenant_id, id, crm_connection_id)%') then
    v_bad := v_bad || 'the outcome''s CRM connection is the batch''s; ';
  end if;
  select string_agg(pg_get_constraintdef(oid), ' | ') into v_a from pg_constraint
  where conrelid = 'cma.legacy_call_outcome'::regclass and contype = 'c';
  if v_a not like '%(crm_contact_source_id IS NOT NULL) = (match_method = ANY (ARRAY[''email_phone''::text, ''email''::text, ''phone''::text, ''customer_id''::text]))%'
     or v_a not like '%(matched_at IS NOT NULL) = (crm_contact_source_id IS NOT NULL)%'
     or v_a not like '%strpos(source_label, ''@''::text) = 0%' then
    v_bad := v_bad || 'the outcome''s checks; ';
  end if;
  -- the meaning's keys, sorted, against cma.telephony_tag.meaning's
  select string_agg(k, ',' order by k) into v_a from (
    select (regexp_matches(pg_get_constraintdef(oid), '''([a-z_]+)''::text', 'g'))[1] as k
    from pg_constraint where conrelid = 'cma.legacy_call_outcome'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%meaning%') x;
  select string_agg(k, ',' order by k) into v_b from (
    select (regexp_matches(pg_get_constraintdef(oid), '''([a-z_]+)''::text', 'g'))[1] as k
    from pg_constraint where conrelid = 'cma.telephony_tag'::regclass and conname = 'telephony_tag_meaning_check') x;
  if v_a is distinct from v_b or v_a not like '%courtesy_completed_negative%' or v_a not like '%incorrect_data%' then
    v_bad := v_bad || 'the meaning''s keys (' || coalesce(v_a, '-') || ' against ' || coalesce(v_b, '-') || '); ';
  end if;
  insert into verify_0008zg values (4, 'A4 one live batch per file, one row per source row, the checks, the meaning''s keys',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. every function the application's only and in the caller's rights; the privacy deletion carries 0008n's tasks
  --     and 0008zg's outcomes
  v_bad := '';
  foreach v_f in array array['cma.legacy_call_counts_ok(jsonb)', 'cma.assert_legacy_crm_connection(uuid)',
                             'cma.legacy_call_batch_start(uuid,text,text,date)', 'cma.legacy_call_outcomes_upsert(uuid,jsonb)',
                             'cma.legacy_call_batch_finish(uuid,jsonb)', 'cma.legacy_call_reconcile(jsonb)',
                             'cma.withdraw_legacy_call_batch(uuid)', 'cma.ingest_contact_forget(uuid,text)'] loop
    if to_regprocedure(v_f) is null
       or (select prosecdef from pg_proc where oid = to_regprocedure(v_f))
       or not has_function_privilege('cma_app', v_f, 'execute')
       or has_function_privilege('cma_readonly', v_f, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_f) and a.grantee = 0) then
      v_bad := v_bad || v_f || '; ';
    end if;
  end loop;
  v_a := (select prosrc from pg_proc where oid = 'cma.ingest_contact_forget(uuid,text)'::regprocedure);
  if v_a !~ 'cma\.legacy_call_outcome' or v_a !~ 'match_method = ''forgotten''' or v_a !~ 'cma\.crm_task' or v_a !~ 'kept_cleared_at' then
    v_bad := v_bad || 'cma.ingest_contact_forget body; ';
  end if;
  insert into verify_0008zg values (5, 'A5 the functions the application''s only, invoker''s rights; the privacy deletion''s body',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A6. the reporting views: every column, the outcomes of withdrawn batches left out; the job name
  v_bad := '';
  if (select string_agg(column_name, ', ' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'legacy_call_batch')
     is distinct from 'id, tenant_id, source_system, crm_connection_id, file_sha256, cutover_date, counts, started_at, finished_at, withdrawn_at, withdrawn_by' then
    v_bad := v_bad || 'cma_read.legacy_call_batch columns; ';
  end if;
  if (select string_agg(column_name, ', ' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'legacy_call_outcome')
     is distinct from 'id, tenant_id, batch_id, source_row, occurred_on, meaning, source_label, crm_connection_id, crm_contact_source_id, match_method, matched_at' then
    v_bad := v_bad || 'cma_read.legacy_call_outcome columns; ';
  end if;
  if not has_table_privilege('cma_readonly', 'cma_read.legacy_call_batch', 'select')
     or not has_table_privilege('cma_readonly', 'cma_read.legacy_call_outcome', 'select')
     or pg_get_viewdef('cma_read.legacy_call_outcome'::regclass) not like '%withdrawn_at IS NULL%' then
    v_bad := v_bad || 'the readers or the withdrawn filter; ';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.sync_run'::regclass and conname = 'sync_run_job_check')
     not like '%''close_forgotten_workdays''%''refresh_follow_up''%''reviews_poll''%''legacy_call_import''%' then
    v_bad := v_bad || 'the job name; ';
  end if;
  insert into verify_0008zg values (6, 'A6 the reporting views, the withdrawn filter, the job name',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_t2 uuid; v_admin1 uuid; v_agent1 uuid; v_ing1 uuid; v_ing2 uuid; v_admin2 uuid;
  v_crm uuid; v_crm_off uuid; v_tel uuid; v_crm2 uuid;
  v_b1 uuid; v_b2 uuid; v_b3 uuid; v_run uuid;
  v_txt text; v_a text;
  v_big jsonb;
  v_sha1 constant text := repeat('a1', 32);
  v_sha2 constant text := repeat('b2', 32);
  v_h1   constant text := repeat('1f', 32);
  v_h2   constant text := repeat('2e', 32);
  v_h3   constant text := repeat('3d', 32);
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people, connections, the telephony catalog and calls (as the owner)
    v_t1 := cma.create_tenant('verify-0008zg-one', 'Verify 0008zg one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zg-two', 'Verify 0008zg two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_agent1, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifycrm', 'Verify legacy CRM', 'portal-zg', 'crm') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, status)
    values (v_t1, 'verifycrm', 'Verify legacy CRM off', 'portal-zg-off', 'crm', 'inactive') returning id into v_crm_off;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifytel', 'Verify legacy telephony', 'account-zg', 'telephony') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t2, 'verifycrm', 'Verify legacy CRM two', 'portal-zg-2', 'crm') returning id into v_crm2;
    insert into cma.telephony_tag (tenant_id, connection_id, tag_ref, name, meaning)
    values (v_t1, v_tel, 't-pos', 'Courtesy positive', 'courtesy_completed_positive'),
           (v_t1, v_tel, 't-neg', 'Courtesy negative', 'courtesy_completed_negative'),
           (v_t1, v_tel, 't-att', 'Courtesy attempt', 'courtesy_attempt'),
           (v_t1, v_tel, 't-none', 'Something else', null);
    -- calls (started_at in UTC; Amsterdam is UTC+2 in September 2026): k1 on 2026-09-03 with a current positive tag;
    -- k2 on 2026-09-03 whose negative tag was removed; k3 on 2026-09-03 with a courtesy attempt only; k4 at 23:30 UTC
    -- on 2026-09-04, so 2026-09-05 in Amsterdam, with a current negative tag; k5 on 2026-09-03 with a positive tag,
    -- deleted at the source
    insert into cma.telephony_call (tenant_id, connection_id, source_system, source_id, direction, started_at, counterpart_hash, source_version_at, source_deleted_at)
    values (v_t1, v_tel, 'verifytel', 'k1', 'outbound', '2026-09-03 08:00:00+00', v_h1, '2026-09-03 08:10:00+00', null),
           (v_t1, v_tel, 'verifytel', 'k2', 'outbound', '2026-09-03 09:00:00+00', v_h2, '2026-09-03 09:10:00+00', null),
           (v_t1, v_tel, 'verifytel', 'k3', 'outbound', '2026-09-03 10:00:00+00', v_h3, '2026-09-03 10:10:00+00', null),
           (v_t1, v_tel, 'verifytel', 'k4', 'outbound', '2026-09-04 23:30:00+00', v_h1, '2026-09-04 23:40:00+00', null),
           (v_t1, v_tel, 'verifytel', 'k5', 'outbound', '2026-09-03 11:00:00+00', v_h3, '2026-09-03 11:10:00+00', '2026-09-04 00:00:00+00');
    insert into cma.telephony_call_tag (tenant_id, connection_id, call_source_id, tag_ref, tagged_at, untagged_at)
    values (v_t1, v_tel, 'k1', 't-pos', '2026-09-03 08:10:00+00', null),
           (v_t1, v_tel, 'k1', 't-none', '2026-09-03 08:10:00+00', null),
           (v_t1, v_tel, 'k2', 't-neg', '2026-09-03 09:10:00+00', '2026-09-03 09:20:00+00'),
           (v_t1, v_tel, 'k3', 't-att', '2026-09-03 10:10:00+00', null),
           (v_t1, v_tel, 'k4', 't-neg', '2026-09-04 23:40:00+00', null),
           (v_t1, v_tel, 'k5', 't-pos', '2026-09-03 11:10:00+00', null);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);

    -- B1. a batch: started; the same file again reused (the same batch); refused for another cutover (CMA03), a
    --     telephony connection (CMA04), an inactive connection (CMA02), a bad SHA-256 and a bad source system (CMA04),
    --     an agent (CMA06)
    perform set_config('app.user_id', v_ing1::text, true);
    select s.batch_id, s.outcome into v_b1, v_a from cma.legacy_call_batch_start(v_crm, 'steamtest', v_sha1, '2026-09-01') s;
    v_txt := v_a || ' ' || (select s.outcome || ':' || (s.batch_id = v_b1)::text from cma.legacy_call_batch_start(v_crm, 'steamtest', upper(v_sha1), '2026-09-01') s)
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_batch_start(%L, %L, %L, %L)', v_crm, 'steamtest', v_sha1, '2026-08-01'))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_batch_start(%L, %L, %L, %L)', v_tel, 'steamtest', v_sha2, '2026-09-01'))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_batch_start(%L, %L, %L, %L)', v_crm_off, 'steamtest', v_sha2, '2026-09-01'))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_batch_start(%L, %L, %L, %L)', v_crm, 'steamtest', 'abc', '2026-09-01'))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_batch_start(%L, %L, %L, %L)', v_crm, 'Steam Test', v_sha2, '2026-09-01'));
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_batch_start(%L, %L, %L, %L)', v_crm, 'steamtest', v_sha2, '2026-09-01'));
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || (select count(*) || ':' || bool_and(b.file_sha256 = v_sha1)::text || ':' || min(b.counts::text) || ':' || min(b.cutover_date::text)
                              from cma.legacy_call_batch b where b.tenant_id = v_t1);
    v_rows := v_rows || array['11', 'B1 a batch started, the same file reused, the refusals',
      case when v_txt = format('started reused:true CMA03 CMA04 CMA02 CMA04 CMA04 CMA06 1:%s:{}:2026-09-01', 'true') and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. the rows of every match method: inserted, a contact and matched_at exactly with email_phone, email, phone and
    --     customer_id
    v_txt := (select string_agg(u.source_row || ':' || u.outcome, ' ' order by u.source_row)
              from cma.legacy_call_outcomes_upsert(v_b1, jsonb_build_array(
                pg_temp.v0008zg_row(2, '2025-05-14', 'courtesy_completed_positive', 'Courtesy positief', 'c-1', 'email_phone'),
                pg_temp.v0008zg_row(3, '2025-06-01', 'courtesy_completed_neutral', 'Courtesy neutraal', 'c-2', 'email'),
                pg_temp.v0008zg_row(4, '2025-07-01', 'courtesy_completed_negative', 'Courtesy negatief', 'c-3', 'phone'),
                pg_temp.v0008zg_row(5, '2025-08-01', 'courtesy_completed_positive', 'Courtesy positief', 'c-1', 'customer_id'),
                pg_temp.v0008zg_row(6, '2026-08-31', 'courtesy_completed_neutral', 'Courtesy neutraal', null, 'none'),
                pg_temp.v0008zg_row(7, '2026-01-02', 'courtesy_completed_negative', 'Courtesy negatief', null, 'conflict'))) u);
    -- (each read in a statement of its own: the statement that wrote the rows sees them as they were before)
    v_txt := v_txt || ' | ' || pg_temp.v0008zg_rows(v_b1);
    v_txt := v_txt || ' | ' || (select string_agg(distinct (o.crm_connection_id = v_crm)::text || ':' || o.meaning, ',')
                                from cma.legacy_call_outcome o where o.batch_id = v_b1 and o.source_row = 2);
    v_rows := v_rows || array['12', 'B2 a row of every match method stored; a contact and matched_at exactly with the four',
      case when v_txt = '2:inserted 3:inserted 4:inserted 5:inserted 6:inserted 7:inserted | 2:email_phone:c-1:true 3:email:c-2:true '
                        || '4:phone:c-3:true 5:customer_id:c-1:true 6:none:-:false 7:conflict:-:false | true:courtesy_completed_positive'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. an idempotent rerun: the same rows answer unchanged and nothing is written (no audit row, the same rows)
    v_a := (select count(*)::text from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'legacy_call_outcome');
    v_txt := (select string_agg(u.outcome, ',' order by u.source_row)
              from cma.legacy_call_outcomes_upsert(v_b1, jsonb_build_array(
                pg_temp.v0008zg_row(2, '2025-05-14', 'courtesy_completed_positive', 'Courtesy positief', 'c-1', 'email_phone'),
                pg_temp.v0008zg_row(6, '2026-08-31', 'courtesy_completed_neutral', 'Courtesy neutraal', null, 'none'),
                pg_temp.v0008zg_row(7, '2026-01-02', 'courtesy_completed_negative', 'Courtesy negatief', null, 'conflict'))) u)
             || ' ' || ((select count(*)::text from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'legacy_call_outcome') = v_a)::text
             || ' ' || (select count(*) from cma.legacy_call_outcome o where o.batch_id = v_b1);
    v_rows := v_rows || array['13', 'B3 an idempotent rerun: unchanged, nothing written',
      case when v_txt = 'unchanged,unchanged,unchanged true 6' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. a rerun fills a contact only where none is set: none → email (filled), a set contact kept against another one
    --     and against none, conflict → none (updated, still no contact); a changed date, meaning or label refuses the
    --     whole call (CMA03) and changes nothing
    v_txt := (select string_agg(u.source_row || ':' || u.outcome, ' ' order by u.source_row)
              from cma.legacy_call_outcomes_upsert(v_b1, jsonb_build_array(
                pg_temp.v0008zg_row(6, '2026-08-31', 'courtesy_completed_neutral', 'Courtesy neutraal', 'c-6', 'email'),
                pg_temp.v0008zg_row(3, '2025-06-01', 'courtesy_completed_neutral', 'Courtesy neutraal', 'c-9', 'phone'),
                pg_temp.v0008zg_row(4, '2025-07-01', 'courtesy_completed_negative', 'Courtesy negatief', null, 'none'),
                pg_temp.v0008zg_row(7, '2026-01-02', 'courtesy_completed_negative', 'Courtesy negatief', null, 'none'))) u)
             || ' | ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b1, jsonb_build_array(
                           pg_temp.v0008zg_row(8, '2025-09-01', 'courtesy_completed_positive', 'Courtesy positief', null, 'none'),
                           pg_temp.v0008zg_row(2, '2025-05-15', 'courtesy_completed_positive', 'Courtesy positief', 'c-1', 'email_phone'))))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b1, jsonb_build_array(
                           pg_temp.v0008zg_row(2, '2025-05-14', 'courtesy_attempt', 'Courtesy positief', 'c-1', 'email_phone'))))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b1, jsonb_build_array(
                           pg_temp.v0008zg_row(2, '2025-05-14', 'courtesy_completed_positive', 'Courtesy positive', 'c-1', 'email_phone'))))
             || ' | ' || pg_temp.v0008zg_rows(v_b1);
    v_rows := v_rows || array['14', 'B4 a contact filled only where none is set, a set one kept, a changed fact refused',
      case when v_txt = '3:kept 4:kept 6:filled 7:updated | CMA03 CMA03 CMA03 | 2:email_phone:c-1:true 3:email:c-2:true 4:phone:c-3:true '
                        || '5:customer_id:c-1:true 6:email:c-6:true 7:none:-:false'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. the refusals of the upsert (CMA04, nothing stored): a row on the cutover date, forgotten sent by the ingest, a
    --     contact with none, an email method without a contact, a label with an @, a meaning outside the seven, a date
    --     that is no date, more than 500 rows; an unknown batch (CMA02); an agent (CMA06)
    select jsonb_agg(pg_temp.v0008zg_row(1000 + g, '2025-09-01', 'courtesy_completed_positive', 'Courtesy positief', null, 'none'))
      into v_big from generate_series(1, 501) g;
    v_txt := pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b1, jsonb_build_array(
               pg_temp.v0008zg_row(20, '2026-09-01', 'courtesy_completed_positive', 'Courtesy positief', null, 'none'))))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b1, jsonb_build_array(
               pg_temp.v0008zg_row(21, '2025-09-01', 'courtesy_completed_positive', 'Courtesy positief', null, 'forgotten'))))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b1, jsonb_build_array(
               pg_temp.v0008zg_row(22, '2025-09-01', 'courtesy_completed_positive', 'Courtesy positief', 'c-1', 'none'))))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b1, jsonb_build_array(
               pg_temp.v0008zg_row(23, '2025-09-01', 'courtesy_completed_positive', 'Courtesy positief', null, 'email'))))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b1, jsonb_build_array(
               pg_temp.v0008zg_row(24, '2025-09-01', 'courtesy_completed_positive', 'someone@example.invalid', null, 'none'))))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b1, jsonb_build_array(
               pg_temp.v0008zg_row(25, '2025-09-01', 'happy', 'Courtesy positief', null, 'none'))))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b1, jsonb_build_array(
               pg_temp.v0008zg_row(26, '2025-02-30', 'courtesy_completed_positive', 'Courtesy positief', null, 'none'))))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b1, v_big))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', gen_random_uuid(), jsonb_build_array(
               pg_temp.v0008zg_row(27, '2025-09-01', 'courtesy_completed_positive', 'Courtesy positief', null, 'none'))));
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b1, jsonb_build_array(
               pg_temp.v0008zg_row(28, '2025-09-01', 'courtesy_completed_positive', 'Courtesy positief', null, 'none'))));
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || (select count(*) from cma.legacy_call_outcome o where o.batch_id = v_b1);
    v_rows := v_rows || array['15', 'B5 the upsert''s refusals, nothing stored',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA02 CMA06 6' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. the table's own checks, by the owner (23514 a check, 23503 a foreign key, 23505 a duplicate): a contact with
    --     none, email_phone without a contact, matched_at without a contact, an @ in the label, another CRM connection than
    --     the batch's, a second row 2, a second live batch of the same file
    perform set_config('role', 'cma_owner', true);
    v_txt := pg_temp.v0008zg_code(format('insert into cma.legacy_call_outcome (tenant_id, batch_id, source_row, occurred_on, meaning, source_label, crm_connection_id, crm_contact_source_id, match_method, matched_at) values (%L, %L, 30, %L, %L, %L, %L, %L, %L, now())',
               v_t1, v_b1, '2025-01-01', 'courtesy_attempt', 'x', v_crm, 'c-1', 'none'))
             || ' ' || pg_temp.v0008zg_code(format('insert into cma.legacy_call_outcome (tenant_id, batch_id, source_row, occurred_on, meaning, source_label, crm_connection_id, match_method) values (%L, %L, 31, %L, %L, %L, %L, %L)',
               v_t1, v_b1, '2025-01-01', 'courtesy_attempt', 'x', v_crm, 'email_phone'))
             || ' ' || pg_temp.v0008zg_code(format('insert into cma.legacy_call_outcome (tenant_id, batch_id, source_row, occurred_on, meaning, source_label, crm_connection_id, match_method, matched_at) values (%L, %L, 32, %L, %L, %L, %L, %L, now())',
               v_t1, v_b1, '2025-01-01', 'courtesy_attempt', 'x', v_crm, 'none'))
             || ' ' || pg_temp.v0008zg_code(format('insert into cma.legacy_call_outcome (tenant_id, batch_id, source_row, occurred_on, meaning, source_label, crm_connection_id, match_method) values (%L, %L, 33, %L, %L, %L, %L, %L)',
               v_t1, v_b1, '2025-01-01', 'courtesy_attempt', 'a@b', v_crm, 'none'))
             || ' ' || pg_temp.v0008zg_code(format('insert into cma.legacy_call_outcome (tenant_id, batch_id, source_row, occurred_on, meaning, source_label, crm_connection_id, match_method) values (%L, %L, 34, %L, %L, %L, %L, %L)',
               v_t1, v_b1, '2025-01-01', 'courtesy_attempt', 'x', v_crm_off, 'none'))
             || ' ' || pg_temp.v0008zg_code(format('insert into cma.legacy_call_outcome (tenant_id, batch_id, source_row, occurred_on, meaning, source_label, crm_connection_id, match_method) values (%L, %L, 2, %L, %L, %L, %L, %L)',
               v_t1, v_b1, '2025-01-01', 'courtesy_attempt', 'x', v_crm, 'none'))
             || ' ' || pg_temp.v0008zg_code(format('insert into cma.legacy_call_batch (tenant_id, source_system, crm_connection_id, file_sha256, cutover_date) values (%L, %L, %L, %L, %L)',
               v_t1, 'steamtest', v_crm, v_sha1, '2026-09-01'));
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['16', 'B6 the table''s own checks: contact and method, matched_at, the label, the batch''s CRM connection, duplicates',
      case when v_txt = '23514 23514 23514 23514 23503 23505 23505' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. the finish: the job's counts with the stored rows per method; another key, a text or a negative number refused
    --     (CMA04); called again it writes that run's counts
    v_txt := cma.legacy_call_batch_finish(v_b1, '{"total": 9, "legacy": 7, "current": 2, "refused": 1, "current_found": 1, "current_not_found": 1}')::text;
    v_txt := v_txt || ' ' || (select (b.finished_at is not null)::text || ':' || (b.counts ->> 'stored') from cma.legacy_call_batch b where b.id = v_b1)
             || ' ' || pg_temp.v0008zg_code(format('select cma.legacy_call_batch_finish(%L, %L)', v_b1, '{"total": 9, "email": 1}'))
             || ' ' || pg_temp.v0008zg_code(format('select cma.legacy_call_batch_finish(%L, %L)', v_b1, '{"total": "9"}'))
             || ' ' || pg_temp.v0008zg_code(format('select cma.legacy_call_batch_finish(%L, %L)', v_b1, '{"total": -1}'))
             || ' ' || (cma.legacy_call_batch_finish(v_b1, '{"total": 9}') ->> 'total');
    v_txt := v_txt || ' ' || (select (b.counts ->> 'legacy' is null)::text || ':' || (b.counts ->> 'stored') from cma.legacy_call_batch b where b.id = v_b1);
    v_rows := v_rows || array['17', 'B7 the finish: the job''s counts and the stored rows per method; the refusals; a second finish',
      case when v_txt = '{"none": 1, "email": 2, "phone": 1, "total": 9, "legacy": 7, "stored": 6, "current": 2, "refused": 1, "conflict": 0, '
                        || '"forgotten": 0, "customer_id": 1, "email_phone": 1, "current_found": 1, "current_not_found": 1} true:6 CMA04 CMA04 CMA04 9 true:6'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. the reconciliation read: calls on the date in the tenant's zone with that hash and a current courtesy completed
    --     tag. Item 1: h1 on 2026-09-03 (k1, positive: 1); 2: h2 on 2026-09-03 (k2, its tag removed: 0); 3: h3 on
    --     2026-09-03 (k3, an attempt only, k5 deleted: 0); 4: h1 on 2026-09-05 (k4 at 23:30 UTC, 01:30 in Amsterdam: 1);
    --     5: h1 on 2026-09-04 (0). The refusals: a hash that is no hash, a date that is no date (CMA04), an agent (CMA06)
    v_txt := (select string_agg(r.item || ':' || r.calls, ' ' order by r.item) from cma.legacy_call_reconcile(jsonb_build_array(
               jsonb_build_object('item', 1, 'hash', v_h1, 'date', '2026-09-03'), jsonb_build_object('item', 2, 'hash', v_h2, 'date', '2026-09-03'),
               jsonb_build_object('item', 3, 'hash', v_h3, 'date', '2026-09-03'), jsonb_build_object('item', 4, 'hash', v_h1, 'date', '2026-09-05'),
               jsonb_build_object('item', 5, 'hash', v_h1, 'date', '2026-09-04'))) r)
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_reconcile(%L)', jsonb_build_array(jsonb_build_object('item', 1, 'hash', '+31201234567', 'date', '2026-09-03'))))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_reconcile(%L)', jsonb_build_array(jsonb_build_object('item', 1, 'hash', v_h1, 'date', '2026-02-30'))));
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_reconcile(%L)', jsonb_build_array(jsonb_build_object('item', 1, 'hash', v_h1, 'date', '2026-09-03'))));
    perform set_config('app.user_id', v_ing1::text, true);
    v_rows := v_rows || array['18', 'B8 the reconciliation read: a current courtesy completed tag on the tenant''s day; the refusals',
      case when v_txt = '1:1 2:0 3:0 4:1 5:0 CMA04 CMA04 CMA06' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. the privacy deletion of contact c-1: its rows read forgotten without a contact or matched_at, the answer counts
    --     them, the other rows unchanged; a rerun answers forgotten and never fills it again; a contact of another CRM
    --     connection is left alone
    v_txt := cma.ingest_contact_forget(v_crm, 'c-1')::text
             || ' | ' || pg_temp.v0008zg_rows(v_b1)
             || ' | ' || (select string_agg(u.source_row || ':' || u.outcome, ' ' order by u.source_row)
                          from cma.legacy_call_outcomes_upsert(v_b1, jsonb_build_array(
                            pg_temp.v0008zg_row(2, '2025-05-14', 'courtesy_completed_positive', 'Courtesy positief', 'c-1', 'email_phone'),
                            pg_temp.v0008zg_row(5, '2025-08-01', 'courtesy_completed_positive', 'Courtesy positief', 'c-7', 'customer_id'))) u)
             || ' | ' || cma.ingest_contact_forget(v_crm, 'c-404')::text
             || ' ' || pg_temp.v0008zg_rows(v_b1);
    v_rows := v_rows || array['19', 'B9 the privacy deletion: forgotten, counted, never filled again by a rerun',
      case when v_txt = '{"refs": 0, "calls": 0, "contacts": 0, "submissions": 0, "legacy_calls": 2} | 2:forgotten:-:false 3:email:c-2:true '
                        || '4:phone:c-3:true 5:forgotten:-:false 6:email:c-6:true 7:none:-:false | 2:forgotten 5:forgotten | '
                        || '{"refs": 0, "calls": 0, "contacts": 0, "submissions": 0} 2:forgotten:-:false 3:email:c-2:true 4:phone:c-3:true '
                        || '5:forgotten:-:false 6:email:c-6:true 7:none:-:false'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. the withdrawal: the Ingest user and an agent refused (CMA06); the admin once, with who and when, audited; a
    --      second time CMA03; then no rows (CMA03) and no finish (CMA03); the reader view leaves the batch's rows out and
    --      shows the batch; the same file starts a new batch; the privacy deletion still reaches a withdrawn batch's rows
    v_txt := pg_temp.v0008zg_code(format('select cma.withdraw_legacy_call_batch(%L)', v_b1));
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zg_code(format('select cma.withdraw_legacy_call_batch(%L)', v_b1));
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ' ' || (cma.withdraw_legacy_call_batch(v_b1) is not null)::text
             || ' ' || pg_temp.v0008zg_code(format('select cma.withdraw_legacy_call_batch(%L)', v_b1))
             || ' ' || pg_temp.v0008zg_code(format('select cma.withdraw_legacy_call_batch(%L)', gen_random_uuid()));
    v_txt := v_txt || ' ' || (select (b.withdrawn_by = v_admin1)::text from cma.legacy_call_batch b where b.id = v_b1)
             || ' ' || (select count(*) || ':' || bool_and(a.actor_user_id = v_admin1 and a.new_row ->> 'withdrawn_at' is not null and a.old_row ->> 'withdrawn_at' is null)::text
                        from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'legacy_call_batch' and a.action = 'update' and a.row_id = v_b1::text
                          and a.new_row ->> 'withdrawn_by' is not null);
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b1, jsonb_build_array(
               pg_temp.v0008zg_row(9, '2025-09-01', 'courtesy_completed_positive', 'Courtesy positief', null, 'none'))))
             || ' ' || pg_temp.v0008zg_code(format('select cma.legacy_call_batch_finish(%L, %L)', v_b1, '{"total": 1}'));
    select s.batch_id, s.outcome into v_b2, v_a from cma.legacy_call_batch_start(v_crm, 'steamtest', v_sha1, '2026-09-01') s;
    perform cma.legacy_call_outcomes_upsert(v_b2, jsonb_build_array(
      pg_temp.v0008zg_row(3, '2025-06-01', 'courtesy_completed_neutral', 'Courtesy neutraal', 'c-2', 'email')));
    v_txt := v_txt || ' ' || v_a || ':' || (v_b2 <> v_b1)::text;
    perform set_config('role', 'cma_readonly', true);
    v_txt := v_txt || ' ' || (select count(*) from cma_read.legacy_call_outcome o where o.tenant_id = v_t1)
             || ':' || (select count(*) from cma_read.legacy_call_outcome o where o.batch_id = v_b1)
             || ':' || (select count(*) from cma_read.legacy_call_batch b where b.tenant_id = v_t1)
             || ':' || (select count(*) from cma_read.legacy_call_batch b where b.id = v_b1 and b.withdrawn_at is not null);
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' ' || (cma.ingest_contact_forget(v_crm, 'c-2') ->> 'legacy_calls');
    v_txt := v_txt || ' ' || (select string_agg(o.source_row || ':' || o.match_method, ',' order by o.batch_id = v_b1, o.source_row)
                        from cma.legacy_call_outcome o where o.tenant_id = v_t1 and o.source_row = 3);
    v_rows := v_rows || array['20', 'B10 the withdrawal: once by the admin, audited; no more rows; left out of the readers; the file again',
      case when v_txt = 'CMA06 CMA06 true CMA03 CMA02 true 1:true CMA03 CMA03 started:true 1:0:2:1 2 3:forgotten,3:forgotten'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. tenant isolation: tenant two's Ingest user sees none of tenant one's batches or rows and reaches none of them
    --      (CMA02 for rows, a finish and the admin's withdrawal; a start on tenant one's CRM connection CMA02); its own
    --      batch of the same file is its own
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    v_txt := (select count(*) from cma.legacy_call_batch)::text || ':' || (select count(*) from cma.legacy_call_outcome)::text
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_outcomes_upsert(%L, %L)', v_b2, jsonb_build_array(
                         pg_temp.v0008zg_row(9, '2025-09-01', 'courtesy_completed_positive', 'Courtesy positief', null, 'none'))))
             || ' ' || pg_temp.v0008zg_code(format('select cma.legacy_call_batch_finish(%L, %L)', v_b2, '{"total": 1}'))
             || ' ' || pg_temp.v0008zg_code(format('select * from cma.legacy_call_batch_start(%L, %L, %L, %L)', v_crm, 'steamtest', v_sha2, '2026-09-01'))
             || ' ' || (select s.outcome from cma.legacy_call_batch_start(v_crm2, 'steamtest', v_sha1, '2026-09-01') s)
             || ' ' || (select count(*) from cma.legacy_call_reconcile(jsonb_build_array(jsonb_build_object('item', 1, 'hash', v_h1, 'date', '2026-09-03'))) r
                        where r.calls > 0);
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zg_code(format('select cma.withdraw_legacy_call_batch(%L)', v_b2));
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || (select count(*) from cma.legacy_call_batch)::text;
    v_rows := v_rows || array['21', 'B11 tenant isolation: nothing of tenant one seen or reached from tenant two',
      case when v_txt = '0:0 CMA02 CMA02 CMA02 started 0 CMA02 2' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B12. the job's run: sync_run takes legacy_call_import with its stream, finished with its counts; the audit names the
    --      Ingest user for the rows and the batch it wrote
    v_run := cma.ingest_sync_run_start(v_crm, 'legacy_call_import', 'steamtest', null, null);
    perform cma.ingest_sync_run_finish(v_run, 'succeeded', '{"fetched": 9, "upserted": 6, "skipped": 2, "failed": 1}');
    v_txt := (select r.job || ':' || r.stream || ':' || r.status || ':' || (r.counts ->> 'upserted') from cma.sync_run r where r.id = v_run)
             || ' ' || (select count(*) || ':' || bool_and(a.actor_user_id = v_ing1)::text from cma.audit_log a
                        where a.tenant_id = v_t1 and a.table_name = 'legacy_call_outcome' and a.action = 'insert')
             || ' ' || (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'legacy_call_outcome' and a.action = 'delete');
    v_rows := v_rows || array['22', 'B12 the job''s sync run; the audit of the rows',
      case when v_txt = 'legacy_call_import:steamtest:succeeded:6 7:true 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['29', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zg (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zg values (29, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zg
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008zg where result = 'PASS') = 18
                       and not exists (select 1 from verify_0008zg where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('109_verify_legacy_call_outcome: %s PASS, %s FAIL', (select count(*) from verify_0008zg where result = 'PASS'),
                                                                       (select count(*) from verify_0008zg where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008zg_code(text);
drop function if exists pg_temp.v0008zg_row(integer, text, text, text, text, text);
drop function if exists pg_temp.v0008zg_rows(uuid);
reset role;
