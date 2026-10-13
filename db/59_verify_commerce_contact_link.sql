-- =============================================================================================
-- 59_verify_commerce_contact_link.sql: verifies addition 0008h, a commerce customer's CRM contact
-- kept in the CMA
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used, adapters, customers and contacts
-- are invented data values. Every check writes one row, PASS or FAIL, and the last result lists
-- them with the verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login in
-- dev, after 58_commerce_contact_link.sql; then 57_verify_commerce_phone_hash.sql,
-- 37_verify_commerce.sql, 33_verify_intake_core.sql and 31_verify_ingest_crm_records.sql again
-- (unchanged).
--   A  structure and privileges: the addition row; the three columns with their checks, the foreign
--      key into the tenant's connections and the index; the two functions the application's only,
--      in the caller's rights; nothing else changed (the table's other columns, the reporting view,
--      the upserts' signatures)
--   B  behaviour: a customer linked, the same link again writing nothing, relinked to another
--      contact and to another CRM connection, cleared, cleared again and an unknown customer's clear
--      answered; a CRM connection known by
--      its kind or, unset, by its rows; the refusals (an unknown customer, another store's customer,
--      an inactive, telephony, empty or the store's own connection, a long id); the link's
--      both-or-none rule on the table itself; the upserts leaving the link alone; the privacy
--      forget clearing one contact's links only; permissions and tenant isolation
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
-- session, so every block below stops at once and the verdict says REFUSED, also where the client
-- carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 59 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008h;
create temp table verify_0008h (ord int, check_name text, result text, detail text);

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text;
  v_bad     text;
  v_cols    text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded
  insert into verify_0008h values (1, 'A1 addition 0008h recorded',
    case when exists (select 1 from cma.schema_migration where version = '0008h') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the three columns, the both-or-none rule, the contact id rule, the foreign key, the index
  v_bad := '';
  select string_agg(column_name || ' ' || data_type || ' ' || is_nullable, ', ' order by column_name) into v_cols
  from information_schema.columns
  where table_schema = 'cma' and table_name = 'commerce_customer' and column_name in ('crm_connection_id', 'crm_contact_source_id', 'matched_at');
  if v_cols is distinct from 'crm_connection_id uuid YES, crm_contact_source_id text YES, matched_at timestamp with time zone YES' then
    v_bad := v_bad || format('columns [%s]; ', v_cols);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.commerce_customer'::regclass and conname = 'commerce_customer_crm_link_check'
                 and pg_get_constraintdef(oid) = 'CHECK ((((crm_connection_id IS NULL) = (crm_contact_source_id IS NULL)) AND ((crm_contact_source_id IS NULL) = (matched_at IS NULL))))') then
    v_bad := v_bad || 'the both-or-none check is missing; ';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.commerce_customer'::regclass and conname = 'commerce_customer_crm_contact_check') then
    v_bad := v_bad || 'the contact id check is missing; ';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.commerce_customer'::regclass and contype = 'f'
                 and confrelid = 'cma.integration_connection'::regclass
                 and pg_get_constraintdef(oid) ~ '^FOREIGN KEY \(tenant_id, crm_connection_id\) REFERENCES (cma\.)?integration_connection\(tenant_id, id\)$') then
    v_bad := v_bad || 'the foreign key into the tenant''s connections is missing; ';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'cma' and tablename = 'commerce_customer' and indexname = 'commerce_customer_crm_contact_idx'
                 and indexdef like '%(tenant_id, crm_connection_id, crm_contact_source_id)%') then
    v_bad := v_bad || 'the index is missing; ';
  end if;
  insert into verify_0008h values (2, 'A2 the link columns, their checks, the foreign key and the index',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the two functions: executable by the application only, in the caller's rights
  v_bad := '';
  foreach v_fn in array array['cma.set_commerce_customer_contact(uuid,text,uuid,text)', 'cma.forget_commerce_contact_links(uuid,text)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not the application''s only, in the caller''s rights; ';
    end if;
  end loop;
  insert into verify_0008h values (3, 'A3 the functions are the application''s only, in the caller''s rights',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. nothing else changed: the customers hold 0008g's columns plus the three, the reporting view
  --     and the upserts are as before, and the application still cannot delete customers
  v_bad := '';
  select string_agg(column_name, ', ' order by ordinal_position) into v_cols
  from information_schema.columns where table_schema = 'cma' and table_name = 'commerce_customer';
  if v_cols is distinct from 'id, tenant_id, connection_id, source_system, source_id, state, locale, orders_count, amount_spent, amount_currency, source_created_at, source_updated_at, source_deleted_at, synced_at, raw, phone_hash, crm_connection_id, crm_contact_source_id, matched_at' then
    v_bad := v_bad || format('commerce_customer [%s]; ', v_cols);
  end if;
  select string_agg(column_name, ', ' order by ordinal_position) into v_cols
  from information_schema.columns where table_schema = 'cma_read' and table_name = 'commerce_customer';
  if v_cols is distinct from 'id, tenant_id, connection_id, source_system, source_id, state, locale, orders_count, amount_spent, amount_currency, source_created_at, source_updated_at, source_deleted_at, synced_at' then
    v_bad := v_bad || format('cma_read.commerce_customer [%s]; ', v_cols);
  end if;
  if to_regprocedure('cma.ingest_upsert_commerce_customers(uuid,jsonb)') is null or to_regprocedure('cma.ingest_upsert_commerce_orders(uuid,jsonb)') is null
     or to_regprocedure('cma.enqueue_contact_writeback(uuid,text,jsonb,text)') is null then
    v_bad := v_bad || 'an upsert or the outbox enqueue changed its signature; ';
  end if;
  if has_table_privilege('cma_app', 'cma.commerce_customer', 'delete') then
    v_bad := v_bad || 'cma_app may delete customers; ';
  end if;
  insert into verify_0008h values (4, 'A4 nothing else changed (columns, reporting view, upserts, no deletes)',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_agent    uuid;
  v_admin2   uuid;
  v_ing1     uuid;
  v_ing2     uuid;
  v_shop     uuid;
  v_shop2    uuid;
  v_shopx    uuid;
  v_crm      uuid;
  v_crm2     uuid;
  v_crm_off  uuid;
  v_crm_rows uuid;
  v_tel      uuid;
  v_blank    uuid;
  v_crmx     uuid;
  v_txt      text;
  v_detail   text;
  v_ok       boolean;
  v_n        integer;
  v_at       timestamptz;
  v_audits   integer;
  v_s        timestamptz := timestamptz '2026-10-12 10:00:00+00';
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008h-one', 'Verify 0008h one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008h-two', 'Verify 0008h two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin, 'admin'), (v_t1, v_agent, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';

    -- tenant one: two shops, CRM connections of kind crm, unset with CRM rows, inactive, a telephony
    -- connection and one without kind or rows; tenant two: a shop and a CRM connection of its own
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id into v_shop from cma.upsert_connection('verifyshop', 'Verify shop one', 'one.example.com', null, null) c;
    select c.connection_id into v_shop2 from cma.upsert_connection('verifyshop', 'Verify shop two', 'two.example.com', null, null) c;
    select c.connection_id into v_crm from cma.upsert_connection('verifycrm', 'Verify CRM', 'portal-1', null, null) c;
    select c.connection_id into v_crm2 from cma.upsert_connection('verifycrm', 'Verify CRM two', 'portal-2', null, null) c;
    select c.connection_id into v_crm_rows from cma.upsert_connection('verifycrm', 'Verify CRM by its rows', 'portal-3', null, null) c;
    select c.connection_id into v_crm_off from cma.upsert_connection('verifycrm', 'Verify CRM off', 'portal-4', null, null) c;
    select c.connection_id into v_tel from cma.upsert_connection('verifytel', 'Verify phones', 'company-1', null, null) c;
    select c.connection_id into v_blank from cma.upsert_connection('verifycrm', 'Verify blank', 'portal-5', null, null) c;
    perform cma.set_connection_kind(v_crm, 'crm');
    perform cma.set_connection_kind(v_crm2, 'crm');
    perform cma.set_connection_kind(v_crm_off, 'crm');
    perform cma.set_connection_kind(v_tel, 'telephony');
    perform cma.set_connection_field(v_crm_rows, 'contact', 'ref', 'verifyshop', 'shop_id_1');
    perform cma.set_connection_status(v_crm_off, 'inactive');
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    select c.connection_id into v_shopx from cma.upsert_connection('verifyshop', 'Verify shop one', 'one.example.com', null, null) c;
    select c.connection_id into v_crmx from cma.upsert_connection('verifycrm', 'Verify CRM', 'portal-1', null, null) c;
    perform cma.set_connection_kind(v_crmx, 'crm');
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_commerce_customers(v_shopx, '[{"sourceId": "cu-1", "updatedAt": "2026-10-12T10:00:00Z"}]');
    perform cma.set_commerce_customer_contact(v_shopx, 'cu-1', v_crmx, 'k-1');
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_commerce_customers(v_shop, '[{"sourceId": "cu-1", "updatedAt": "2026-10-12T10:00:00Z"},
                                                          {"sourceId": "cu-2", "updatedAt": "2026-10-12T10:00:00Z"},
                                                          {"sourceId": "cu-3", "updatedAt": "2026-10-12T10:00:00Z"}]');
    perform cma.ingest_upsert_commerce_customers(v_shop2, '[{"sourceId": "cu-1", "updatedAt": "2026-10-12T10:00:00Z"}]');

    -- B1. a customer linked: the connection, the contact, the time of the match; audited
    v_txt := cma.set_commerce_customer_contact(v_shop, 'cu-1', v_crm, ' k-1 ');
    select matched_at into v_at from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-1';
    v_ok := v_txt = 'linked'
            and exists (select 1 from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-1'
                          and crm_connection_id = v_crm and crm_contact_source_id = 'k-1' and matched_at is not null)
            and exists (select 1 from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'commerce_customer' and a.action = 'update'
                          and a.new_row ->> 'source_id' = 'cu-1' and a.new_row ->> 'crm_contact_source_id' = 'k-1');
    v_rows := v_rows || array['11', 'B1 a customer linked to a contact, with the time of the match',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no outcome')];

    -- B2. the same link again: unchanged, nothing written (no audit row, the time stays)
    select count(*) into v_audits from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'commerce_customer';
    v_txt := cma.set_commerce_customer_contact(v_shop, 'cu-1', v_crm, 'k-1');
    v_ok := v_txt = 'unchanged'
            and (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'commerce_customer') = v_audits
            and (select matched_at from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-1') = v_at;
    v_rows := v_rows || array['12', 'B2 the same link again writes nothing',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no outcome')];

    -- B3. relinked: another contact, then another CRM connection; a CRM connection known by its rows
    v_txt := cma.set_commerce_customer_contact(v_shop, 'cu-1', v_crm, 'k-2');
    v_detail := cma.set_commerce_customer_contact(v_shop, 'cu-1', v_crm2, 'k-2');
    v_ok := v_txt = 'relinked' and v_detail = 'relinked'
            and exists (select 1 from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-1' and crm_connection_id = v_crm2 and crm_contact_source_id = 'k-2');
    v_txt := v_txt || ',' || v_detail || ',' || cma.set_commerce_customer_contact(v_shop, 'cu-2', v_crm_rows, 'k-9');
    v_ok := v_ok and v_txt like '%,linked'
            and exists (select 1 from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-2' and crm_connection_id = v_crm_rows);
    v_rows := v_rows || array['13', 'B3 relinked to another contact and connection; a CRM connection known by its rows',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no outcome')];

    -- B4. cleared with a null contact (or an empty one), cleared again, and a clear for a customer the
    --     store does not hold (unknown, nothing fails)
    v_txt := cma.set_commerce_customer_contact(v_shop, 'cu-2', null, null) || ',' || cma.set_commerce_customer_contact(v_shop, 'cu-2', v_crm, '')
             || ',' || cma.set_commerce_customer_contact(v_shop, 'cu-3', null, null) || ',' || cma.set_commerce_customer_contact(v_shop, 'cu-404', null, null);
    v_ok := v_txt = 'cleared,unlinked,unlinked,unknown'
            and exists (select 1 from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-2'
                          and crm_connection_id is null and crm_contact_source_id is null and matched_at is null);
    v_rows := v_rows || array['14', 'B4 a null contact clears the link; clearing again or an unknown customer changes nothing',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no outcome')];

    -- B5. refusals, nothing written: an unknown customer and another store's customer (CMA02), an
    --     inactive CRM connection (CMA02), the store itself, a telephony connection, one without kind
    --     or rows, a long contact id (CMA04)
    v_n := 0;
    begin perform cma.set_commerce_customer_contact(v_shop, 'cu-404', v_crm, 'k-1'); exception when sqlstate 'CMA02' then v_n := v_n + 1; end;
    begin perform cma.set_commerce_customer_contact(v_shop2, 'cu-3', v_crm, 'k-1'); exception when sqlstate 'CMA02' then v_n := v_n + 1; end;
    begin perform cma.set_commerce_customer_contact(v_shop, 'cu-3', v_crm_off, 'k-1'); exception when sqlstate 'CMA02' then v_n := v_n + 1; end;
    begin perform cma.set_commerce_customer_contact(v_shop, 'cu-3', v_shop, 'k-1'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.set_commerce_customer_contact(v_shop, 'cu-3', v_tel, 'k-1'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.set_commerce_customer_contact(v_shop, 'cu-3', v_blank, 'k-1'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.set_commerce_customer_contact(v_shop, 'cu-3', v_crm, repeat('k', 101)); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    v_ok := v_n = 7 and exists (select 1 from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-3' and crm_contact_source_id is null);
    v_rows := v_rows || array['15', 'B5 seven refusals, nothing written',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, format('%s of 7 refusals', v_n)];

    -- B6. the table itself holds the rule: a contact without its connection, or a connection without its
    --     time, is refused even for a direct update (as the owner)
    v_n := 0;
    perform set_config('role', 'cma_owner', true);
    begin
      update cma.commerce_customer set crm_contact_source_id = 'k-5' where tenant_id = v_t1 and connection_id = v_shop and source_id = 'cu-3';
    exception when check_violation then v_n := v_n + 1;
    end;
    begin
      update cma.commerce_customer set crm_connection_id = v_crm, crm_contact_source_id = 'k-5' where tenant_id = v_t1 and connection_id = v_shop and source_id = 'cu-3';
    exception when check_violation then v_n := v_n + 1;
    end;
    begin
      update cma.commerce_customer set crm_connection_id = v_crmx, crm_contact_source_id = 'k-5', matched_at = now() where tenant_id = v_t1 and connection_id = v_shop and source_id = 'cu-3';
    exception when foreign_key_violation then v_n := v_n + 1;
    end;
    perform set_config('role', 'cma_app', true);
    v_ok := v_n = 3;
    v_rows := v_rows || array['16', 'B6 the table refuses half a link and another tenant''s connection',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, format('%s of 3 refused', v_n)];

    -- B7. the upserts leave the link alone: a newer read and a deletion of the customer keep it (the
    --     ingest service clears it itself when a customer is deleted)
    perform cma.ingest_upsert_commerce_customers(v_shop, '[{"sourceId": "cu-1", "updatedAt": "2026-10-12T11:00:00Z", "ordersCount": 3}]');
    v_ok := exists (select 1 from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-1' and crm_contact_source_id = 'k-2' and orders_count = 3);
    perform cma.ingest_upsert_commerce_customers(v_shop, '[{"sourceId": "cu-1", "deletedAt": "2026-10-12T12:00:00Z"}]');
    v_ok := v_ok and exists (select 1 from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-1' and crm_contact_source_id = 'k-2' and source_deleted_at is not null);
    v_rows := v_rows || array['17', 'B7 the upserts of 0007b and 0008g leave the link alone',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, ''];

    -- B8. the privacy forget clears one contact's links in every store of the connection, no others;
    --     another tenant's link to the same contact id stays
    perform cma.set_commerce_customer_contact(v_shop, 'cu-3', v_crm2, 'k-2');
    perform cma.set_commerce_customer_contact(v_shop2, 'cu-1', v_crm, 'k-2');
    perform cma.set_commerce_customer_contact(v_shop, 'cu-2', v_crm2, 'k-7');
    v_n := cma.forget_commerce_contact_links(v_crm2, 'k-2');
    v_ok := v_n = 2
            and (select count(*) from cma.commerce_customer where tenant_id = v_t1 and crm_connection_id = v_crm2 and crm_contact_source_id = 'k-2') = 0
            and exists (select 1 from cma.commerce_customer where connection_id = v_shop2 and source_id = 'cu-1' and crm_connection_id = v_crm and crm_contact_source_id = 'k-2')
            and exists (select 1 from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-2' and crm_contact_source_id = 'k-7');
    perform set_config('role', 'cma_owner', true);
    v_ok := v_ok and exists (select 1 from cma.commerce_customer where tenant_id = v_t2 and crm_connection_id = v_crmx and crm_contact_source_id = 'k-1');
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['18', 'B8 the privacy forget clears that contact''s links only',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, format('%s cleared', v_n)];

    -- B9. permissions and isolation: an agent and a configuring person may not link or forget (CMA06);
    --     tenant two's Ingest user cannot reach tenant one's store (CMA02) and sees none of its links
    v_n := 0;
    perform set_config('app.user_id', v_agent::text, true);
    begin perform cma.set_commerce_customer_contact(v_shop, 'cu-3', v_crm, 'k-1'); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    perform set_config('app.user_id', v_admin::text, true);
    begin perform cma.set_commerce_customer_contact(v_shop, 'cu-3', v_crm, 'k-1'); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    begin perform cma.forget_commerce_contact_links(v_crm, 'k-2'); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    begin perform cma.set_commerce_customer_contact(v_shop, 'cu-3', v_crmx, 'k-1'); exception when sqlstate 'CMA02' then v_n := v_n + 1; end;
    begin perform cma.set_commerce_customer_contact(v_shopx, 'cu-1', v_crm, 'k-1'); exception when sqlstate 'CMA02' then v_n := v_n + 1; end;
    v_ok := v_n = 5
            and (select count(*) from cma.commerce_customer where crm_contact_source_id is not null) = 1
            and cma.forget_commerce_contact_links(v_crmx, 'k-2') = 0;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_ok := v_ok and exists (select 1 from cma.commerce_customer where connection_id = v_shop2 and source_id = 'cu-1' and crm_contact_source_id = 'k-2');
    v_rows := v_rows || array['19', 'B9 permissions and tenant isolation',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, format('%s of 5 refusals', v_n)];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008h (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008h values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008h
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008h where result = 'PASS') = 13
                       and not exists (select 1 from verify_0008h where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008h where result = 'PASS'),
                                        (select count(*) from verify_0008h where result <> 'PASS'))) x
order by ord;
reset role;
