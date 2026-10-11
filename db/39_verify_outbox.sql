-- =============================================================================================
-- 39_verify_outbox.sql: verifies migration 0007c, outbox and CRM contact write-back
-- =============================================================================================
-- Block A checks structure and privileges; blocks B to F each work on throwaway tenants inside a
-- subtransaction that is always rolled back. All universal: no seed is assumed. Cloud SQL Studio
-- shows no notices: a check that fails raises "FAIL …" and stops the block. The last result is the
-- verdict. Run as your own IAM login, dev and prod, after 38_outbox.sql; then
-- 37_verify_commerce.sql, 33_verify_intake_core.sql and 31_verify_ingest_crm_records.sql again.
--   A  structure and privileges: tables, RLS, audit, no deletes, the outbox's state columns only,
--      keys, functions, views without the dedupe hash, the setting, the state trigger, SKIP LOCKED
--   B  write-back fields: set and updated in place, disabled not removed, slot and the slot mode for
--      commerce_ref only, one field per property, the refusals, the fields in connection_config
--   C  enqueue: enabled fields only, unknown fields and bad values refused, null when nothing is
--      left, dedupe on an identical payload, a newer action supersedes older pending ones per
--      contact, a sent one untouched, the same payload again after another one, inactive connection
--   D  claim and finish: one claim per action, the backoff, a dead claim returning, no claim while
--      the same contact is in flight, an overtaken claim superseded, failed actions superseded,
--      parking at outbox.max_attempts (after a failure and after an expired claim), a sent action
--      never reopens (functions, the trigger, the column grants), the refusals
--   E  resolve and status: retry and drop recording the person, the refusals (a newer action
--      blocks a retry), outbox_status per connection and state and who may read it
--   F  permissions (configuration versus ingest), tenant isolation for both tables, no deletes
-- A second session's claim (SKIP LOCKED with a claim held open) cannot be shown from one Studio
-- session; block A proves the claim locks with SKIP LOCKED, and the local run records the
-- two-session test (docs/night-2026-10-10/local-records/0007c/).
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
  if not exists (select 1 from cma.schema_migration where version = '0007c') or v_provoke then
    raise exception 'FAIL A1: migration 0007c not recorded';
  end if;

  -- A2. two tenant tables, each with row-level security, the tenant policy and the audit trigger
  foreach v_t in array array['writeback_field', 'outbox_action'] loop
    if to_regclass('cma.' || v_t) is null then
      raise exception 'FAIL A2: table cma.% is missing', v_t;
    end if;
    if not (select relrowsecurity from pg_class where oid = to_regclass('cma.' || v_t))
       or not exists (select 1 from pg_policy where polrelid = to_regclass('cma.' || v_t) and polname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = to_regclass('cma.' || v_t) and tgname = 'audit') then
      raise exception 'FAIL A2: cma.% lacks row-level security, its tenant policy or its audit trigger', v_t;
    end if;
  end loop;

  -- A3. the app inserts into both and never deletes; it updates write-back fields, and of an outbox
  --     action only the state columns (never what the action asks for)
  foreach v_t in array array['writeback_field', 'outbox_action'] loop
    if has_table_privilege('cma_app', 'cma.' || v_t, 'delete') or not has_table_privilege('cma_app', 'cma.' || v_t, 'insert') then
      raise exception 'FAIL A3: cma_app must insert into, and never delete from, cma.%', v_t;
    end if;
  end loop;
  if not has_table_privilege('cma_app', 'cma.writeback_field', 'update')
     or has_table_privilege('cma_app', 'cma.outbox_action', 'update') then
    raise exception 'FAIL A3: cma_app must update write-back fields, and outbox actions by column only';
  end if;
  select count(*) into v_n from unnest(array['dedupe_key', 'status', 'attempts', 'next_attempt_at', 'claimed_at', 'sent_at',
                                             'result', 'error', 'resolved_by', 'resolved_at']) c
  where has_column_privilege('cma_app', 'cma.outbox_action', c, 'update');
  if v_n <> 10 then
    raise exception 'FAIL A3: cma_app may update % of the 10 state columns of an outbox action', v_n;
  end if;
  select string_agg(c, ', ') into v_cols
  from unnest(array['id', 'tenant_id', 'connection_id', 'action', 'target_type', 'target_id', 'payload', 'reason',
                    'created_by', 'created_at']) c
  where has_column_privilege('cma_app', 'cma.outbox_action', c, 'update');
  if v_cols is not null then
    raise exception 'FAIL A3: cma_app may update % of an outbox action', v_cols;
  end if;

  -- A4. the keys: a field per connection and slot, a property written by one field, one action per
  --     dedupe key, both tied to a connection of the tenant
  select count(*) into v_n from pg_constraint c
  where c.contype in ('u', 'f', 'p')
    and ((c.conrelid = 'cma.writeback_field'::regclass
          and pg_get_constraintdef(c.oid) in ('PRIMARY KEY (tenant_id, connection_id, field, slot)',
                                              'UNIQUE (tenant_id, connection_id, target_property)',
                                              'FOREIGN KEY (tenant_id, connection_id) REFERENCES integration_connection(tenant_id, id)',
                                              'FOREIGN KEY (tenant_id, connection_id) REFERENCES cma.integration_connection(tenant_id, id)'))
      or (c.conrelid = 'cma.outbox_action'::regclass
          and pg_get_constraintdef(c.oid) in ('UNIQUE (tenant_id, dedupe_key)',
                                              'FOREIGN KEY (tenant_id, connection_id) REFERENCES integration_connection(tenant_id, id)',
                                              'FOREIGN KEY (tenant_id, connection_id) REFERENCES cma.integration_connection(tenant_id, id)',
                                              'FOREIGN KEY (tenant_id, created_by) REFERENCES app_user(tenant_id, id)',
                                              'FOREIGN KEY (tenant_id, created_by) REFERENCES cma.app_user(tenant_id, id)',
                                              'FOREIGN KEY (tenant_id, resolved_by) REFERENCES app_user(tenant_id, id)',
                                              'FOREIGN KEY (tenant_id, resolved_by) REFERENCES cma.app_user(tenant_id, id)')));
  if v_n <> 7 then
    raise exception 'FAIL A4: % of 7 keys on the outbox tables', v_n;
  end if;

  -- A5. the functions: the app may execute them, readers and public may not; none runs as its owner
  foreach v_fn in array array[
    'cma.set_writeback_field(uuid,text,text,text,boolean,smallint)', 'cma.outbox_resolve(uuid,text)', 'cma.outbox_status()',
    'cma.connection_config(uuid)', 'cma.enqueue_contact_writeback(uuid,text,jsonb,text)', 'cma.outbox_claim(uuid,integer)',
    'cma.outbox_finish(uuid[],text,jsonb,text)', 'cma.check_outbox_action()'
  ] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A5: % does not exist', v_fn;
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute')
       or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      raise exception 'FAIL A5: execute on % must be granted to cma_app only', v_fn;
    end if;
    if (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      raise exception 'FAIL A5: % must run with the caller''s rights', v_fn;
    end if;
  end loop;

  -- A6. reporting views: readers see each view and never the table; no dedupe hash, raw payload,
  --     key or secret; the outbox view's exact columns (payload included: ids, counts, codes)
  foreach v_t in array array['writeback_field', 'outbox_action'] loop
    if not has_table_privilege('cma_readonly', 'cma_read.' || v_t, 'select') or has_table_privilege('cma_readonly', 'cma.' || v_t, 'select') then
      raise exception 'FAIL A6: readers must see cma_read.% and not cma.%', v_t, v_t;
    end if;
  end loop;
  select string_agg(table_name || '.' || column_name, ', ') into v_cols
  from information_schema.columns
  where table_schema = 'cma_read' and table_name in ('writeback_field', 'outbox_action')
    and (column_name in ('raw', 'key', 'settings', 'dedupe_key') or column_name like '%hash%' or column_name like '%secret%'
         or column_name like '%token%' or column_name like '%email%' or column_name like '%phone%');
  if v_cols is not null then
    raise exception 'FAIL A6: reporting views expose %', v_cols;
  end if;
  select string_agg(column_name, ', ' order by ordinal_position) into v_cols
  from information_schema.columns where table_schema = 'cma_read' and table_name = 'outbox_action';
  if v_cols is distinct from 'id, tenant_id, connection_id, action, target_type, target_id, payload, reason, status, attempts, next_attempt_at, claimed_at, sent_at, result, error, created_by, created_at, resolved_by, resolved_at' then
    raise exception 'FAIL A6: cma_read.outbox_action exposes [%]', v_cols;
  end if;

  -- A7. the setting outbox.max_attempts, an integer with default 8
  if not exists (select 1 from cma.setting where key = 'outbox.max_attempts' and value_type = 'integer' and default_value = '8') then
    raise exception 'FAIL A7: the setting outbox.max_attempts (integer, default 8) is missing';
  end if;

  -- A8. the state trigger guards every update; the claim locks with SKIP LOCKED
  if not exists (select 1 from pg_trigger where tgrelid = 'cma.outbox_action'::regclass and tgname = 'check_state'
                 and tgfoid = 'cma.check_outbox_action()'::regprocedure and not tgisinternal and tgenabled = 'O') then
    raise exception 'FAIL A8: the state trigger on cma.outbox_action is missing';
  end if;
  select count(*) into v_n
  from regexp_matches((select prosrc from pg_proc where oid = 'cma.outbox_claim(uuid,integer)'::regprocedure),
                      'for\s+update\s+skip\s+locked', 'gi');
  if v_n < 3 then
    raise exception 'FAIL A8: outbox_claim locks % of its 3 selections with FOR UPDATE SKIP LOCKED', v_n;
  end if;
end
$$;

-- B. Write-back fields (throwaway tenant, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_admin    uuid;
  v_c1       uuid;
  v_c2       uuid;
  v_txt      text;
  v_n        int;
  v_cfg      jsonb;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007c-one', 'Verify 0007c one', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'admin';

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id into v_c1 from cma.upsert_connection('verify_crm', 'Verify CRM one', '1000001', null, null) c;
    select c.connection_id into v_c2 from cma.upsert_connection('verify_crm', 'Verify CRM two', '1000002', null, null) c;

    -- B1. the seven fields of the contact write-back, two slots for the customer id; a second call
    --     updates in place (one row per field and slot)
    perform cma.set_writeback_field(v_c1, 'commerce_ref', 'verify_shop_id_1', 'slot', true);
    perform cma.set_writeback_field(v_c1, 'commerce_ref', 'verify_shop_id_2', 'slot', true, 2::smallint);
    perform cma.set_writeback_field(v_c1, 'commerce_store', 'verify_shop_store', 'always', true);
    perform cma.set_writeback_field(v_c1, 'commerce_orders', 'verify_shop_orders', 'always', true);
    perform cma.set_writeback_field(v_c1, 'commerce_spent', 'verify_shop_spent', 'always', true);
    perform cma.set_writeback_field(v_c1, 'country', 'verify_country', 'always', true);
    perform cma.set_writeback_field(v_c1, 'currency', 'verify_currency', 'if_empty', true);
    perform cma.set_writeback_field(v_c1, 'language', 'verify_language', 'if_empty', true);
    perform cma.set_writeback_field(v_c1, 'country', ' verify_country ', 'if_empty', true);
    select string_agg(field || ':' || slot || ':' || target_property || ':' || mode || ':' || enabled, ',' order by field, slot) into v_txt
    from cma.writeback_field where connection_id = v_c1;
    if v_txt is distinct from 'commerce_orders:1:verify_shop_orders:always:true,commerce_ref:1:verify_shop_id_1:slot:true,'
                              'commerce_ref:2:verify_shop_id_2:slot:true,commerce_spent:1:verify_shop_spent:always:true,'
                              'commerce_store:1:verify_shop_store:always:true,country:1:verify_country:if_empty:true,'
                              'currency:1:verify_currency:if_empty:true,language:1:verify_language:if_empty:true' or v_provoke then
      raise exception 'FAIL B1: write-back fields are %', v_txt;
    end if;

    -- B2. disabling keeps the row
    perform cma.set_writeback_field(v_c1, 'language', 'verify_language', 'if_empty', false);
    if (select enabled from cma.writeback_field where connection_id = v_c1 and field = 'language') is distinct from false
       or (select count(*) from cma.writeback_field where connection_id = v_c1) <> 8 then
      raise exception 'FAIL B2: disabling language did not keep the row disabled';
    end if;

    -- B3. refusals: the slot mode and a slot above 1 for any field but commerce_ref, a slot outside 1
    --     to 9, an unknown field or mode, an empty or long property, enabled null (CMA04); a property
    --     another field writes (CMA03); an unknown connection (CMA02); the table refuses the slot mode
    --     for another field by itself
    foreach v_txt in array array[
      format('select cma.set_writeback_field(%L, ''country'', ''verify_x'', ''slot'', true)', v_c1),
      format('select cma.set_writeback_field(%L, ''commerce_store'', ''verify_x'', ''always'', true, 2::smallint)', v_c1),
      format('select cma.set_writeback_field(%L, ''commerce_ref'', ''verify_x'', ''slot'', true, 0::smallint)', v_c1),
      format('select cma.set_writeback_field(%L, ''commerce_ref'', ''verify_x'', ''slot'', true, 10::smallint)', v_c1),
      format('select cma.set_writeback_field(%L, ''email'', ''verify_x'', ''always'', true)', v_c1),
      format('select cma.set_writeback_field(%L, ''country'', ''verify_x'', ''overwrite'', true)', v_c1),
      format('select cma.set_writeback_field(%L, ''country'', '' '', ''always'', true)', v_c1),
      format('select cma.set_writeback_field(%L, ''country'', %L, ''always'', true)', v_c1, repeat('p', 101)),
      format('select cma.set_writeback_field(%L, ''country'', ''verify_x'', ''always'', null)', v_c1)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL B3: % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    begin
      perform cma.set_writeback_field(v_c1, 'currency', 'verify_country', 'always', true);
      raise exception 'FAIL B3: two fields write verify_country';
    exception when sqlstate 'CMA03' then null;
    end;
    begin
      perform cma.set_writeback_field(gen_random_uuid(), 'country', 'verify_x', 'always', true);
      raise exception 'FAIL B3: an unknown connection was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    begin
      insert into cma.writeback_field (connection_id, field, target_property, mode) values (v_c2, 'country', 'verify_x', 'slot');
      raise exception 'FAIL B3: the table took the slot mode for country';
    exception when check_violation then null;
    end;
    begin
      insert into cma.writeback_field (connection_id, field, target_property, mode)
      values (v_c2, 'country', 'verify_x', 'always'), (v_c2, 'currency', 'verify_x', 'always');
      raise exception 'FAIL B3: the table took a property twice';
    exception when unique_violation then null;
    end;
    select string_agg(field || ':' || target_property || ':' || mode, ',' order by field, slot) into v_txt
    from cma.writeback_field where connection_id = v_c1 and field in ('country', 'currency', 'commerce_store');
    if v_txt is distinct from 'commerce_store:verify_shop_store:always,country:verify_country:if_empty,currency:verify_currency:if_empty'
       or (select count(*) from cma.writeback_field) <> 8 then
      raise exception 'FAIL B3: a refusal changed the fields: %', v_txt;
    end if;

    -- B4. another connection may write the same property
    perform cma.set_writeback_field(v_c2, 'country', 'verify_country', 'if_empty', true);
    if (select count(*) from cma.writeback_field where target_property = 'verify_country') <> 2 then
      raise exception 'FAIL B4: a second connection could not write verify_country';
    end if;

    -- B5. the adapter's configuration lists the fields with slot, property, mode and enabled; a
    --     connection without any answers an empty list
    v_cfg := cma.connection_config(v_c1);
    select count(*) into v_n from jsonb_array_elements(v_cfg -> 'writeback') w
    where (w ->> 'field' = 'commerce_ref' and (w ->> 'slot')::int = 2 and w ->> 'property' = 'verify_shop_id_2' and w ->> 'mode' = 'slot'
           and (w ->> 'enabled')::boolean)
       or (w ->> 'field' = 'language' and not (w ->> 'enabled')::boolean);
    if jsonb_array_length(v_cfg -> 'writeback') <> 8 or v_n <> 2
       or not (v_cfg ? 'fields' and v_cfg ? 'pipelines' and v_cfg ? 'settings' and v_cfg ? 'store') then
      raise exception 'FAIL B5: connection_config gives %', v_cfg;
    end if;
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id into v_c2 from cma.upsert_connection('verify_crm', 'Verify CRM three', '1000003', null, null) c;
    if cma.connection_config(v_c2) -> 'writeback' is distinct from '[]'::jsonb then
      raise exception 'FAIL B5: a connection without write-back fields gives %', cma.connection_config(v_c2) -> 'writeback';
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- C. Enqueue (throwaway tenant, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_admin    uuid;
  v_ing1     uuid;
  v_c1       uuid;
  v_id       uuid;
  v_id2      uuid;
  v_id3      uuid;
  v_id4      uuid;
  v_other    uuid;
  v_txt      text;
  v_n        int;
  r          record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007c-one', 'Verify 0007c one', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'admin';
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id into v_c1 from cma.upsert_connection('verify_crm', 'Verify CRM one', '1000001', null, null) c;
    perform cma.set_writeback_field(v_c1, 'commerce_ref', 'verify_shop_id_1', 'slot', true);
    perform cma.set_writeback_field(v_c1, 'commerce_ref', 'verify_shop_id_2', 'slot', true, 2::smallint);
    perform cma.set_writeback_field(v_c1, 'commerce_store', 'verify_shop_store', 'always', true);
    perform cma.set_writeback_field(v_c1, 'commerce_orders', 'verify_shop_orders', 'always', true);
    perform cma.set_writeback_field(v_c1, 'commerce_spent', 'verify_shop_spent', 'always', true);
    perform cma.set_writeback_field(v_c1, 'country', 'verify_country', 'if_empty', true);
    perform cma.set_writeback_field(v_c1, 'currency', 'verify_currency', 'if_empty', true);
    perform cma.set_writeback_field(v_c1, 'language', 'verify_language', 'if_empty', false);
    perform set_config('app.user_id', v_ing1::text, true);

    -- C1. only enabled fields are kept (language is disabled); values normalised; a pending action
    --     for the contact, written by the Ingest user, with its reason
    v_id := cma.enqueue_contact_writeback(v_c1, ' 9000001 ', '{"commerce_ref": "7001", "commerce_store": "verify-gb",
      "commerce_orders": "3", "commerce_spent": "120.505", "country": "GB", "currency": "gbp", "language": "en"}',
      'commerce_customer:7001');
    select * into r from cma.outbox_action where id = v_id;
    if r.payload is distinct from '{"commerce_ref": "7001", "commerce_store": "verify-gb", "commerce_orders": 3, "commerce_spent": 120.51,
                                    "country": "GB", "currency": "GBP"}'::jsonb
       or r.status <> 'pending' or r.attempts <> 0 or r.target_type <> 'contact' or r.target_id <> '9000001'
       or r.action <> 'crm.contact.set_properties' or r.created_by is distinct from v_ing1 or r.reason <> 'commerce_customer:7001'
       or r.next_attempt_at > now() or length(r.dedupe_key) <> 64 or v_provoke then
      raise exception 'FAIL C1: the action is % % % % by %', r.status, r.target_id, r.payload, r.reason, r.created_by;
    end if;

    -- C2. refusals (CMA04), nothing written: an unknown field, a value that is an object, a negative
    --     or fractional count, an amount or currency that is none, an id over 100 characters, values
    --     that are not an object, an empty contact id, a long reason
    foreach v_txt in array array[
      format('select cma.enqueue_contact_writeback(%L, ''9000001'', ''{"email": "x@example.com"}'', null)', v_c1),
      format('select cma.enqueue_contact_writeback(%L, ''9000001'', ''{"commerce_ref": {"id": 1}}'', null)', v_c1),
      format('select cma.enqueue_contact_writeback(%L, ''9000001'', ''{"commerce_ref": "7001", "commerce_orders": -1}'', null)', v_c1),
      format('select cma.enqueue_contact_writeback(%L, ''9000001'', ''{"commerce_ref": "7001", "commerce_orders": 2.5}'', null)', v_c1),
      format('select cma.enqueue_contact_writeback(%L, ''9000001'', ''{"commerce_ref": "7001", "commerce_spent": "a lot"}'', null)', v_c1),
      format('select cma.enqueue_contact_writeback(%L, ''9000001'', ''{"currency": "EURO"}'', null)', v_c1),
      format('select cma.enqueue_contact_writeback(%L, ''9000001'', %L, null)', v_c1, jsonb_build_object('commerce_ref', repeat('9', 101))),
      format('select cma.enqueue_contact_writeback(%L, ''9000001'', ''["GB"]'', null)', v_c1),
      format('select cma.enqueue_contact_writeback(%L, '' '', ''{"country": "GB"}'', null)', v_c1),
      format('select cma.enqueue_contact_writeback(%L, ''9000001'', ''{"country": "GB"}'', %L)', v_c1, repeat('r', 101))
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL C2: % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    if (select count(*) from cma.outbox_action) <> 1 then
      raise exception 'FAIL C2: a refused write-back was written';
    end if;

    -- C3. nothing left to write gives null and no row: a disabled field only, null and empty values,
    --     the totals without the customer id they describe
    if cma.enqueue_contact_writeback(v_c1, '9000002', '{"language": "nl"}', null) is not null
       or cma.enqueue_contact_writeback(v_c1, '9000002', '{"country": null, "currency": " "}', null) is not null
       or cma.enqueue_contact_writeback(v_c1, '9000002', '{"commerce_orders": 2, "commerce_spent": 10, "commerce_store": "verify-gb"}', null) is not null
       or (select count(*) from cma.outbox_action) <> 1 then
      raise exception 'FAIL C3: a write-back with nothing to write gave an action';
    end if;

    -- C4. dedupe: the same payload again (written differently, another reason) gives the same action
    v_id2 := cma.enqueue_contact_writeback(v_c1, '9000001', '{"currency": "GBP", "country": "GB", "commerce_spent": 120.51,
      "commerce_orders": 3, "commerce_store": "verify-gb", "commerce_ref": 7001, "language": "en"}', 'reconcile');
    if v_id2 is distinct from v_id or (select count(*) from cma.outbox_action) <> 1 then
      raise exception 'FAIL C4: the same payload gave a second action (% versus %)', v_id2, v_id;
    end if;

    -- C5. a newer payload for the contact supersedes the older pending action; another contact's
    --     pending action is left alone
    v_other := cma.enqueue_contact_writeback(v_c1, '9000003', '{"country": "NL"}', null);
    v_id2 := cma.enqueue_contact_writeback(v_c1, '9000001', '{"commerce_ref": "7001", "commerce_orders": 4}', null);
    select string_agg(target_id || ':' || status, ',' order by id) into v_txt from cma.outbox_action;
    if v_id2 = v_id or v_txt is distinct from '9000001:superseded,9000003:pending,9000001:pending' then
      raise exception 'FAIL C5: after a newer payload the actions are %', v_txt;
    end if;

    -- C6. a sent action is never touched: a newer payload after it is a new action, the sent one stays
    perform 1 from cma.outbox_claim(v_c1);
    perform cma.outbox_finish(array[v_id2], 'sent', '{"written": ["verify_shop_orders"]}');
    select * into r from cma.outbox_action where id = v_id2;
    v_id3 := cma.enqueue_contact_writeback(v_c1, '9000001', '{"commerce_ref": "7001", "commerce_orders": 5}', null);
    if v_id3 = v_id2 or (select status from cma.outbox_action where id = v_id2) <> 'sent'
       or (select sent_at from cma.outbox_action where id = v_id2) is distinct from r.sent_at
       or (select status from cma.outbox_action where id = v_id3) <> 'pending' then
      raise exception 'FAIL C6: a newer payload after a sent action changed it or wrote nothing';
    end if;

    -- C7. the same payload as an earlier, overtaken action is written again (the earlier one keeps
    --     its history under a retired key); dedupe holds against the latest action only
    v_id4 := cma.enqueue_contact_writeback(v_c1, '9000001', '{"commerce_ref": "7001", "commerce_orders": 4}', null);
    select count(*) into v_n from cma.outbox_action where target_id = '9000001';
    if v_id4 in (v_id2, v_id3) or v_n <> 4
       or (select dedupe_key from cma.outbox_action where id = v_id2) <> (select dedupe_key from cma.outbox_action where id = v_id4) || ':' || v_id2::text
       or (select status from cma.outbox_action where id = v_id3) <> 'superseded'
       or (select status from cma.outbox_action where id = v_id2) <> 'sent' then
      raise exception 'FAIL C7: the earlier payload again gave % (% actions for the contact)', v_id4, v_n;
    end if;

    -- C8. an inactive or unknown connection takes no write-back (CMA02)
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_connection_status(v_c1, 'inactive');
    perform set_config('app.user_id', v_ing1::text, true);
    foreach v_txt in array array[
      format('select cma.enqueue_contact_writeback(%L, ''9000004'', ''{"country": "GB"}'', null)', v_c1),
      format('select cma.enqueue_contact_writeback(%L, ''9000004'', ''{"country": "GB"}'', null)', gen_random_uuid())
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL C8: % was accepted', v_txt;
      exception when sqlstate 'CMA02' then null;
      end;
    end loop;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- D. Claim and finish (throwaway tenant, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_admin    uuid;
  v_ing1     uuid;
  v_c1       uuid;
  v_a        uuid;
  v_b        uuid;
  v_c        uuid;
  v_c2       uuid;
  v_b2       uuid;
  v_d        uuid;
  v_e        uuid;
  v_ids      uuid[];
  v_txt      text;
  v_n        int;
  r          record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007c-one', 'Verify 0007c one', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'admin';
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id into v_c1 from cma.upsert_connection('verify_crm', 'Verify CRM one', '1000001', null, null) c;
    perform cma.set_writeback_field(v_c1, 'country', 'verify_country', 'if_empty', true);
    perform cma.set_writeback_field(v_c1, 'commerce_ref', 'verify_shop_id_1', 'slot', true);
    perform cma.set_writeback_field(v_c1, 'commerce_orders', 'verify_shop_orders', 'always', true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_a := cma.enqueue_contact_writeback(v_c1, '9000001', '{"country": "GB"}', null);
    v_b := cma.enqueue_contact_writeback(v_c1, '9000002', '{"country": "NL"}', null);
    v_c := cma.enqueue_contact_writeback(v_c1, '9000003', '{"country": "DE"}', null);

    -- D1. a claim takes the three due actions once: in flight, one attempt, claimed now, the next
    --     attempt a minute ahead; a second claim takes nothing
    select array_agg(c.action_id order by c.action_id), count(*) filter (where c.attempts = 1 and c.payload ? 'country')
    into v_ids, v_n from cma.outbox_claim(v_c1) c;
    if v_ids is distinct from array[v_a, v_b, v_c] or v_n <> 3
       or exists (select 1 from cma.outbox_action where status <> 'in_flight' or claimed_at <> now()
                                                    or next_attempt_at <> now() + interval '1 minute')
       or exists (select 1 from cma.outbox_claim(v_c1)) or v_provoke then
      raise exception 'FAIL D1: claimed % (% at one attempt), or claimed again at once', v_ids, v_n;
    end if;

    -- D2. sent with the result; finishing again changes nothing, and a sent action never fails
    if cma.outbox_finish(array[v_a], 'sent', '{"written": ["verify_country"], "responseId": "r-1"}') <> 1
       or cma.outbox_finish(array[v_a], 'sent') <> 0
       or cma.outbox_finish(array[v_a], 'failed', null, 'late_failure') <> 0 then
      raise exception 'FAIL D2: finishing a sent action changed it';
    end if;
    select * into r from cma.outbox_action where id = v_a;
    if r.status <> 'sent' or r.sent_at <> now() or r.result ->> 'responseId' <> 'r-1' or r.error is not null then
      raise exception 'FAIL D2: the sent action holds % % % %', r.status, r.sent_at, r.result, r.error;
    end if;

    -- D3. a failure waits for its backoff (the next attempt the claim set), then is claimed again with
    --     the second attempt, two minutes ahead
    if cma.outbox_finish(array[v_b], 'failed', null, ' http_429 ') <> 1 then
      raise exception 'FAIL D3: the failure was not recorded';
    end if;
    select * into r from cma.outbox_action where id = v_b;
    if r.status <> 'failed' or r.error <> 'http_429' or r.next_attempt_at <> now() + interval '1 minute'
       or exists (select 1 from cma.outbox_claim(v_c1)) then
      raise exception 'FAIL D3: a failed action is % (%), or was claimed before its backoff', r.status, r.error;
    end if;
    perform set_config('role', 'cma_owner', true);
    update cma.outbox_action set next_attempt_at = now() - interval '1 second' where id = v_b;
    perform set_config('role', 'cma_app', true);
    select array_agg(c.action_id), max(c.attempts) into v_ids, v_n from cma.outbox_claim(v_c1) c;
    if v_ids is distinct from array[v_b] or v_n <> 2
       or (select next_attempt_at from cma.outbox_action where id = v_b) <> now() + interval '2 minutes' then
      raise exception 'FAIL D3: after its backoff the claim took % at attempt %', v_ids, v_n;
    end if;

    -- D4. a dead worker's claim comes back once it expires
    perform set_config('role', 'cma_owner', true);
    update cma.outbox_action set next_attempt_at = now() - interval '1 second' where id = v_c;
    perform set_config('role', 'cma_app', true);
    select array_agg(c.action_id), max(c.attempts) into v_ids, v_n from cma.outbox_claim(v_c1) c;
    if v_ids is distinct from array[v_c] or v_n <> 2 then
      raise exception 'FAIL D4: the expired claim came back as % at attempt %', v_ids, v_n;
    end if;

    -- D5. a newer action for a contact in flight waits for that claim; when the claim expires the
    --     overtaken action is superseded (a late finish changes nothing) and the newer one is claimed
    v_c2 := cma.enqueue_contact_writeback(v_c1, '9000003', '{"country": "AT"}', null);
    if (select status from cma.outbox_action where id = v_c) <> 'in_flight' or exists (select 1 from cma.outbox_claim(v_c1)) then
      raise exception 'FAIL D5: an action was claimed while the same contact was in flight';
    end if;
    perform set_config('role', 'cma_owner', true);
    update cma.outbox_action set next_attempt_at = now() - interval '1 second' where id = v_c;
    perform set_config('role', 'cma_app', true);
    select array_agg(c.action_id) into v_ids from cma.outbox_claim(v_c1) c;
    if v_ids is distinct from array[v_c2] or (select status from cma.outbox_action where id = v_c) <> 'superseded'
       or cma.outbox_finish(array[v_c], 'sent') <> 0 then
      raise exception 'FAIL D5: after the claim expired the claim took %, the older action is %', v_ids,
        (select status from cma.outbox_action where id = v_c);
    end if;

    -- D6. a failed action is superseded by a newer one for the same contact, never retried
    perform cma.outbox_finish(array[v_b], 'failed', null, 'http_500');
    v_b2 := cma.enqueue_contact_writeback(v_c1, '9000002', '{"country": "BE"}', null);
    select array_agg(c.action_id) into v_ids from cma.outbox_claim(v_c1) c;
    if (select status from cma.outbox_action where id = v_b) <> 'superseded' or v_ids is distinct from array[v_b2] then
      raise exception 'FAIL D6: the failed older action is %, the claim took %', (select status from cma.outbox_action where id = v_b), v_ids;
    end if;

    -- D7. parking: with outbox.max_attempts 2, the second failure parks the action for review; a
    --     parked action is never claimed
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_tenant_setting('outbox.max_attempts', '2');
    perform set_config('app.user_id', v_ing1::text, true);
    v_d := cma.enqueue_contact_writeback(v_c1, '9000004', '{"country": "FR"}', null);
    perform 1 from cma.outbox_claim(v_c1);
    perform cma.outbox_finish(array[v_d], 'failed', null, 'http_500');
    perform set_config('role', 'cma_owner', true);
    update cma.outbox_action set next_attempt_at = now() - interval '1 second' where id = v_d;
    perform set_config('role', 'cma_app', true);
    perform 1 from cma.outbox_claim(v_c1);
    perform cma.outbox_finish(array[v_d], 'failed', null, 'http_400');
    perform set_config('role', 'cma_owner', true);
    update cma.outbox_action set next_attempt_at = now() - interval '1 second' where id = v_d;
    perform set_config('role', 'cma_app', true);
    select * into r from cma.outbox_action where id = v_d;
    if r.status <> 'needs_review' or r.attempts <> 2 or r.error <> 'http_400'
       or exists (select 1 from cma.outbox_claim(v_c1) c where c.action_id = v_d) then
      raise exception 'FAIL D7: after two failures the action is % at attempt % (%)', r.status, r.attempts, r.error;
    end if;

    -- D8. a claim that expires at the maximum is parked too, not claimed a third time
    v_e := cma.enqueue_contact_writeback(v_c1, '9000005', '{"country": "SE"}', null);
    perform 1 from cma.outbox_claim(v_c1);
    perform cma.outbox_finish(array[v_e], 'failed', null, 'timeout');
    perform set_config('role', 'cma_owner', true);
    update cma.outbox_action set next_attempt_at = now() - interval '1 second' where id = v_e;
    perform set_config('role', 'cma_app', true);
    perform 1 from cma.outbox_claim(v_c1);
    perform set_config('role', 'cma_owner', true);
    update cma.outbox_action set next_attempt_at = now() - interval '1 second' where id = v_e;
    perform set_config('role', 'cma_app', true);
    select array_agg(c.action_id) into v_ids from cma.outbox_claim(v_c1) c;
    select * into r from cma.outbox_action where id = v_e;
    if r.status <> 'needs_review' or r.attempts <> 2 or r.error <> 'claim_expired' or v_e = any (coalesce(v_ids, '{}')) then
      raise exception 'FAIL D8: an expired claim at the maximum is % at attempt % (%)', r.status, r.attempts, r.error;
    end if;

    -- D9. a sent action never reopens, not even directly: the trigger refuses a move back or a new
    --     result (CMA03), the column grants refuse a change to what was asked (and so does the
    --     trigger, for the owner); a pending action cannot jump to sent
    begin
      update cma.outbox_action set status = 'pending' where id = v_a;
      raise exception 'FAIL D9: a sent action was reopened';
    exception when sqlstate 'CMA03' then null;
    end;
    begin
      update cma.outbox_action set result = '{"responseId": "r-2"}', sent_at = now() - interval '1 hour' where id = v_a;
      raise exception 'FAIL D9: a sent action''s result changed';
    exception when sqlstate 'CMA03' then null;
    end;
    begin
      update cma.outbox_action set payload = '{"country": "XX"}' where id = v_d;
      raise exception 'FAIL D9: the application changed a payload';
    exception when insufficient_privilege then null;
    end;
    v_c := cma.enqueue_contact_writeback(v_c1, '9000006', '{"country": "DK"}', null);
    begin
      update cma.outbox_action set status = 'sent' where id = v_c;
      raise exception 'FAIL D9: a pending action jumped to sent';
    exception when sqlstate 'CMA03' then null;
    end;
    perform set_config('role', 'cma_owner', true);
    begin
      update cma.outbox_action set payload = '{"country": "XX"}' where id = v_d;
      raise exception 'FAIL D9: the owner changed a payload';
    exception when sqlstate 'CMA03' then null;
    end;
    begin
      update cma.outbox_action set dedupe_key = 'verify' where id = v_d;
      raise exception 'FAIL D9: a dedupe key was replaced';
    exception when sqlstate 'CMA03' then null;
    end;
    perform set_config('role', 'cma_app', true);

    -- D10. refusals: an unknown outcome, a failure without an error, a result that is no object, a
    --      limit outside 1 to 500 (CMA04); a claim on an inactive connection (CMA02)
    foreach v_txt in array array[
      format('select cma.outbox_finish(array[%L]::uuid[], ''done'')', v_c),
      format('select cma.outbox_finish(array[%L]::uuid[], ''failed'', null, '' '')', v_c),
      format('select cma.outbox_finish(array[%L]::uuid[], ''sent'', ''["x"]'')', v_c),
      format('select cma.outbox_claim(%L, 0)', v_c1),
      format('select cma.outbox_claim(%L, 501)', v_c1)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL D10: % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_connection_status(v_c1, 'inactive');
    perform set_config('app.user_id', v_ing1::text, true);
    begin
      perform cma.outbox_claim(v_c1);
      raise exception 'FAIL D10: an inactive connection was claimed from';
    exception when sqlstate 'CMA02' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- E. Resolve and status (throwaway tenant, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_admin    uuid;
  v_manager  uuid;
  v_agent    uuid;
  v_ing1     uuid;
  v_c1       uuid;
  v_c2       uuid;
  v_x        uuid;
  v_y        uuid;
  v_z        uuid;
  v_z2       uuid;
  v_ids      uuid[];
  v_who      uuid;
  v_txt      text;
  r          record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007c-one', 'Verify 0007c one', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-manager@example.invalid', 'Verify manager') returning id into v_manager;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_admin, 'admin'), (v_manager, 'manager'), (v_agent, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id into v_c1 from cma.upsert_connection('verify_crm', 'Verify CRM one', '1000001', null, null) c;
    select c.connection_id into v_c2 from cma.upsert_connection('verify_crm', 'Verify CRM two', '1000002', null, null) c;
    perform cma.set_writeback_field(v_c1, 'country', 'verify_country', 'if_empty', true);
    perform cma.set_writeback_field(v_c2, 'country', 'verify_country', 'if_empty', true);
    perform cma.set_tenant_setting('outbox.max_attempts', '1');
    perform set_config('app.user_id', v_ing1::text, true);
    v_x := cma.enqueue_contact_writeback(v_c1, '9000001', '{"country": "GB"}', null);
    v_y := cma.enqueue_contact_writeback(v_c1, '9000002', '{"country": "NL"}', null);
    v_z := cma.enqueue_contact_writeback(v_c1, '9000003', '{"country": "DE"}', null);
    perform cma.enqueue_contact_writeback(v_c2, '9000001', '{"country": "IE"}', null);
    perform 1 from cma.outbox_claim(v_c1);
    perform cma.outbox_finish(array[v_x, v_y, v_z], 'failed', null, 'http_403');
    if (select count(*) from cma.outbox_action where status = 'needs_review') <> 3 then
      raise exception 'FAIL E1: the three failures are not parked';
    end if;

    -- E1. retry: pending again with its attempts starting over, due now, the person recorded; the
    --     next claim takes it
    perform set_config('app.user_id', v_admin::text, true);
    if cma.outbox_resolve(v_x, 'retry') <> 'pending' or v_provoke then
      raise exception 'FAIL E1: retry did not answer pending';
    end if;
    select * into r from cma.outbox_action where id = v_x;
    if r.status <> 'pending' or r.attempts <> 0 or r.next_attempt_at > now() or r.resolved_by is distinct from v_admin
       or r.resolved_at <> now() then
      raise exception 'FAIL E1: a retried action is % at % attempts, resolved by %', r.status, r.attempts, r.resolved_by;
    end if;
    perform set_config('app.user_id', v_ing1::text, true);
    select array_agg(c.action_id) into v_ids from cma.outbox_claim(v_c1) c;
    if v_ids is distinct from array[v_x] then
      raise exception 'FAIL E1: after the retry the claim took %', v_ids;
    end if;

    -- E2. drop: final, the person recorded, never claimed; the same payload again stays with it, a
    --     different one is a new action
    perform set_config('app.user_id', v_admin::text, true);
    if cma.outbox_resolve(v_y, 'drop') <> 'dropped' then
      raise exception 'FAIL E2: drop did not answer dropped';
    end if;
    perform set_config('app.user_id', v_ing1::text, true);
    select * into r from cma.outbox_action where id = v_y;
    if r.status <> 'dropped' or r.resolved_by is distinct from v_admin
       or cma.enqueue_contact_writeback(v_c1, '9000002', '{"country": "NL"}', null) is distinct from v_y
       or cma.enqueue_contact_writeback(v_c1, '9000002', '{"country": "BE"}', null) = v_y
       or (select status from cma.outbox_action where id = v_y) <> 'dropped' then
      raise exception 'FAIL E2: a dropped action is %, resolved by %', r.status, r.resolved_by;
    end if;

    -- E3. refusals: an unknown decision (CMA04); an unknown action (CMA02); an action not parked, in
    --     flight or dropped (CMA03); a retry when a newer action for the contact exists (CMA03), which
    --     may still be dropped
    v_z2 := cma.enqueue_contact_writeback(v_c1, '9000003', '{"country": "AT"}', null);
    perform set_config('app.user_id', v_admin::text, true);
    begin
      perform cma.outbox_resolve(v_z, 'ignore');
      raise exception 'FAIL E3: the decision ignore was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.outbox_resolve(gen_random_uuid(), 'drop');
      raise exception 'FAIL E3: an unknown action was resolved';
    exception when sqlstate 'CMA02' then null;
    end;
    foreach v_txt in array array[
      format('select cma.outbox_resolve(%L, ''drop'')', v_x),
      format('select cma.outbox_resolve(%L, ''retry'')', v_y),
      format('select cma.outbox_resolve(%L, ''retry'')', v_z2),
      format('select cma.outbox_resolve(%L, ''retry'')', v_z)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL E3: % was accepted', v_txt;
      exception when sqlstate 'CMA03' then null;
      end;
    end loop;
    if (select status from cma.outbox_action where id = v_z) <> 'needs_review' or cma.outbox_resolve(v_z, 'drop') <> 'dropped' then
      raise exception 'FAIL E3: the overtaken parked action could not be dropped';
    end if;

    -- E4. status per connection and state: counts, oldest and newest, the next attempt due
    select string_agg(s.connection_name || ':' || s.status || ':' || s.actions || ':' || (s.next_attempt_at is not null), ','
                      order by s.connection_name, s.status) into v_txt
    from cma.outbox_status() s;
    if v_txt is distinct from 'Verify CRM one:dropped:2:false,Verify CRM one:in_flight:1:true,Verify CRM one:pending:2:true,'
                              'Verify CRM two:pending:1:true'
       or exists (select 1 from cma.outbox_status() s where s.oldest_at > s.newest_at or s.oldest_at is null) then
      raise exception 'FAIL E4: outbox_status gives %', v_txt;
    end if;

    -- E5. a manager (reports.view) reads the status but cannot resolve; an agent and the Ingest user
    --     do neither (CMA06)
    perform set_config('app.user_id', v_manager::text, true);
    perform 1 from cma.outbox_status();
    foreach v_who in array array[v_manager, v_agent, v_ing1] loop
      perform set_config('app.user_id', v_who::text, true);
      foreach v_txt in array array[
        format('select cma.outbox_resolve(%L, ''drop'')', v_x),
        case when v_who <> v_manager then 'select cma.outbox_status()' end
      ] loop
        continue when v_txt is null;
        begin
          execute v_txt;
          raise exception 'FAIL E5: % ran %', v_who, v_txt;
        exception when sqlstate 'CMA06' then null;
        end;
      end loop;
    end loop;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- F. Permissions and tenant isolation (two throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_agent    uuid;
  v_admin2   uuid;
  v_ing1     uuid;
  v_ing2     uuid;
  v_who      uuid;
  v_c1       uuid;
  v_c2       uuid;
  v_a1       uuid;
  v_p1       uuid;
  v_a2       uuid;
  v_t        text;
  v_n        bigint;
  v_txt      text;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007c-one', 'Verify 0007c one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0007c-two', 'Verify 0007c two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin@example.invalid', 'Verify admin two') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin, 'admin'), (v_t1, v_agent, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    select id into v_ing2 from cma.app_user where tenant_id = v_t2 and email = 'ingest@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_crm', 'Verify CRM one', '1000001') returning id into v_c1;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verify_crm', 'Verify CRM two', '1000001') returning id into v_c2;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);

    -- F1. the Ingest user cannot configure, resolve or read the status; a configuring person and an
    --     agent cannot enqueue, claim or finish; an agent cannot configure either (CMA06)
    perform set_config('app.user_id', v_ing1::text, true);
    foreach v_txt in array array[
      format('select cma.set_writeback_field(%L, ''country'', ''verify_country'', ''if_empty'', true)', v_c1),
      format('select cma.outbox_resolve(%L, ''drop'')', gen_random_uuid()),
      'select cma.outbox_status()',
      'select cma.set_tenant_setting(''outbox.max_attempts'', ''1'')'
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL F1: the Ingest user ran %', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;
    if v_provoke then
      raise exception 'FAIL F1: provoked';
    end if;
    foreach v_who in array array[v_admin, v_agent] loop
      perform set_config('app.user_id', v_who::text, true);
      foreach v_txt in array array[
        format('select cma.enqueue_contact_writeback(%L, ''9000001'', ''{"country": "GB"}'', null)', v_c1),
        format('select cma.outbox_claim(%L)', v_c1),
        format('select cma.outbox_finish(array[%L]::uuid[], ''sent'')', gen_random_uuid())
      ] loop
        begin
          execute v_txt;
          raise exception 'FAIL F1: a person ran %', v_txt;
        exception when sqlstate 'CMA06' then null;
        end;
      end loop;
    end loop;
    foreach v_txt in array array[
      format('select cma.set_writeback_field(%L, ''country'', ''verify_country'', ''if_empty'', true)', v_c1),
      format('select cma.outbox_resolve(%L, ''drop'')', gen_random_uuid()),
      format('select cma.connection_config(%L)', v_c1)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL F1: an agent ran %', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;

    -- F2. tenant one fills both tables: a sent, a parked and a pending action
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_writeback_field(v_c1, 'country', 'verify_country', 'if_empty', true);
    perform cma.set_tenant_setting('outbox.max_attempts', '1');
    perform set_config('app.user_id', v_ing1::text, true);
    v_a1 := cma.enqueue_contact_writeback(v_c1, '9000001', '{"country": "GB"}', null);
    v_p1 := cma.enqueue_contact_writeback(v_c1, '9000002', '{"country": "NL"}', null);
    perform 1 from cma.outbox_claim(v_c1);
    perform cma.outbox_finish(array[v_a1], 'sent');
    perform cma.outbox_finish(array[v_p1], 'failed', null, 'http_403');
    perform cma.enqueue_contact_writeback(v_c1, '9000003', '{"country": "DE"}', null);

    -- F3. tenant two sees none of it, cannot write to tenant one's connection, claim from it, finish
    --     or resolve its actions, or configure it; the same contact, property and payload are its own
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    foreach v_t in array array['writeback_field', 'outbox_action'] loop
      execute format('select count(*) from cma.%I', v_t) into v_n;
      if v_n <> 0 then
        raise exception 'FAIL F3: tenant two sees % row(s) of tenant one in cma.%', v_n, v_t;
      end if;
    end loop;
    foreach v_txt in array array[
      format('select cma.enqueue_contact_writeback(%L, ''9000001'', ''{"country": "GB"}'', null)', v_c1),
      format('select cma.outbox_claim(%L)', v_c1),
      format('select cma.connection_config(%L)', v_c1)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL F3: tenant two ran %', v_txt;
      exception when sqlstate 'CMA02' then null;
      end;
    end loop;
    if cma.outbox_finish(array[v_p1], 'sent') <> 0 then
      raise exception 'FAIL F3: tenant two finished tenant one''s action';
    end if;
    perform set_config('app.user_id', v_admin2::text, true);
    foreach v_txt in array array[
      format('select cma.outbox_resolve(%L, ''drop'')', v_p1),
      format('select cma.set_writeback_field(%L, ''country'', ''verify_country'', ''if_empty'', true)', v_c1)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL F3: tenant two ran %', v_txt;
      exception when sqlstate 'CMA02' then null;
      end;
    end loop;
    if exists (select 1 from cma.outbox_status()) then
      raise exception 'FAIL F3: tenant two''s status shows tenant one''s actions';
    end if;
    perform cma.set_writeback_field(v_c2, 'country', 'verify_country', 'if_empty', true);
    perform set_config('app.user_id', v_ing2::text, true);
    v_a2 := cma.enqueue_contact_writeback(v_c2, '9000001', '{"country": "GB"}', null);
    if v_a2 is null or v_a2 = v_a1 or (select count(*) from cma.outbox_action) <> 1 then
      raise exception 'FAIL F3: tenant two''s own write-back gave %', v_a2;
    end if;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    if (select string_agg(status, ',' order by id) from cma.outbox_action) is distinct from 'sent,needs_review,pending'
       or (select count(*) from cma.writeback_field) <> 1 then
      raise exception 'FAIL F3: tenant two''s actions reached tenant one';
    end if;

    -- F4. no deletes on either table
    foreach v_t in array array['writeback_field', 'outbox_action'] loop
      begin
        execute format('delete from cma.%I', v_t);
        raise exception 'FAIL F4: the application deleted from cma.%', v_t;
      exception when insufficient_privilege then null;
      end;
    end loop;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the write-back fields and the outbox as it stands
select t.slug as tenant,
       (select count(*) from cma.writeback_field w where w.tenant_id = t.id and w.enabled) as writeback_fields,
       (select count(*) from cma.outbox_action o where o.tenant_id = t.id and o.status in ('pending', 'in_flight', 'failed')) as outbox_open,
       (select count(*) from cma.outbox_action o where o.tenant_id = t.id and o.status = 'needs_review') as outbox_parked,
       (select count(*) from cma.outbox_action o where o.tenant_id = t.id and o.status = 'sent') as outbox_sent,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
