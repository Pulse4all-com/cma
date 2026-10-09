-- =============================================================================================
-- 31_verify_ingest_crm_records.sql: verifies migration 0006, ingest and CRM records
-- =============================================================================================
-- Block A checks structure and privileges; block B works on two throwaway tenants inside a
-- subtransaction that is always rolled back. Both universal: no seed is assumed. Cloud SQL Studio
-- shows no notices: a check that fails raises "FAIL …" and stops the script. The last result is
-- the verdict. Run as your own IAM login, dev and prod, after 30_ingest_crm_records.sql.
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict
-- (reached only when the run does not stop on errors) says PROVOKED instead of PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every block fail

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t       text;
  v_fn      text;
  v_n       int;
  v_cols    text;
begin
  -- A1. the migration is recorded
  if not exists (select 1 from cma.schema_migration where version = '0006') then
    raise exception 'FAIL A1: migration 0006 not recorded';
  end if;

  -- A2. eight tenant tables, each with row-level security, the tenant policy and the audit trigger
  foreach v_t in array array['integration_connection', 'connection_field', 'connection_pipeline', 'connection_stage',
                             'ingest_event', 'crm_record', 'crm_contact', 'crm_contact_ref'] loop
    if to_regclass('cma.' || v_t) is null then
      raise exception 'FAIL A2: table cma.% is missing', v_t;
    end if;
    if not (select relrowsecurity from pg_class where oid = to_regclass('cma.' || v_t))
       or not exists (select 1 from pg_policy where polrelid = to_regclass('cma.' || v_t) and polname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = to_regclass('cma.' || v_t) and tgname = 'audit')
       or (v_provoke and v_t = 'crm_record') then
      raise exception 'FAIL A2: cma.% lacks row-level security, its tenant policy or its audit trigger', v_t;
    end if;
  end loop;

  -- A3. the app writes but never deletes, except the mapping rows and contact refs
  foreach v_t in array array['integration_connection', 'connection_pipeline', 'connection_stage',
                             'ingest_event', 'crm_record', 'crm_contact'] loop
    if has_table_privilege('cma_app', 'cma.' || v_t, 'delete') or not has_table_privilege('cma_app', 'cma.' || v_t, 'insert') then
      raise exception 'FAIL A3: cma_app must insert into and never delete from cma.%', v_t;
    end if;
  end loop;
  if not has_table_privilege('cma_app', 'cma.connection_field', 'delete') or not has_table_privilege('cma_app', 'cma.crm_contact_ref', 'delete') then
    raise exception 'FAIL A3: cma_app must be able to remove a field mapping and a contact ref';
  end if;

  -- A4. the functions: the app may execute them, readers and public may not; only the
  --     connection lookup runs as its owner
  foreach v_fn in array array[
    'cma.ingest_connection(text)',
    'cma.ingest_record_events(uuid,jsonb)', 'cma.ingest_claim_events(uuid,uuid[],integer)',
    'cma.ingest_finish_events(uuid,uuid[],text,text)', 'cma.ingest_upsert_records(uuid,jsonb)',
    'cma.ingest_upsert_contacts(uuid,jsonb)', 'cma.ingest_upsert_pipelines(uuid,jsonb)',
    'cma.ingest_records_without_contact(uuid,interval)',
    'cma.upsert_connection(text,text,text,text,text)', 'cma.set_connection_status(uuid,text)',
    'cma.set_connection_field(uuid,text,text,text,text)', 'cma.set_connection_pipeline(uuid,text,text,boolean,boolean,text)',
    'cma.connection_config(uuid)', 'cma.connections_all()', 'cma.crm_records_per_day(date,date)'
  ] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A4: % does not exist', v_fn;
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute')
       or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      raise exception 'FAIL A4: execute on % must be granted to cma_app only', v_fn;
    end if;
    if (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) <> (v_fn = 'cma.ingest_connection(text)') then
      raise exception 'FAIL A4: % runs with the wrong rights (only ingest_connection is security definer)', v_fn;
    end if;
  end loop;
  if (select array_to_string(proconfig, ',') from pg_proc where oid = 'cma.ingest_connection(text)'::regprocedure)
     is distinct from 'search_path=pg_catalog, cma' then
    raise exception 'FAIL A4: ingest_connection must pin its search_path';
  end if;

  -- A5. every active tenant has exactly one active Ingest user: system kind, the non-assignable
  --     role ingest holding only ingest.write, the login (ingest, ingest), no clock; and no
  --     assignable role holds ingest.write
  select count(*) into v_n from cma.tenant t
  where t.status = 'active'
    and 1 <> (select count(*) from cma.app_user u
              join cma.app_user_external_id x on x.tenant_id = u.tenant_id and x.user_id = u.id
              where u.tenant_id = t.id and u.kind = 'system' and u.status = 'active'
                and x.system = 'ingest' and x.external_id = 'ingest');
  if v_n <> 0 then
    raise exception 'FAIL A5: % tenant(s) without exactly one active Ingest user', v_n;
  end if;
  select count(*) into v_n from cma.app_user u
  where u.email = 'ingest@system.invalid'
    and (u.kind <> 'system' or cma.time_is_kept(u.id)
         or not exists (select 1 from cma.user_role ur join cma.app_role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                        where ur.tenant_id = u.tenant_id and ur.user_id = u.id and r.key = 'ingest' and r.is_system and not r.is_assignable));
  if v_n <> 0 then
    raise exception 'FAIL A5: % Ingest user(s) not a system user, with a clock, or without the ingest role', v_n;
  end if;
  select count(*) into v_n from cma.app_role r
  where (r.key = 'ingest'
         and (select string_agg(rp.permission_key, ',') from cma.role_permission rp where rp.tenant_id = r.tenant_id and rp.role_id = r.id) is distinct from 'ingest.write')
     or (r.is_assignable and exists (select 1 from cma.role_permission rp where rp.tenant_id = r.tenant_id and rp.role_id = r.id and rp.permission_key = 'ingest.write'));
  if v_n <> 0 then
    raise exception 'FAIL A5: % role(s) with ingest.write beside the ingest role, or an ingest role with more', v_n;
  end if;

  -- A6. reporting views: no raw payload and no secret names; readers see views, never tables
  select string_agg(column_name, ', ' order by ordinal_position) into v_cols
  from information_schema.columns where table_schema = 'cma_read' and table_name = 'crm_record';
  if v_cols is distinct from 'id, tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref, contact_source_id, market, language, is_closed, closed_at, source_created_at, source_updated_at, source_deleted_at, synced_at' then
    raise exception 'FAIL A6: cma_read.crm_record exposes [%]', v_cols;
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'cma_read'
             and ((table_name in ('ingest_event', 'crm_contact') and column_name = 'raw')
                  or (table_name = 'integration_connection' and column_name in ('key', 'signing_secret_name', 'token_secret_name')))) then
    raise exception 'FAIL A6: a reporting view exposes a raw payload, the connection key or a secret name';
  end if;
  foreach v_t in array array['integration_connection', 'connection_pipeline', 'connection_stage', 'ingest_event',
                             'crm_record', 'crm_contact', 'crm_contact_ref'] loop
    if not has_table_privilege('cma_readonly', 'cma_read.' || v_t, 'select') or has_table_privilege('cma_readonly', 'cma.' || v_t, 'select') then
      raise exception 'FAIL A6: readers must see cma_read.% and not cma.%', v_t, v_t;
    end if;
  end loop;

  -- A7. the setting
  if not exists (select 1 from cma.setting where key = 'ingest.max_attempts' and value_type = 'integer' and default_value = '10') then
    raise exception 'FAIL A7: setting ingest.max_attempts (integer, default 10) missing';
  end if;
end
$$;

-- B. Behaviour (universal, throwaway tenants, rolled back)
--    Tenant one (zone UTC): an admin, an analyst, an agent, a work type, a connection with field
--    mapping and pipelines, events, records and contacts written by its Ingest user. Tenant two:
--    its own Ingest user and connection, to prove isolation.
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_analyst  uuid;
  v_agent    uuid;
  v_ing1     uuid;
  v_ing2     uuid;
  v_c1       uuid;
  v_c2       uuid;
  v_key      text;
  v_key2     text;
  v_id       uuid;
  v_ids      uuid[];
  v_n        int;
  v_n2       int;
  v_cfg      jsonb;
  v_txt      text;
  v_t0       timestamptz := now() - interval '3 hours';
  v_t1time   timestamptz := now() - interval '2 hours';
  v_t2time   timestamptz := now() - interval '1 hour';
  r          record;
begin
  begin
    -- Setup as owner
    v_t1 := cma.create_tenant('verify-0006-one', 'Verify 0006 one', 'UTC');
    v_t2 := cma.create_tenant('verify-0006-two', 'Verify 0006 two', 'UTC');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst@example.invalid', 'Verify analyst') returning id into v_analyst;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_admin, 'admin'), (v_analyst, 'analytics'), (v_agent, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.skill (tenant_id, dimension, key, name) values (v_t1, 'work_type', 'verify-sales', 'Verify sales');
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    select id into v_ing2 from cma.app_user where tenant_id = v_t2 and email = 'ingest@system.invalid';
    if v_ing1 is null or v_ing2 is null then
      raise exception 'FAIL B0: create_tenant did not seed the Ingest user';
    end if;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verify_crm', 'Verify two', '222') returning id, key into v_c2, v_key2;

    -- From here on as the application
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);

    -- B1. the admin adds a connection; the same adapter and account again gives the same id and
    --     key; an agent may not
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id, c.key into v_c1, v_key
    from cma.upsert_connection('verify_crm', 'Verify one', '111', 'verify-signing', 'verify-token') c;
    select c.connection_id into v_id from cma.upsert_connection('verify_crm', 'Verify one renamed', '111', 'verify-signing', 'verify-token') c;
    if v_c1 is null or v_id <> v_c1 or v_key !~ '^[0-9a-f]{32}$' or v_provoke then
      raise exception 'FAIL B1: upsert_connection gave % then % with key %', v_c1, v_id, v_key;
    end if;
    perform set_config('app.user_id', v_agent::text, true);
    begin
      perform cma.upsert_connection('verify_crm', 'Verify agent', '999', null, null);
      raise exception 'FAIL B1: an agent added a connection';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B2. the field mapping: allowed pairs, refused pairs, removal by an empty property
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_connection_field(v_c1, 'deal', 'market', null, 'verify_market');
    perform cma.set_connection_field(v_c1, 'deal', 'language', null, 'verify_language');
    perform cma.set_connection_field(v_c1, 'contact', 'country', null, 'country');
    perform cma.set_connection_field(v_c1, 'contact', 'ref', 'verify_shop', 'verify_shop_id');
    perform cma.set_connection_field(v_c1, 'deal', 'language', null, '');
    begin
      perform cma.set_connection_field(v_c1, 'deal', 'country', null, 'country');
      raise exception 'FAIL B2: a record took a contact field';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.set_connection_field(v_c1, 'contact', 'ref', null, 'verify_shop_id');
      raise exception 'FAIL B2: a ref without its system was accepted';
    exception when sqlstate 'CMA04' then null;
    end;

    -- B3. pipelines: a work type that is not one is refused; the routed sales pipeline is mapped
    begin
      perform cma.set_connection_pipeline(v_c1, 'deal', 'p-sales', true, true, 'no-such-work-type');
      raise exception 'FAIL B3: an unknown work type was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    perform cma.set_connection_pipeline(v_c1, 'deal', 'p-sales', true, true, 'verify-sales');
    v_cfg := cma.connection_config(v_c1);
    if jsonb_array_length(v_cfg -> 'fields') <> 3
       or (v_cfg -> 'pipelines' -> 0 ->> 'workType') is distinct from 'verify-sales'
       or (v_cfg -> 'pipelines' -> 0 ->> 'isRouted') is distinct from 'true' then
      raise exception 'FAIL B3: connection_config is %', v_cfg;
    end if;

    -- B4. the lookup by key, before a tenant is known: the tenant, the connection, the secret
    --     names and the Ingest user; nothing for an unknown key or an inactive connection
    perform set_config('app.tenant_id', '', true);
    perform set_config('app.user_id', '', true);
    select * into r from cma.ingest_connection(v_key);
    if r.tenant_id is distinct from v_t1 or r.connection_id <> v_c1 or r.ingest_user_id <> v_ing1
       or r.signing_secret_name <> 'verify-signing' or r.external_account_id <> '111' then
      raise exception 'FAIL B4: ingest_connection answered (%, %, %)', r.tenant_id, r.connection_id, r.ingest_user_id;
    end if;
    if exists (select 1 from cma.ingest_connection('no-such-key-0000000000000000')) then
      raise exception 'FAIL B4: an unknown key found a connection';
    end if;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_connection_status(v_c1, 'inactive');
    if exists (select 1 from cma.ingest_connection(v_key)) then
      raise exception 'FAIL B4: an inactive connection was found';
    end if;
    perform cma.set_connection_status(v_c1, 'active');

    -- B5. events: three new; a resend of two with one new gives the old ids; an unknown kind is
    --     refused; an admin may not write events (ingest.write is the Ingest user's alone)
    perform set_config('app.user_id', v_ing1::text, true);
    select count(*) filter (where e.is_new) into v_n
    from cma.ingest_record_events(v_c1, jsonb_build_array(
      jsonb_build_object('key', 'k1', 'sourceType', 'deal.creation', 'kind', 'created', 'objectType', 'deal', 'objectId', 'd1', 'occurredAt', v_t0),
      jsonb_build_object('key', 'k2', 'sourceType', 'deal.creation', 'kind', 'created', 'objectType', 'deal', 'objectId', 'd2', 'occurredAt', v_t0),
      jsonb_build_object('key', 'k3', 'sourceType', 'deal.propertyChange', 'kind', 'changed', 'objectType', 'deal', 'objectId', 'd1',
                         'propertyName', 'dealstage', 'occurredAt', v_t1time, 'attempt', 2, 'raw', jsonb_build_object('objectId', 'd1')))) e;
    select count(*) filter (where e.is_new), count(*) filter (where not e.is_new) into v_n, v_n2
    from cma.ingest_record_events(v_c1, jsonb_build_array(
      jsonb_build_object('key', 'k1', 'sourceType', 'deal.creation', 'kind', 'created', 'objectType', 'deal', 'objectId', 'd1', 'occurredAt', v_t0),
      jsonb_build_object('key', 'k2', 'sourceType', 'deal.creation', 'kind', 'created', 'objectType', 'deal', 'objectId', 'd2', 'occurredAt', v_t0),
      jsonb_build_object('key', 'k4', 'sourceType', 'ticket.creation', 'kind', 'created', 'objectType', 'ticket', 'objectId', 't1', 'occurredAt', v_t0))) e;
    if v_n <> 1 or v_n2 <> 2 or (select count(*) from cma.ingest_event where connection_id = v_c1) <> 4 then
      raise exception 'FAIL B5: the resend wrote % new and % known, % in the log', v_n, v_n2,
        (select count(*) from cma.ingest_event where connection_id = v_c1);
    end if;
    begin
      perform cma.ingest_record_events(v_c1, jsonb_build_array(
        jsonb_build_object('key', 'k5', 'sourceType', 'deal.x', 'kind', 'exploded', 'objectType', 'deal', 'objectId', 'd1')));
      raise exception 'FAIL B5: an unknown kind was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    perform set_config('app.user_id', v_admin::text, true);
    begin
      perform cma.ingest_record_events(v_c1, '[]'::jsonb);
      raise exception 'FAIL B5: an admin wrote events';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B6. claim and finish: four claimed with one attempt each, none claimable again at once;
    --     processed, ignored and failed; a failure at ingest.max_attempts parks the event; a
    --     finished event does not reopen
    perform set_config('app.user_id', v_ing1::text, true);
    select array_agg(c.event_id order by c.event_id), count(*) filter (where c.attempts = 1) into v_ids, v_n
    from cma.ingest_claim_events(v_c1) c;
    if cardinality(v_ids) <> 4 or v_n <> 4 or exists (select 1 from cma.ingest_claim_events(v_c1)) then
      raise exception 'FAIL B6: claimed % events (% at one attempt), or claimed again at once', cardinality(v_ids), v_n;
    end if;
    if cma.ingest_finish_events(v_c1, v_ids[1:2], 'processed') <> 2
       or cma.ingest_finish_events(v_c1, v_ids[3:3], 'ignored') <> 1
       or cma.ingest_finish_events(v_c1, v_ids[4:4], 'failed', 'verify_error') <> 1
       or cma.ingest_finish_events(v_c1, v_ids[1:1], 'failed', 'verify_error') <> 0 then
      raise exception 'FAIL B6: finishing changed the wrong number of events';
    end if;
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t1, 'ingest.max_attempts', '2');
    update cma.ingest_event set next_attempt_at = now() - interval '1 second' where id = v_ids[4];
    perform 1 from cma.ingest_claim_events(v_c1, array[v_ids[4]]);
    perform cma.ingest_finish_events(v_c1, v_ids[4:4], 'failed', 'verify_error');
    if (select status from cma.ingest_event where id = v_ids[4]) <> 'needs_review'
       or (select status from cma.ingest_event where id = v_ids[1]) <> 'processed' then
      raise exception 'FAIL B6: after two failures the event is %',
        (select status from cma.ingest_event where id = v_ids[4]);
    end if;

    -- B7. pipelines from the source: the routed pipeline keeps its settings, stages arrive with
    --     their closed flags
    perform cma.ingest_upsert_pipelines(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'pipelineId', 'p-sales', 'label', 'Sales', 'stages', jsonb_build_array(
        jsonb_build_object('stageId', 's-open', 'label', 'Open', 'order', 1, 'isClosed', false),
        jsonb_build_object('stageId', 's-won', 'label', 'Won', 'order', 2, 'isClosed', true))),
      jsonb_build_object('recordType', 'ticket', 'pipelineId', 'p-support', 'label', 'Support', 'stages', jsonb_build_array(
        jsonb_build_object('stageId', 's-new', 'label', 'New', 'order', 1, 'isClosed', false),
        jsonb_build_object('stageId', 's-closed', 'label', 'Closed', 'order', 2, 'isClosed', true)))));
    select count(*) into v_n from cma.connection_pipeline
    where connection_id = v_c1 and source_pipeline_id = 'p-sales' and label = 'Sales' and is_routed and work_type_skill_id is not null;
    if v_n <> 1 or (select count(*) from cma.connection_stage where connection_id = v_c1) <> 4 then
      raise exception 'FAIL B7: the refresh lost the pipeline''s settings or its stages';
    end if;

    -- B8. records: inserted with the stage's closed flag (null for an unknown stage); an older
    --     read is stale; a newer one closes the deal; delete, unknown delete, restore
    select count(*) filter (where u.outcome = 'inserted') into v_n
    from cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'pipelineId', 'p-sales', 'stageId', 's-open', 'ownerRef', 'o1',
                         'contactId', 'c1', 'market', 'nl', 'createdAt', v_t0, 'updatedAt', v_t1time),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd2', 'pipelineId', 'p-sales', 'stageId', 's-mystery',
                         'market', 'de', 'createdAt', v_t0, 'updatedAt', v_t1time),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 't1', 'pipelineId', 'p-support', 'stageId', 's-closed',
                         'contactId', 'c1', 'market', 'nl', 'createdAt', v_t0, 'updatedAt', v_t1time))) u;
    if v_n <> 3
       or (select is_closed from cma.crm_record where connection_id = v_c1 and source_id = 'd1') is distinct from false
       or (select is_closed from cma.crm_record where connection_id = v_c1 and source_id = 'd2') is not null
       or (select closed_at is null or not is_closed from cma.crm_record where connection_id = v_c1 and source_id = 't1')
       or (select source_system from cma.crm_record where connection_id = v_c1 and source_id = 'd1') <> 'verify_crm' then
      raise exception 'FAIL B8: the first records are wrong';
    end if;
    select u.outcome into r from cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'pipelineId', 'p-sales', 'stageId', 's-open',
                         'market', 'xx', 'createdAt', v_t0, 'updatedAt', v_t0))) u;
    if r.outcome <> 'stale' or (select market from cma.crm_record where connection_id = v_c1 and source_id = 'd1') <> 'nl' then
      raise exception 'FAIL B8: an older read was not stale';
    end if;
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'pipelineId', 'p-sales', 'stageId', 's-won', 'ownerRef', 'o2',
                         'market', 'nl', 'createdAt', v_t0, 'updatedAt', v_t2time)));
    select * into r from cma.crm_record where connection_id = v_c1 and source_id = 'd1';
    if not r.is_closed or r.closed_at is null or r.owner_ref <> 'o2' or r.contact_source_id <> 'c1' then
      raise exception 'FAIL B8: the newer read gave closed %, owner %, contact %', r.is_closed, r.owner_ref, r.contact_source_id;
    end if;
    select string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd2', 'deletedAt', v_t2time),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd9', 'deletedAt', v_t2time))) u;
    if v_txt is distinct from 'deleted,unknown'
       or (select source_deleted_at from cma.crm_record where connection_id = v_c1 and source_id = 'd2') is null
       or exists (select 1 from cma.crm_record where connection_id = v_c1 and source_id = 'd9') then
      raise exception 'FAIL B8: delete and unknown delete gave %', v_txt;
    end if;

    -- B9. a pipeline refresh that names the unknown stage closes the record that stood in it
    v_n := cma.ingest_upsert_pipelines(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'pipelineId', 'p-sales', 'label', 'Sales', 'stages', jsonb_build_array(
        jsonb_build_object('stageId', 's-open', 'label', 'Open', 'order', 1, 'isClosed', false),
        jsonb_build_object('stageId', 's-won', 'label', 'Won', 'order', 2, 'isClosed', true),
        jsonb_build_object('stageId', 's-mystery', 'label', 'Lost', 'order', 3, 'isClosed', true)))));
    if v_n <> 1 or (select is_closed from cma.crm_record where connection_id = v_c1 and source_id = 'd2') is not true then
      raise exception 'FAIL B9: the refresh changed % records', v_n;
    end if;

    -- B10. contacts: one a record points to is taken in with its ref, one nobody points to is not;
    --      an older read is stale; a null ref removes it; a deleted contact loses its attributes
    select string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_contacts(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'c1', 'country', 'NL', 'language', 'nl', 'refs', jsonb_build_object('verify_shop', '123'), 'updatedAt', v_t1time),
      jsonb_build_object('sourceId', 'c9', 'country', 'SE', 'updatedAt', v_t1time))) u;
    if v_txt is distinct from 'inserted,not_held'
       or (select x.external_id from cma.crm_contact_ref x join cma.crm_contact c on c.id = x.contact_id
           where c.source_id = 'c1' and x.system = 'verify_shop') is distinct from '123' then
      raise exception 'FAIL B10: contacts gave %', v_txt;
    end if;
    if (select u.outcome from cma.ingest_upsert_contacts(v_c1, jsonb_build_array(
          jsonb_build_object('sourceId', 'c1', 'country', 'BE', 'updatedAt', v_t0))) u) <> 'stale' then
      raise exception 'FAIL B10: an older contact read was not stale';
    end if;
    perform cma.ingest_upsert_contacts(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'c1', 'country', 'NL', 'language', 'nl', 'refs', jsonb_build_object('verify_shop', null), 'updatedAt', v_t2time)));
    if exists (select 1 from cma.crm_contact_ref) then
      raise exception 'FAIL B10: a null ref was not removed';
    end if;
    perform cma.ingest_upsert_contacts(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'c1', 'refs', jsonb_build_object('verify_shop', '456'), 'updatedAt', now())));
    perform cma.ingest_upsert_contacts(v_c1, jsonb_build_array(jsonb_build_object('sourceId', 'c1', 'deletedAt', now())));
    select * into r from cma.crm_contact where connection_id = v_c1 and source_id = 'c1';
    if r.country is not null or r.language is not null or r.source_deleted_at is null or exists (select 1 from cma.crm_contact_ref) then
      raise exception 'FAIL B10: a deleted contact kept country %, language % or a ref', r.country, r.language;
    end if;

    -- B11. records without a contact: the deleted d2 is not listed; a new deal without one is
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd3', 'pipelineId', 'p-sales', 'stageId', 's-open',
                         'market', 'se', 'createdAt', now(), 'updatedAt', now())));
    if (select string_agg(w.source_id, ',') from cma.ingest_records_without_contact(v_c1) w) is distinct from 'd3' then
      raise exception 'FAIL B11: without contact lists %', (select string_agg(w.source_id, ',') from cma.ingest_records_without_contact(v_c1) w);
    end if;

    -- B12. the Dashboard read: counted pipelines only, deleted left out, per market; the support
    --      pipeline taken out of counting disappears; the range is bounded; an agent may not read
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_connection_pipeline(v_c1, 'ticket', 'p-support', false, false, null);
    perform set_config('app.user_id', v_analyst::text, true);
    select coalesce(sum(d.records), 0), coalesce(sum(d.closed_now), 0) into v_n, v_n2
    from cma.crm_records_per_day(current_date - 1, current_date) d;
    if v_n <> 2 or v_n2 <> 1
       or (select string_agg(d.market || ':' || d.records, ',' order by d.market) from cma.crm_records_per_day(current_date - 1, current_date) d)
          is distinct from 'nl:1,se:1' then
      raise exception 'FAIL B12: the Dashboard read counted % records (% closed)', v_n, v_n2;
    end if;
    begin
      perform cma.crm_records_per_day(current_date - 100, current_date);
      raise exception 'FAIL B12: a range of 101 days was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    perform set_config('app.user_id', v_agent::text, true);
    begin
      perform cma.crm_records_per_day(current_date, current_date);
      raise exception 'FAIL B12: an agent read the Dashboard counts';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B13. tenant isolation: tenant two's Ingest user cannot write to tenant one's connection and
    --      sees none of its rows
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    begin
      perform cma.ingest_upsert_records(v_c1, '[]'::jsonb);
      raise exception 'FAIL B13: tenant two wrote to tenant one''s connection';
    exception when sqlstate 'CMA02' then null;
    end;
    if exists (select 1 from cma.crm_record) or exists (select 1 from cma.ingest_event) or exists (select 1 from cma.crm_contact) then
      raise exception 'FAIL B13: tenant two sees tenant one''s rows';
    end if;
    perform cma.ingest_record_events(v_c2, jsonb_build_array(
      jsonb_build_object('key', 'k1', 'sourceType', 'deal.creation', 'kind', 'created', 'objectType', 'deal', 'objectId', 'd1', 'occurredAt', v_t0)));
    if (select count(*) from cma.ingest_event) <> 1 then
      raise exception 'FAIL B13: the same event key in another tenant was not its own event';
    end if;

    -- B14. the Ingest user and its role are out of the application's reach; no deletes
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    begin
      update cma.app_user set display_name = 'Renamed' where id = v_ing1;
      raise exception 'FAIL B14: the application edited the Ingest user';
    exception when sqlstate 'CMA06' then null;
    end;
    begin
      insert into cma.user_role (tenant_id, user_id, role_id)
      select v_t1, v_agent, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'ingest';
      raise exception 'FAIL B14: the ingest role was granted to a person';
    exception when sqlstate 'CMA06' then null;
    end;
    begin
      delete from cma.crm_record where connection_id = v_c1;
      raise exception 'FAIL B14: the application deleted records';
    exception when insufficient_privilege then null;
    end;

    -- B15. no acting user: refused
    perform set_config('app.user_id', '', true);
    begin
      perform cma.ingest_record_events(v_c1, '[]'::jsonb);
      raise exception 'FAIL B15: events were written without an acting user';
    exception when sqlstate 'CMA01' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the Ingest user and what has arrived so far
select t.slug as tenant,
       (select count(*) from cma.app_user u where u.tenant_id = t.id and u.email = 'ingest@system.invalid' and u.status = 'active') as ingest_users,
       (select count(*) from cma.integration_connection c where c.tenant_id = t.id and c.status = 'active') as connections,
       (select count(*) from cma.ingest_event e where e.tenant_id = t.id) as events,
       (select count(*) from cma.ingest_event e where e.tenant_id = t.id and e.status = 'needs_review') as needs_review,
       (select count(*) from cma.crm_record r where r.tenant_id = t.id) as records,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
