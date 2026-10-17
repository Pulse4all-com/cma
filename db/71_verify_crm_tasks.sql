-- =============================================================================================
-- 71_verify_crm_tasks.sql: verifies addition 0008n, CRM tasks (never body or subject)
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; adapters, refs and ids are invented
-- data values. Every check writes one row, PASS or FAIL, and the last result lists them with the
-- verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after
-- 70_crm_tasks.sql; then 33, 53 and 69 again (unchanged).
--   A  structure and privileges: the addition row after 0008m; the three tables with row-level
--      security, the tenant policy, audit, no delete for the application and a reader view each; the
--      views' exact columns (crm_task without raw); no column named like a task's text and the check
--      on raw; every function the application's only, in the caller's rights; held kinds, the contact
--      upsert and the privacy deletion naming tasks
--   B  behaviour on tenant one (a CRM connection, a telephony connection, one without a kind) and
--      tenant two: the upsert seeding both catalogs with the defaults; update and stale; the strip of
--      body, subject, a connection-named key, nested values, a string with an @ and a long one, and
--      the table's check refusing a body key on any path; is_done and the labels a person set surviving
--      a read; associations taken as the read gives them; deletion, an unknown deletion, a newer read
--      bringing the task back; a contact held for a task alone; the privacy deletion clearing the task's
--      contact; tenant isolation; the configuration refusals (an agent, a null switch, a ref with a
--      space, an empty label, an unknown connection, a telephony connection, the Ingest user); the
--      upsert's refusals; the Sources read with its counts; task rows making a connection's kind crm
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says
-- PROVOKED instead of PASS.
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

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the
-- session, so every block below stops at once and the verdict says REFUSED
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 71 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008n;
create temp table verify_0008n (ord int, check_name text, result text, detail text);

-- The SQLSTATE a statement fails with, or ok
create or replace function pg_temp.v8n_err(p_sql text)
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

-- One task as the ingest write takes it, created and updated at a fixed time, due the next day, plus p_extra
create or replace function pg_temp.v8n_task(p_src text, p_status text, p_type text, p_extra jsonb default '{}')
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object('sourceId', p_src, 'statusRef', p_status, 'typeRef', p_type,
    'createdAt', '2026-10-05T09:00:00Z', 'updatedAt', '2026-10-05T09:00:00Z', 'dueAt', '2026-10-06T10:00:00Z')) || p_extra
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t       text;
  v_fn      text;
  v_bad     text;
  v_cols    text;
  v_want    text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008m
  insert into verify_0008n values (1, 'A1 addition 0008n recorded, after 0008m',
    case when exists (select 1 from cma.schema_migration where version = '0008n')
              and exists (select 1 from cma.schema_migration where version = '0008m') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the three tables: row-level security with the tenant policy and the audit trigger; the
  --     application inserts and updates, never deletes; readers have no rights on a base table and read
  --     its view in cma_read
  v_bad := '';
  foreach v_t in array array['crm_task', 'connection_task_status', 'connection_task_type'] loop
    if to_regclass('cma.' || v_t) is null then
      v_bad := v_bad || v_t || ' is missing; ';
      continue;
    end if;
    if not (select relrowsecurity from pg_class where oid = ('cma.' || v_t)::regclass) then v_bad := v_bad || v_t || ' has no row-level security; '; end if;
    if not exists (select 1 from pg_policies where schemaname = 'cma' and tablename = v_t and policyname = 'tenant_app') then v_bad := v_bad || v_t || ' has no tenant policy; '; end if;
    if not exists (select 1 from pg_trigger where tgrelid = ('cma.' || v_t)::regclass and tgname = 'audit') then v_bad := v_bad || v_t || ' has no audit trigger; '; end if;
    if not has_table_privilege('cma_app', 'cma.' || v_t, 'insert') or not has_table_privilege('cma_app', 'cma.' || v_t, 'update') then
      v_bad := v_bad || 'the application cannot write ' || v_t || '; ';
    end if;
    if has_table_privilege('cma_app', 'cma.' || v_t, 'delete') then v_bad := v_bad || 'the application may delete from ' || v_t || '; '; end if;
    if has_table_privilege('cma_readonly', 'cma.' || v_t, 'select') then v_bad := v_bad || 'readers read the base table ' || v_t || '; '; end if;
    if to_regclass('cma_read.' || v_t) is null then v_bad := v_bad || v_t || ' has no reader view; '; end if;
  end loop;
  insert into verify_0008n values (2, 'A2 the three tables: RLS, tenant policy, audit, no delete, a reader view each',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the reporting views' exact columns: crm_task without raw; the catalogs whole
  v_bad := '';
  foreach v_t in array array[
    'crm_task=id,tenant_id,connection_id,source_system,source_id,owner_ref,status_ref,type_ref,priority_ref,due_at,completed_at,contact_source_id,deal_source_id,ticket_source_id,source_created_at,source_updated_at,source_deleted_at,synced_at',
    'connection_task_status=tenant_id,connection_id,status_ref,label,is_done,first_seen_at,updated_at',
    'connection_task_type=tenant_id,connection_id,type_ref,label,is_callback,is_counted,first_seen_at,updated_at'] loop
    v_want := split_part(v_t, '=', 2);
    select string_agg(column_name, ',' order by ordinal_position) into v_cols
    from information_schema.columns where table_schema = 'cma_read' and table_name = split_part(v_t, '=', 1);
    if v_cols is distinct from v_want then
      v_bad := v_bad || split_part(v_t, '=', 1) || ' has ' || coalesce(v_cols, 'no columns') || '; ';
    end if;
    select string_agg(column_name, ',' order by ordinal_position) into v_cols
    from information_schema.columns where table_schema = 'cma' and table_name = split_part(v_t, '=', 1);
    if split_part(v_t, '=', 1) = 'crm_task' then
      v_want := v_want || ',raw';
    end if;
    if v_cols is distinct from v_want then
      v_bad := v_bad || 'the table ' || split_part(v_t, '=', 1) || ' has ' || coalesce(v_cols, 'no columns') || '; ';
    end if;
  end loop;
  insert into verify_0008n values (3, 'A3 the reporting views'' exact columns: crm_task without raw, the catalogs whole',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. no column named like a task's text in the tables and views, and the check on raw names the filter
  select string_agg(table_schema || '.' || table_name || '.' || column_name, ', ') into v_bad
  from information_schema.columns
  where table_schema in ('cma', 'cma_read')
    and table_name in ('crm_task', 'connection_task_status', 'connection_task_type')
    and column_name ~* '(subject|body|text|note|description|html|address|sender|recipient)';
  if not exists (select 1 from pg_constraint where conrelid = 'cma.crm_task'::regclass and contype = 'c'
                 and pg_get_constraintdef(oid) like '%task_raw_ok(raw)%') then
    v_bad := coalesce(v_bad || '; ', '') || 'no check on raw through cma.task_raw_ok';
  end if;
  insert into verify_0008n values (4, 'A4 no subject, body, note or text column; the check on raw',
    case when v_bad is null and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_bad, ''));

  -- A5. every function the application's only and in the caller's rights
  v_bad := '';
  foreach v_fn in array array[
    'cma.ingest_upsert_tasks(uuid,jsonb)', 'cma.set_task_status(uuid,text,text,boolean)', 'cma.set_task_type(uuid,text,text,boolean,boolean)',
    'cma.connection_task_catalogs(uuid)', 'cma.assert_task_connection(uuid)', 'cma.task_raw(uuid,jsonb)', 'cma.task_raw_ok(jsonb)',
    'cma.connection_held_kinds_of(uuid,uuid)', 'cma.ingest_upsert_contacts(uuid,jsonb)', 'cma.ingest_contact_forget(uuid,text)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not the application''s only, in the caller''s rights; ';
    end if;
  end loop;
  insert into verify_0008n values (5, 'A5 the functions the application''s only, in the caller''s rights',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A6. the replaced functions name tasks: held kinds, the contact upsert's holding rule, the privacy deletion
  v_bad := '';
  foreach v_fn in array array['cma.connection_held_kinds_of(uuid,uuid)', 'cma.ingest_upsert_contacts(uuid,jsonb)', 'cma.ingest_contact_forget(uuid,text)'] loop
    if to_regprocedure(v_fn) is null or pg_get_functiondef(to_regprocedure(v_fn)) not like '%cma.crm_task%' then
      v_bad := v_bad || v_fn || ' does not name crm_task; ';
    end if;
  end loop;
  insert into verify_0008n values (6, 'A6 held kinds, the contact upsert and the privacy deletion name tasks',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_agent1 uuid; v_ing1 uuid; v_admin2 uuid; v_ing2 uuid;
  v_c1 uuid; v_tel1 uuid; v_x1 uuid; v_c2 uuid;
  v_txt      text;
  v_txt2     text;
  v_detail   text;
  v_n        integer;
  v_m        integer;
  v_res      jsonb;
  v_items    jsonb;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008n-one', 'Verify 0008n one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008n-two', 'Verify 0008n two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_agent1, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    perform set_config('role', 'cma_app', true);

    -- tenant one: a CRM connection naming a subject key of its own, a telephony connection, one without a kind
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    select c.connection_id into v_c1 from cma.upsert_connection('verifycrm', 'Verify CRM one', 'portal-1', null, null) c;
    perform cma.set_connection_kind(v_c1, 'crm');
    perform cma.set_connection_settings(v_c1, '{"task_subject_property": "my_subject"}'::jsonb);
    select c.connection_id into v_tel1 from cma.upsert_connection('verifytel', 'Verify phones one', 'company-1', null, null) c;
    perform cma.set_connection_kind(v_tel1, 'telephony');
    select c.connection_id into v_x1 from cma.upsert_connection('verifyother', 'Verify other one', 'account-1', null, null) c;
    -- tenant two: a CRM connection of its own
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    select c.connection_id into v_c2 from cma.upsert_connection('verifycrm', 'Verify CRM two', 'portal-2', null, null) c;
    perform cma.set_connection_kind(v_c2, 'crm');

    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);

    -- B1. three tasks inserted; both catalogs seeded from the refs seen, with the given label or the ref
    --     as label and the defaults (is_done false, is_callback false, is_counted true)
    select string_agg(r.source_id || ':' || r.outcome, ',' order by r.source_id) into v_txt
    from cma.ingest_upsert_tasks(v_c1, jsonb_build_array(
      pg_temp.v8n_task('t-1', 'NOT_STARTED', 'CALL', '{"ownerRef": "o-1", "priorityRef": "HIGH", "contactId": "k-1", "dealId": "d-1", "statusLabel": "Not started"}'),
      pg_temp.v8n_task('t-2', 'COMPLETED', 'EMAIL', '{"ownerRef": "o-2", "completedAt": "2026-10-05T12:00:00Z", "ticketId": "x-1"}'),
      pg_temp.v8n_task('t-3', 'NOT_STARTED', 'CALL', '{"typeLabel": "Phone call"}'))) r;
    select string_agg(format('%s:%s:%s', s.status_ref, s.label, s.is_done), ' ' order by s.status_ref) into v_txt2
    from cma.connection_task_status s where s.connection_id = v_c1;
    select string_agg(format('%s:%s:%s:%s', y.type_ref, y.label, y.is_callback, y.is_counted), ' ' order by y.type_ref) into v_detail
    from cma.connection_task_type y where y.connection_id = v_c1;
    v_rows := v_rows || array['11', 'B1 three tasks inserted; both catalogs seeded with the defaults',
      case when v_txt = 't-1:inserted,t-2:inserted,t-3:inserted'
                and v_txt2 = 'COMPLETED:COMPLETED:f NOT_STARTED:Not started:f'
                and v_detail = 'CALL:CALL:f:t EMAIL:EMAIL:f:t' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | %s | %s', v_txt, v_txt2, v_detail)];

    -- B2. a newer read updates the status and the due time; an older read is stale and changes nothing
    select r.outcome into v_txt from cma.ingest_upsert_tasks(v_c1, jsonb_build_array(
      pg_temp.v8n_task('t-1', 'IN_PROGRESS', 'CALL', '{"updatedAt": "2026-10-05T10:00:00Z", "dueAt": "2026-10-07T10:00:00Z", "ownerRef": "o-1", "contactId": "k-1", "dealId": "d-1"}'))) r;
    select r.outcome into v_txt2 from cma.ingest_upsert_tasks(v_c1, jsonb_build_array(
      pg_temp.v8n_task('t-1', 'COMPLETED', 'CALL', '{"updatedAt": "2026-10-05T09:30:00Z"}'))) r;
    select format('%s:%s', k.status_ref, k.due_at at time zone 'UTC') into v_detail from cma.crm_task k where k.connection_id = v_c1 and k.source_id = 't-1';
    v_rows := v_rows || array['12', 'B2 a newer read updates, an older read is stale',
      case when v_txt = 'updated' and v_txt2 = 'stale' and v_detail = 'IN_PROGRESS:2026-10-07 10:00:00' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s %s %s', v_txt, v_txt2, v_detail)];

    -- B3. the strip: body, subject, notes, the connection's own subject key, a nested value, a string with
    --     an @ and a long string are dropped from raw; the structural keys stay; a body key refused on any
    --     path by the table's check (as the owner)
    perform cma.ingest_upsert_tasks(v_c1, jsonb_build_array(
      pg_temp.v8n_task('t-4', 'NOT_STARTED', 'CALL', jsonb_build_object('raw', jsonb_build_object(
        'hs_task_body', 'never stored', 'hs_task_subject', 'never stored', 'HS_Task_Notes', 'never', 'my_subject', 'never', 'description', 'never',
        'nested', jsonb_build_object('a', 1), 'mail', 'someone@example.invalid', 'long', repeat('x', 201),
        'hs_task_status', 'NOT_STARTED', 'hs_timestamp', '2026-10-06T10:00:00Z', 'hs_task_priority', 'LOW')))));
    select string_agg(k.key, ',' order by k.key) into v_txt from cma.crm_task t, jsonb_object_keys(t.raw) k(key)
    where t.connection_id = v_c1 and t.source_id = 't-4';
    perform set_config('role', 'cma_owner', true);
    v_txt2 := pg_temp.v8n_err(format('update cma.crm_task set raw = %L::jsonb where tenant_id = %L and connection_id = %L and source_id = %L',
                                     '{"hs_task_body": "x"}', v_t1, v_c1, 't-4'));
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['13', 'B3 the strip of body, subject, notes, the named key, nested, an @ and a long string; the check on raw',
      case when v_txt = 'hs_task_priority,hs_task_status,hs_timestamp' and v_txt2 = '23514' and not v_provoke then 'PASS' else 'FAIL' end,
      format('kept %s | direct body key %s', v_txt, v_txt2)];

    -- B4. configuration survives a read: is_done and a label set by a person, is_callback and is_counted
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_task_status(v_c1, 'COMPLETED', 'Done', true);
    perform cma.set_task_type(v_c1, 'CALL', 'Call back', true, false);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_tasks(v_c1, jsonb_build_array(
      pg_temp.v8n_task('t-5', 'COMPLETED', 'CALL', '{"statusLabel": "Completed", "typeLabel": "Call"}')));
    select format('%s:%s', s.label, s.is_done) into v_txt from cma.connection_task_status s where s.connection_id = v_c1 and s.status_ref = 'COMPLETED';
    select format('%s:%s:%s', y.label, y.is_callback, y.is_counted) into v_txt2 from cma.connection_task_type y where y.connection_id = v_c1 and y.type_ref = 'CALL';
    v_rows := v_rows || array['14', 'B4 is_done, is_callback, is_counted and the labels a person set survive a read',
      case when v_txt = 'Done:t' and v_txt2 = 'Call back:t:f' and not v_provoke then 'PASS' else 'FAIL' end, format('%s | %s', v_txt, v_txt2)];

    -- B5. associations are taken as the read gives them: a later read without the deal clears it, the
    --     contact stays as sent
    perform cma.ingest_upsert_tasks(v_c1, jsonb_build_array(
      pg_temp.v8n_task('t-1', 'IN_PROGRESS', 'CALL', '{"updatedAt": "2026-10-05T11:00:00Z", "contactId": "k-1", "ticketId": "x-9"}')));
    select format('%s:%s:%s', coalesce(k.contact_source_id, '-'), coalesce(k.deal_source_id, '-'), coalesce(k.ticket_source_id, '-')) into v_txt
    from cma.crm_task k where k.connection_id = v_c1 and k.source_id = 't-1';
    v_rows := v_rows || array['15', 'B5 associations as the read gives them: the deal cleared, the ticket set, the contact kept',
      case when v_txt = 'k-1:-:x-9' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. a deletion keeps the row with source_deleted_at; a deletion of an unknown task is unknown; a
    --     newer read brings the task back
    select r.outcome into v_txt from cma.ingest_upsert_tasks(v_c1, '[{"sourceId": "t-2", "deletedAt": "2026-10-06T08:00:00Z"}]') r;
    select r.outcome into v_txt2 from cma.ingest_upsert_tasks(v_c1, '[{"sourceId": "t-none", "deletedAt": "2026-10-06T08:00:00Z"}]') r;
    select (k.source_deleted_at is not null)::text into v_detail from cma.crm_task k where k.connection_id = v_c1 and k.source_id = 't-2';
    perform cma.ingest_upsert_tasks(v_c1, jsonb_build_array(pg_temp.v8n_task('t-2', 'COMPLETED', 'EMAIL', '{"updatedAt": "2026-10-06T09:00:00Z"}')));
    select v_detail || ':' || (k.source_deleted_at is null)::text into v_detail from cma.crm_task k where k.connection_id = v_c1 and k.source_id = 't-2';
    v_rows := v_rows || array['16', 'B6 deletion keeps the row, an unknown deletion is unknown, a newer read brings it back',
      case when v_txt = 'deleted' and v_txt2 = 'unknown' and v_detail = 'true:true' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s %s %s', v_txt, v_txt2, v_detail)];

    -- B7. a contact is held for a task alone: k-1 (a task points to it) is taken in, k-9 (nothing does) is not
    select string_agg(r.source_id || ':' || r.outcome, ',' order by r.source_id) into v_txt
    from cma.ingest_upsert_contacts(v_c1, '[{"sourceId": "k-1", "country": "NL", "updatedAt": "2026-10-05T09:00:00Z"},
                                            {"sourceId": "k-9", "country": "NL", "updatedAt": "2026-10-05T09:00:00Z"}]') r;
    v_rows := v_rows || array['17', 'B7 a contact is held while a task points to it, not otherwise',
      case when v_txt = 'k-1:inserted,k-9:not_held' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. the contact's privacy deletion clears the task's contact ref and says so
    v_res := cma.ingest_contact_forget(v_c1, 'k-1');
    select count(*)::integer into v_n from cma.crm_task k where k.connection_id = v_c1 and k.contact_source_id = 'k-1';
    v_rows := v_rows || array['18', 'B8 the privacy deletion clears the task''s contact and answers tasks',
      case when (v_res ->> 'tasks')::integer = 1 and (v_res ->> 'contacts')::integer = 1 and v_n = 0 and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s, %s tasks still point to the contact', v_res::text, v_n)];

    -- B9. tenant isolation: tenant two sees no task of tenant one, and its Ingest user cannot write into
    --     tenant one's connection; the owner sees both tenants
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    select count(*)::integer into v_n from cma.crm_task;
    v_txt := pg_temp.v8n_err(format('select cma.ingest_upsert_tasks(%L, %L::jsonb)', v_c1, jsonb_build_array(pg_temp.v8n_task('t-x', 'A', 'B'))));
    perform cma.ingest_upsert_tasks(v_c2, jsonb_build_array(pg_temp.v8n_task('t-1', 'OPEN', 'TODO')));
    select count(*)::integer into v_m from cma.crm_task;
    perform set_config('role', 'cma_owner', true);
    select v_m::text || ':' || count(*)::text into v_txt2 from cma.crm_task k where k.tenant_id in (v_t1, v_t2);
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['19', 'B9 tenant isolation: nothing of tenant one in tenant two, the other connection refused, the owner sees both',
      case when v_n = 0 and v_txt = 'CMA02' and v_txt2 = '1:6' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s %s %s', v_n, v_txt, v_txt2)];

    -- B10. configuration refusals: an agent (CMA06), a null switch (CMA04), a ref with a space (CMA04), an
    --      empty label (CMA04), an unknown connection (CMA02), a telephony connection (CMA04), the Ingest
    --      user configuring (CMA06), a configuring person ingesting (CMA06)
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := pg_temp.v8n_err(format('select cma.set_task_status(%L, %L, %L, true)', v_c1, 'NOT_STARTED', 'Open'));
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ',' || pg_temp.v8n_err(format('select cma.set_task_status(%L, %L, %L, null)', v_c1, 'NOT_STARTED', 'Open'))
      || ',' || pg_temp.v8n_err(format('select cma.set_task_type(%L, %L, %L, true, true)', v_c1, 'NOT A REF', 'Open'))
      || ',' || pg_temp.v8n_err(format('select cma.set_task_type(%L, %L, %L, true, true)', v_c1, 'CALL', ' '))
      || ',' || pg_temp.v8n_err(format('select cma.set_task_status(%L, %L, %L, true)', '00000000-0000-7000-8000-00000000dead', 'X', 'X'))
      || ',' || pg_temp.v8n_err(format('select cma.set_task_status(%L, %L, %L, true)', v_tel1, 'X', 'X'));
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ',' || pg_temp.v8n_err(format('select cma.set_task_type(%L, %L, %L, true, true)', v_c1, 'CALL', 'Call'));
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ',' || pg_temp.v8n_err(format('select cma.ingest_upsert_tasks(%L, %L::jsonb)', v_c1, jsonb_build_array(pg_temp.v8n_task('t-9', 'A', 'B'))));
    v_rows := v_rows || array['20', 'B10 eight configuration refusals',
      case when v_txt = 'CMA06,CMA04,CMA04,CMA04,CMA02,CMA04,CMA06,CMA06' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. the upsert's refusals: no sourceId, not an array, 501 items, a sourceId with an @, a new task
    --      without createdAt
    perform set_config('app.user_id', v_ing1::text, true);
    select jsonb_agg(pg_temp.v8n_task('t-m-' || i, 'A', 'B')) into v_items from generate_series(1, 501) i;
    v_txt := pg_temp.v8n_err(format('select cma.ingest_upsert_tasks(%L, %L::jsonb)', v_c1, '[{"statusRef": "A"}]'))
      || ',' || pg_temp.v8n_err(format('select cma.ingest_upsert_tasks(%L, %L::jsonb)', v_c1, '{"sourceId": "t-9"}'))
      || ',' || pg_temp.v8n_err(format('select cma.ingest_upsert_tasks(%L, %L::jsonb)', v_c1, v_items))
      || ',' || pg_temp.v8n_err(format('select cma.ingest_upsert_tasks(%L, %L::jsonb)', v_c1, jsonb_build_array(pg_temp.v8n_task('some@one', 'A', 'B'))))
      || ',' || pg_temp.v8n_err(format('select cma.ingest_upsert_tasks(%L, %L::jsonb)', v_c1, '[{"sourceId": "t-new", "statusRef": "A"}]'));
    v_rows := v_rows || array['21', 'B11 five refusals of the upsert',
      case when v_txt = 'CMA04,CMA04,CMA04,CMA04,CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B12. the Sources read: both catalogs with how many tasks carry each ref and how many are open, the
    --      newest task id; refused for an agent
    perform set_config('app.user_id', v_admin1::text, true);
    v_res := cma.connection_task_catalogs(v_c1);
    select string_agg(format('%s:%s:%s', x ->> 'statusRef', x ->> 'isDone', x ->> 'seenTasks'), ' ' order by x ->> 'statusRef') into v_txt
    from jsonb_array_elements(v_res -> 'statuses') x;
    select string_agg(format('%s:%s:%s:%s', x ->> 'typeRef', x ->> 'isCallback', x ->> 'seenTasks', x ->> 'openTasks'), ' ' order by x ->> 'typeRef') into v_txt2
    from jsonb_array_elements(v_res -> 'types') x;
    perform set_config('app.user_id', v_agent1::text, true);
    v_detail := pg_temp.v8n_err(format('select cma.connection_task_catalogs(%L)', v_c1));
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['22', 'B12 the Sources read: statuses and types with their counts, the newest task id; an agent refused',
      case when v_txt = 'COMPLETED:true:2 IN_PROGRESS:false:1 NOT_STARTED:false:2'
                and v_txt2 = 'CALL:true:4:3 EMAIL:false:1:0'
                and v_res ->> 'sampleTaskId' is not null and v_detail = 'CMA06' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | %s | sample %s | agent %s', v_txt, v_txt2, v_res ->> 'sampleTaskId', v_detail)];

    -- B13. task rows make a connection's kind crm: a task written into the connection without a kind, then
    --      telephony refused for it (CMA03), while a kind of its own stays settable to crm
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_tasks(v_x1, jsonb_build_array(pg_temp.v8n_task('t-1', 'OPEN', 'TODO')));
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := array_to_string(cma.connection_held_kinds_of(v_t1, v_x1), ',')
      || ' ' || pg_temp.v8n_err(format('select cma.set_connection_kind(%L, %L)', v_x1, 'telephony'))
      || ' ' || pg_temp.v8n_err(format('select cma.set_connection_kind(%L, %L)', v_x1, 'crm'));
    v_rows := v_rows || array['23', 'B13 task rows make a connection''s kind crm',
      case when v_txt = 'crm CMA03 ok' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B14. the reader view shows ids and refs only, for readers only, and nothing of tenant one to a
    --      reader scoped to tenant two
    perform set_config('role', 'cma_readonly', true);
    perform set_config('app.tenant_id', v_t2::text, true);
    select count(*)::integer into v_n from cma_read.crm_task where tenant_id = v_t1;
    select count(*)::integer into v_m from cma_read.crm_task where tenant_id = v_t2;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['24', 'B14 a reader scoped to tenant two sees its own task and none of tenant one',
      case when v_n = 0 and v_m = 1 and not v_provoke then 'PASS' else 'FAIL' end, format('%s of one, %s of two', v_n, v_m)];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008n (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008n values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008n
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008n where result = 'PASS') = 20
                       and not exists (select 1 from verify_0008n where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008n where result = 'PASS'),
                                        (select count(*) from verify_0008n where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v8n_err(text);
drop function if exists pg_temp.v8n_task(text, text, text, jsonb);
reset role;
