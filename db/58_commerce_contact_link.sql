-- =============================================================================================
-- 58_commerce_contact_link.sql: addition 0008h, a commerce customer's CRM contact kept in the CMA
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 56_commerce_phone_hash.sql (0008g). Rerunnable, forward-only, in one transaction. Run as your own
-- IAM login, dev first, then prod; then 59_verify_commerce_contact_link.sql (dev), then
-- 57_verify_commerce_phone_hash.sql (dev), 37_verify_commerce.sql, 33_verify_intake_core.sql and
-- 31_verify_ingest_crm_records.sql again (unchanged).
--
-- Why (README Decision log, 13 October 2026): the CRM's own commerce integration already writes the
-- store's fields on the contact (and creates a deal per new order), and every property has one
-- writer, so the CMA writes nothing back for a store's customers. The CMA still needs each
-- customer's CRM contact (indirect sales: an order is matched to the contact's earlier deals and
-- calls), so the ingest service's match is kept here, in the CMA's own database.
--
-- What it adds
--   the link           cma.commerce_customer.crm_connection_id and crm_contact_source_id: the CRM
--                      connection and the contact id the customer was matched to, both set or both
--                      null; matched_at, when this link was made. A foreign key keeps the connection
--                      in the customer's tenant; the function below accepts only a CRM connection.
--                      An index on (tenant_id, crm_connection_id, crm_contact_source_id) finds a
--                      contact's customers
--   setting it         cma.set_commerce_customer_contact(store connection, customer id, CRM
--                      connection, contact id) (ingest.write): links, relinks or, with a null contact,
--                      clears; answers linked, relinked, unchanged, cleared, unlinked or unknown. An
--                      unchanged link writes nothing (matched_at stays the time of the match)
--   forgetting it      cma.forget_commerce_contact_links(CRM connection, contact id) (ingest.write):
--                      clears every customer link to that contact, for the CRM's privacy deletion of
--                      the contact (the ingest service calls it next to cma.ingest_contact_forget)
--
-- No other change: 0007b's tables, upserts and views (the reporting view leaves the link out),
-- 0007c's outbox and 0008g's hash stay as they are. A contact id is an identifier, not personal data
-- in itself; no email, name or number is stored.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted.
--
-- Guard: scripts run under a personal IAM login so the audit trail names a person. postgres is
-- for emergencies only; to use it deliberately, run first:  set cma.emergency = 'on';
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

begin;
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008g') then
    raise exception 'addition 0008g (56_commerce_phone_hash.sql) must run before 0008h';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The link
-- ---------------------------------------------------------------------------------------------
alter table cma.commerce_customer add column if not exists crm_connection_id uuid;
alter table cma.commerce_customer
  add column if not exists crm_contact_source_id text
    constraint commerce_customer_crm_contact_check check (length(crm_contact_source_id) between 1 and 100 and crm_contact_source_id = btrim(crm_contact_source_id));
alter table cma.commerce_customer add column if not exists matched_at timestamptz;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'cma.commerce_customer'::regclass
                 and conname = 'commerce_customer_crm_link_check') then
    alter table cma.commerce_customer add constraint commerce_customer_crm_link_check
      check ((crm_connection_id is null) = (crm_contact_source_id is null)
         and (crm_contact_source_id is null) = (matched_at is null));
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.commerce_customer'::regclass
                 and conname = 'commerce_customer_crm_connection_fkey') then
    alter table cma.commerce_customer add constraint commerce_customer_crm_connection_fkey
      foreign key (tenant_id, crm_connection_id) references cma.integration_connection (tenant_id, id);
  end if;
end
$$;
comment on column cma.commerce_customer.crm_connection_id is 'The CRM connection the customer was matched to (0008h); null with the contact id when unmatched';
comment on column cma.commerce_customer.crm_contact_source_id is 'The CRM contact the customer was matched to (0008h): an id, kept in the CMA only; nothing is written to the CRM';
comment on column cma.commerce_customer.matched_at is 'When the customer was linked to this contact (0008h); unchanged while the link holds';
create index if not exists commerce_customer_crm_contact_idx
  on cma.commerce_customer (tenant_id, crm_connection_id, crm_contact_source_id) where crm_contact_source_id is not null;

-- ---------------------------------------------------------------------------------------------
-- 2. Setting and clearing it (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- Links a store's customer to a contact of a CRM connection of the same tenant, or clears the link
-- with a null contact (the CRM connection is then not needed). To link, the customer must exist in
-- the store connection (CMA02) and the CRM connection must be active and a CRM connection: its kind
-- is crm, or its kind is unset and its rows are a CRM's only (0008e); another connection is CMA04.
-- Answers linked (no link before), relinked (another contact or connection before), unchanged
-- (nothing written), cleared, unlinked (nothing to clear) or unknown (a clear for a customer the
-- store connection does not hold: nothing to clear either, so a deletion the CMA never saw the
-- customer of does not fail).
create or replace function cma.set_commerce_customer_contact(p_store_connection_id uuid, p_customer_id text,
                                                             p_crm_connection_id uuid, p_contact_id text)
returns text
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_row     cma.commerce_customer;
  v_contact text := nullif(btrim(p_contact_id), '');
  v_kind    text;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_store_connection_id);
  select * into v_row from cma.commerce_customer cc
  where cc.tenant_id = v_tenant and cc.connection_id = p_store_connection_id and cc.source_id = btrim(p_customer_id)
  for update;
  if v_row.id is null and v_contact is null then
    return 'unknown';
  end if;
  if v_row.id is null then
    raise exception 'no customer % in store connection %', p_customer_id, p_store_connection_id using errcode = 'CMA02';
  end if;

  if v_contact is null then
    if v_row.crm_contact_source_id is null then
      return 'unlinked';
    end if;
    update cma.commerce_customer cc set crm_connection_id = null, crm_contact_source_id = null, matched_at = null
    where cc.tenant_id = v_tenant and cc.id = v_row.id;
    return 'cleared';
  end if;

  if length(v_contact) > 100 then
    raise exception 'a contact id is 1 to 100 characters' using errcode = 'CMA04';
  end if;
  perform cma.active_connection_adapter(p_crm_connection_id);
  if p_crm_connection_id = p_store_connection_id then
    raise exception 'a customer is linked to a CRM connection, not to its own store' using errcode = 'CMA04';
  end if;
  select c.kind into v_kind from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_crm_connection_id;
  if not (coalesce(v_kind, '') = 'crm'
          or (v_kind is null and cma.connection_held_kinds_of(v_tenant, p_crm_connection_id) = array['crm'])) then
    raise exception 'connection % is not a CRM connection', p_crm_connection_id using errcode = 'CMA04';
  end if;

  if v_row.crm_connection_id = p_crm_connection_id and v_row.crm_contact_source_id = v_contact then
    return 'unchanged';
  end if;
  update cma.commerce_customer cc
     set crm_connection_id = p_crm_connection_id, crm_contact_source_id = v_contact, matched_at = now()
   where cc.tenant_id = v_tenant and cc.id = v_row.id;
  return case when v_row.crm_contact_source_id is null then 'linked' else 'relinked' end;
end
$$;

-- The CRM deleted a contact for privacy: every customer link to it in the current tenant is cleared.
-- Answers how many links were cleared.
create or replace function cma.forget_commerce_contact_links(p_crm_connection_id uuid, p_contact_id text)
returns integer
language plpgsql
as $$
declare
  v_n integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.assert_connection(p_crm_connection_id);
  update cma.commerce_customer cc set crm_connection_id = null, crm_contact_source_id = null, matched_at = null
  where cc.tenant_id = cma.current_tenant_id() and cc.crm_connection_id = p_crm_connection_id
    and cc.crm_contact_source_id = btrim(p_contact_id);
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Grants: the application only
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.set_commerce_customer_contact(uuid, text, uuid, text) from public;
grant execute on function cma.set_commerce_customer_contact(uuid, text, uuid, text) to cma_app;
revoke execute on function cma.forget_commerce_contact_links(uuid, text) from public;
grant execute on function cma.forget_commerce_contact_links(uuid, text) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 4. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008h', 'Commerce contact link: a store customer''s matched CRM contact kept in the CMA (connection, contact id, matched_at), set or cleared by cma.set_commerce_customer_contact and forgotten with the CRM''s privacy deletion; nothing written to the CRM')
on conflict (version) do nothing;

commit;
reset role;
