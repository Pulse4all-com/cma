-- =============================================================================================
-- 168_pledge_lists.sql: addition 0009j, Assets → Pledge lists: the asset register's loan and language fields, the
-- loan catalog and per-model values, and the quarter files frozen on each quarter's first day
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Loans, per-model values, language aliases and the two settings are
-- tenant configuration set in Studio; no value is seeded. Runs unchanged in every database, after
-- 166_live_outbound_direct.sql (0009i). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own
-- IAM login: dev first, then 169_verify_pledge_lists.sql there (and its provoked run), then the verifies that read what
-- this changes: 27 (the scheduler role gains pledges.snapshot: its verify.job_permissions is edited by this change),
-- 77, 107 and 113 (cma.audit_row(): 113 also cma.device_raw_ok and the staging; its A2 is edited by this change: the two
-- columns), 115 (the staging, the load and
-- the connection fields' checks as text), 117 (dev and local only: the load; its A2 is edited by this change, the load's
-- row types gain two attributes), 123 (cma.ensure_scheduler_user's text), 85, 99 and 137 (the connection fields' checks
-- as text) and 161 (the installed base and data quality read the devices this load writes; nothing of theirs changes);
-- then the data map's schema refresh from dev on this branch; then prod: the point-in-time recovery check, 168, 169, 27,
-- 77, 107, 113, 115, 123, 85, 99, 137 and 161, before the merge. 131_time_all.sql is edited by this change (the three
-- pledge reads in part b; it refuses a database without 0009j). The ingest of main sends rows
-- without the two new keys, which this script's chunk load still takes (a missing key is an empty value); the ingest of
-- this change sends both keys, which the database before this script refuses, so in prod this script runs before that
-- ingest is deployed (Martin's steps). The web of main reads nothing this adds; the web of this change reads it.
--
-- Why (Martin, 10 November 2026; brief 0009j; Decision log, 10 Nov 2026, D1 to D8): every quarter Pulse4all sends the
-- Belastingdienst the pledge lists of the early-stage investors' loans, one .xlsx with three tabs per loan. The asset
-- register (the source of truth for which device secures which loan: its field maatje_id, a single select whose option
-- name is the loan's number) and Juo's subscriptions hold the facts; the loan catalog, the values per model and the
-- language aliases are configuration. The CMA freezes each quarter's rows on its first day so the same file can be
-- downloaded again, unchanged, at any later time.
--
-- What it adds
--   device fields      cma.device.pledge_ref (the register's loan reference as an id: the option name, trimmed, with
--                      subscription_ref's check; null for the empty option or a value that is no id, counted in
--                      refs_dropped) and cma.device.language (a two-letter code through cma.device_language_code_of; null
--                      when the label is empty or unmapped). raw keeps the language's label and the loan reference, as it
--                      keeps the model's, status's and country's labels (cma.device_raw_ok, from 112, knows both keys).
--                      The index device_pledge_idx (tenant, pledge_ref) for the pledged devices (cma.device is not a busy
--                      table: CLAUDE.md, Performance). Note: the first full read after the two fields are mapped updates
--                      every device whose raw gains a label (one audit row each, as any changed device)
--   language aliases   cma.device_language_alias (tenant, alias, code ^[a-z]{2}$): a register's language label, matched
--                      lower-cased and trimmed, to its code; cma.set_device_language_alias(alias, code) (tenant.configure;
--                      an empty code removes the alias); cma.device_language_code_of(tenant, label)
--   the load           the load's row types cma.device_load_row and cma.device_load_mapped gain pledge_ref and language;
--                      the staging cma.device_import_row and its COPY target cma.device_import_staging gain both columns
--                      (text, at most 500 characters, an @ kept as a bare @); made again with them, each from 116:
--                      cma.device_import_staging_insert(), cma.device_snapshot_apply, cma.ingest_load_device_chunk (the two
--                      keys allowed, a missing key empty) and cma.device_rows_apply (the two fields mapped, compared,
--                      updated and inserted; the answer gains unmapped_language: a label given that no alias maps). The
--                      same answers as 116 for every row without the two fields: 113, 115 and 117 pass unchanged on it
--                      (but for the column and attribute counts this change edits)
--   field mapping      connection_field's checks (from 136) take pledge_ref as a field and pledge_ref and language for an
--                      asset register's device (cma.set_connection_field writes them; it is unchanged)
--   loan catalog       cma.pledge_loan (key: the register's loan reference; number 1 to 999, the file's LOAN SPV and tab
--                      prefix; lender_label, area_label, name_suffix: the tab name's parts; layout 1 or 2; is_active) and
--                      cma.set_pledge_loan(...) (tenant.configure). Lender names are investors' personal data: set in
--                      Studio only, never in a seed, a fixture or a log (D8). cma.audit_row() (from 112) leaves the label
--                      out of pledge_loan's audit images (lender_label_changed on an update instead), as it keeps a
--                      staged device row's keys only; a quarter file keeps its frozen copy (the file's tab names, D5)
--   model values       cma.pledge_model_value (model_key, type_label, acquisition_value, depreciation_per_month, receipts)
--                      and cma.set_pledge_model_value(...) (tenant.configure)
--   settings           pledges.snapshot_local_time ('HH:MM' in the tenant's zone, default 00:05; 24:00 refused) and
--                      pledges.file_name_prefix (letters, digits, _ and -, 1 to 60, default Pledge_Lists), checked by their
--                      own trigger beside cma.check_tenant_setting() (as 132's data-quality setting)
--   the link           cma.linkable_subscriptions_of(tenant): the subscriptions a device's subscription reference can
--                      name, Installed base's rule (cma.flash_devices_of, 136): a subscription the CMA holds of a store of
--                      the device's market, the first by id when two share the reference. Read whole and hash-joined (a
--                      narrowing by an array of references was measured at 2.8 s for 15,000 against 42 ms whole, at
--                      30,000 subscriptions). 169 proves it links every device as cma.flash_devices_of does
--   the rows           cma.pledge_rows_of(tenant, valuation date): every device the register still holds whose loan
--                      reference is an active loan's key, with SN AED, Type AED, the market, the language in capitals,
--                      LOAN SPV, Customer ID (the customer reference, or In Storage when the register holds none; empty
--                      for a reference that is no id), Start date (the linked subscription's creation date in the
--                      tenant's zone; empty when In Storage or unlinked), First Shipment Date, Months Depriciating (whole
--                      months from the first shipment to the valuation date; 0 without one or after it), the model's
--                      values and Current value (round(acquisition − months × depreciation, 2), never below 0; empty
--                      without model values). One implementation for the page, the take and today's file
--   quarter files      cma.pledge_snapshot (valuation date unique per tenant, taken_at, taken_by, loans, devices, the
--                      sources' last reads) and cma.pledge_snapshot_row (every column of the rows, plus the loan's number,
--                      lender_label, area_label, name_suffix and layout copied in, so a later catalog change never alters
--                      an old file). Frozen: a trigger refuses update, delete and truncate on both (CMA03), the
--                      application holds no write on either, the rows are not audited one by one (the header's audit row
--                      carries the counts, as Flash's id lists)
--   the take           cma.pledge_snapshot_take(tenant) (pledges.snapshot, the scheduler's system user only; SECURITY
--                      DEFINER): on the tenant's local 1 January, 1 April, 1 July or 1 October from
--                      pledges.snapshot_local_time, the day's file once, under the tenant's advisory lock; answers taken,
--                      already_taken, not_due or no_pledges. cma.pledge_snapshot_take_at(tenant, instant) is its body, the
--                      owner's alone (169 tests the time gate with it). cma.pledge_snapshot_take_current()
--                      (tenant.configure; SECURITY DEFINER): the current quarter's first day once (taken or
--                      already_taken, no_pledges): the first comparison with October's file, and the way back after a
--                      missed first day. cma.ensure_scheduler_user (from 132) gives the scheduler role pledges.snapshot.
--                      The snapshot job (web/jobs/snapshot-flash.mjs) calls the take after Flash's, every minute
--   the reads          pledges.view, a new permission with no default role (D7): cma.pledge_page() (the quarter files,
--                      today's sums per loan, the checks before the next file, the quarter's state),
--                      cma.pledge_finding_rows(check, limit) (a check's serials), cma.pledge_file(valuation date or null
--                      for today) (a file's rows, at most 50,000: CMA04 above)
--
-- Measured locally (a throwaway tenant of 30,000 devices, 15,000 of them pledged to five active loans, 30,000
-- subscriptions; three times prod's register): cma.pledge_rows_of 88 ms, cma.pledge_page 218 ms, a check's serials 93 ms,
-- today's file 210 ms, the take 350 ms, a stored file 13 ms; the take before its day answers not_due in 0.3 ms.
--
-- Not made: no cma_read view of the loan catalog or the quarter files (lender names stay in the CMA's own tables); the
-- installed base's own copies of the link rule (cma.flash_devices_of, cma.data_quality_of) are not moved onto
-- cma.linkable_subscriptions_of here (169 proves they agree; moving them reruns 123, 133, 137, 159 and 161).
--
-- Everything is SECURITY INVOKER and executable by the application only, with its permission checked inside, except the
-- two takes (SECURITY DEFINER, owned by cma_owner, search path pinned) and their bodies (the owner's alone).
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid, CMA06 not permitted.
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
set local lock_timeout = '5s';
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0009i') then
    raise exception 'addition 0009i (166_live_outbound_direct.sql) must run before 0009j';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Language aliases (tenant configuration)
-- ---------------------------------------------------------------------------------------------
-- A register's language label (an option name such as English) to its two-letter code; matched lower-cased and trimmed.
-- One code per alias; several aliases may share a code
create table if not exists cma.device_language_alias (
  id          uuid primary key default uuidv7(),
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  alias       text not null check (alias = lower(btrim(alias)) and length(alias) between 1 and 100 and alias !~ '[[:cntrl:]@]'),
  code        text not null check (code ~ '^[a-z]{2}$'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, alias)
);
comment on table cma.device_language_alias is 'The asset register''s language labels and the two-letter code each maps to (cma.device_language_code_of): matched lower-cased and trimmed. Tenant configuration (0009j)';
comment on column cma.device_language_alias.code is 'The language''s two-letter code in lower case (en, nl); the pledge file writes it in capitals';
create or replace trigger set_updated_at before update on cma.device_language_alias
  for each row execute function cma.set_updated_at();
select cma.setup_tenant_table('cma.device_language_alias');

-- A label's code: the alias equal to the label lower-cased and trimmed; null for an empty or unmapped label
create or replace function cma.device_language_code_of(p_tenant_id uuid, p_label text)
returns text
language sql stable
as $$
  select a.code from cma.device_language_alias a
  where a.tenant_id = p_tenant_id and nullif(btrim(p_label), '') is not null and a.alias = lower(btrim(p_label))
$$;

-- Sets an alias's code (tenant.configure): the alias lower-cased and trimmed (1 to 100 characters, no @), the code two
-- letters (stored in lower case); an empty or null code removes the alias. Answers the alias as stored. A device takes the
-- new code at its next load that reads it (the nightly full read reads every device)
create or replace function cma.set_device_language_alias(p_alias text, p_code text)
returns text
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_alias  text := lower(btrim(coalesce(p_alias, '')));
  v_code   text := lower(btrim(coalesce(p_code, '')));
begin
  perform cma.assert_permission('tenant.configure');
  if length(v_alias) not between 1 and 100 or v_alias ~ '[[:cntrl:]@]' then
    raise exception 'an alias is the register''s label, 1 to 100 characters without an @' using errcode = 'CMA04';
  end if;
  if v_code = '' then
    delete from cma.device_language_alias a where a.tenant_id = v_tenant and a.alias = v_alias;
    return v_alias;
  end if;
  if v_code !~ '^[a-z]{2}$' then
    raise exception 'a language code is two letters, such as en' using errcode = 'CMA04';
  end if;
  insert into cma.device_language_alias (tenant_id, alias, code) values (v_tenant, v_alias, v_code)
  on conflict (tenant_id, alias) do update set code = excluded.code;
  return v_alias;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The devices' two new fields
-- ---------------------------------------------------------------------------------------------
alter table cma.device add column if not exists pledge_ref text;
alter table cma.device add column if not exists language text;
alter table cma.device drop constraint if exists device_pledge_ref_check;
alter table cma.device add constraint device_pledge_ref_check check (pledge_ref ~ '^[A-Za-z0-9#][A-Za-z0-9 _.#:/-]{0,99}$');
alter table cma.device drop constraint if exists device_language_check;
alter table cma.device add constraint device_language_check check (language ~ '^[a-z]{2}$');
comment on column cma.device.pledge_ref is 'The loan the device secures as the register states it (Pulse4all: the field maatje_id, a single select whose option name is the loan''s number): an id, trimmed; null for the empty option or a value that is no id. The register owns it; the CMA never writes it (0009j)';
comment on column cma.device.language is 'The device''s language as a two-letter code, mapped from the register''s label through cma.device_language_alias; null when the label is empty or unmapped (raw keeps the label) (0009j)';
create index if not exists device_pledge_idx on cma.device (tenant_id, pledge_ref) where pledge_ref is not null;

-- based on: 112_assets.sql
create or replace function cma.device_raw_ok(p_raw jsonb)
returns boolean
language sql immutable
as $$
  select p_raw is not null and jsonb_typeof(p_raw) = 'object' and length(p_raw::text) <= 4096 and strpos(p_raw::text, '@') = 0
     and not exists (select 1 from jsonb_object_keys(p_raw) k
                     where k not in ('source_id', 'serial', 'model', 'status', 'country', 'warehouse_ref', 'customer_ref',
                                     'subscription_ref', 'order_ref', 'first_shipped_on', 'stock_received_on', 'last_shipped_on',
                                     'warranty_until', 'end_of_life_on', 'components', 'external_refs', 'pledge_ref', 'language'))
$$;
revoke execute on function cma.device_raw_ok(jsonb) from public;
grant execute on function cma.device_raw_ok(jsonb) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 3. The staging and the load's row types
-- ---------------------------------------------------------------------------------------------
alter table cma.device_import_row add column if not exists pledge_ref text check (length(pledge_ref) <= 500);
alter table cma.device_import_row add column if not exists language text check (length(language) <= 500);

-- 0008zi's COPY target with the two columns at its end (a view gains columns only there)
create or replace view cma.device_import_staging as
  select r.batch_key, r.source_row, r.source_id, r.serial, r.model, r.status, r.country, r.warehouse_ref, r.customer_ref,
         r.subscription_ref, r.order_ref, r.first_shipped_on, r.stock_received_on, r.last_shipped_on, r.warranty_until,
         r.end_of_life_on, r.components, r.external_refs, r.pledge_ref, r.language
  from cma.device_import_row r
  where r.tenant_id = cma.current_tenant_id();

do $$
begin
  if not exists (select 1 from pg_attribute where attrelid = (select typrelid from pg_type where oid = 'cma.device_load_row'::regtype)
                 and attname = 'pledge_ref' and not attisdropped) then
    alter type cma.device_load_row add attribute pledge_ref text, add attribute language text;
  end if;
  if not exists (select 1 from pg_attribute where attrelid = (select typrelid from pg_type where oid = 'cma.device_load_mapped'::regtype)
                 and attname = 'pledge_ref' and not attisdropped) then
    alter type cma.device_load_mapped add attribute pledge_ref text, add attribute language text;
  end if;
end
$$;
comment on type cma.device_load_row is 'A device record as staged, every value text: the input of cma.device_rows_apply (0008zk; pledge_ref and language 0009j)';
comment on type cma.device_load_mapped is 'A device record as cma.device_rows_apply maps it (0008zk; pledge_ref and language 0009j)';

-- As 116, with the two staged columns (an @ kept as a bare @)
-- based on: 116_asset_sync_load.sql
create or replace function cma.device_import_staging_insert()
returns trigger
language plpgsql
as $$
begin
  perform cma.assert_any_permission(array['tenant.configure', 'ingest.write']);
  insert into cma.device_import_row (tenant_id, batch_key, source_row, source_id, serial, model, status, country, warehouse_ref,
                                     customer_ref, subscription_ref, order_ref, first_shipped_on, stock_received_on, last_shipped_on,
                                     warranty_until, end_of_life_on, components, external_refs, pledge_ref, language)
  values (cma.current_tenant_id(), new.batch_key, new.source_row, cma.device_staged_without_at(new.source_id),
          cma.device_staged_without_at(new.serial), cma.device_staged_without_at(new.model), cma.device_staged_without_at(new.status),
          cma.device_staged_without_at(new.country), cma.device_staged_without_at(new.warehouse_ref),
          cma.device_staged_without_at(new.customer_ref), cma.device_staged_without_at(new.subscription_ref),
          cma.device_staged_without_at(new.order_ref), cma.device_staged_without_at(new.first_shipped_on),
          cma.device_staged_without_at(new.stock_received_on), cma.device_staged_without_at(new.last_shipped_on),
          cma.device_staged_without_at(new.warranty_until), cma.device_staged_without_at(new.end_of_life_on),
          case when strpos(coalesce(new.components, ''), '@') > 0 then cma.device_staged_object_without_at(new.components) else new.components end,
          case when strpos(coalesce(new.external_refs, ''), '@') > 0 then cma.device_staged_object_without_at(new.external_refs) else new.external_refs end,
          cma.device_staged_without_at(new.pledge_ref), cma.device_staged_without_at(new.language));
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The load with the two fields
-- ---------------------------------------------------------------------------------------------
-- As 116, with the loan reference and the language: the reference kept only when it is an id (subscription_ref's
-- check; given but no id, it counts in refs_dropped), the language's label looked up once per distinct label
-- (cma.device_language_code_of), both compared, updated and inserted with the device's other values, raw keeping the
-- reference and the label. The answer gains unmapped_language (a label given that no alias maps). A row that stages
-- neither (the ingest of main, a file of the tool before this) loads both as empty, as any column the source leaves out
-- based on: 116_asset_sync_load.sql
create or replace function cma.device_rows_apply(p_connection_id uuid, p_rows cma.device_load_row[], p_is_full boolean)
returns jsonb
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_user    uuid;
  v_system  text;
  v_bad     text;
  v_m       cma.device_load_mapped[];
  v_newm    cma.device_load_mapped[];
  v_plan    cma.device_load_component[];
  v_dmap    jsonb;
  v_umap    jsonb;
  v_changed uuid[];
  v_new     uuid[];
  v_rid     uuid[];
  v_rows    integer;
  v_ins     integer;
  v_upd     integer;
  v_repl    integer;
  v_cid     uuid[];
  v_missing integer := 0;
  v_t       timestamptz;
  v_map     numeric;
  v_ups     numeric;
  v_cmp     numeric;
  v_mis     numeric := 0;
begin
  v_user := cma.assert_any_permission(array['tenant.configure', 'ingest.write']);
  v_system := cma.active_connection_adapter(p_connection_id);
  perform cma.assert_assets_connection(p_connection_id);
  if not cma.has_permission(v_user, 'tenant.configure')
     and (select ic.token_secret_name from cma.integration_connection ic where ic.tenant_id = v_tenant and ic.id = p_connection_id) is null then
    raise exception 'connection % has no token secret name: it is loaded from files (cma.load_device_snapshot), not by the ingest', p_connection_id
      using errcode = 'CMA04';
  end if;
  perform pg_advisory_xact_lock(hashtext('cma-device-load'), hashtext(p_connection_id::text));
  if p_is_full is null then
    raise exception 'is_full must be true (a full snapshot) or false (a partial one)' using errcode = 'CMA04';
  end if;
  v_rows := coalesce(cardinality(p_rows), 0);
  if v_rows = 0 then
    raise exception 'no rows to load' using errcode = 'CMA04';
  end if;
  v_t := clock_timestamp();

  -- the checks, before anything is written
  select string_agg(coalesce(x.source_row::text, '?'), ', ' order by x.source_row) into v_bad
  from (select r.source_row from unnest(p_rows) r where cma.device_staged_text(r.source_id) is null order by r.source_row limit 20) x;
  if v_bad is not null then
    raise exception 'lines %: no record id (or one that is no id)', v_bad using errcode = 'CMA04';
  end if;
  select string_agg(x.sid || ' (lines ' || x.lines || ')', '; ' order by x.sid) into v_bad
  from (select cma.device_staged_text(r.source_id) as sid, string_agg(coalesce(r.source_row::text, '?'), ', ' order by r.source_row) as lines
        from unnest(p_rows) r
        group by 1 having count(*) > 1
        order by 1 limit 20) x;
  if v_bad is not null then
    raise exception 'a record id appears twice: %', v_bad using errcode = 'CMA04';
  end if;
  -- each row's own problems (n 0) before its components' (n 1, 2, … in the object's order); the first row by line
  select x.problem into v_bad
  from (select r.source_row, 0::bigint as n,
               case when r.cj is null then format('line %s: components is not a JSON object', coalesce(r.source_row::text, '?'))
                    when r.rj is null then format('line %s: external_refs is not a JSON object', coalesce(r.source_row::text, '?'))
                    when not cma.device_staged_date_ok(r.first_shipped_on)
                      then format('line %s: first_shipped_on is not a date as YYYY-MM-DD', coalesce(r.source_row::text, '?'))
                    when not cma.device_staged_date_ok(r.stock_received_on)
                      then format('line %s: stock_received_on is not a date as YYYY-MM-DD', coalesce(r.source_row::text, '?'))
                    when not cma.device_staged_date_ok(r.last_shipped_on)
                      then format('line %s: last_shipped_on is not a date as YYYY-MM-DD', coalesce(r.source_row::text, '?'))
                    when not cma.device_staged_date_ok(r.warranty_until)
                      then format('line %s: warranty_until is not a date as YYYY-MM-DD', coalesce(r.source_row::text, '?'))
                    when not cma.device_staged_date_ok(r.end_of_life_on)
                      then format('line %s: end_of_life_on is not a date as YYYY-MM-DD', coalesce(r.source_row::text, '?'))
               end as problem
        from (select u.source_row, cma.device_staged_json(u.components) as cj, cma.device_staged_json(u.external_refs) as rj,
                     u.first_shipped_on, u.stock_received_on, u.last_shipped_on, u.warranty_until, u.end_of_life_on
              from unnest(p_rows) u offset 0) r
        union all
        select r.source_row, e.n,
               case when k.key is null then format('line %s: no component kind %s', coalesce(r.source_row::text, '?'), cma.device_staged_without_at(e.key))
                    when jsonb_typeof(e.value) <> 'object'
                      then format('line %s: component %s holds serial and expires_on only, as text', coalesce(r.source_row::text, '?'), cma.device_staged_without_at(e.key))
                    when e.value - 'serial' - 'expires_on' <> '{}'::jsonb
                         or coalesce(jsonb_typeof(e.value -> 'serial'), 'null') not in ('string', 'null')
                         or coalesce(jsonb_typeof(e.value -> 'expires_on'), 'null') not in ('string', 'null')
                      then format('line %s: component %s holds serial and expires_on only, as text', coalesce(r.source_row::text, '?'), cma.device_staged_without_at(e.key))
                    when not cma.device_staged_date_ok(e.value ->> 'expires_on')
                      then format('line %s: %s.expires_on is not a date as YYYY-MM-DD', coalesce(r.source_row::text, '?'), cma.device_staged_without_at(e.key))
               end
        from unnest(p_rows) r
        cross join lateral jsonb_each(cma.device_staged_json(r.components)) with ordinality as e(key, value, n)
        left join cma.device_component_kind k on k.tenant_id = v_tenant and k.key = e.key) x
  where x.problem is not null
  order by x.source_row, x.n
  limit 1;
  if v_bad is not null then
    raise exception '%', v_bad using errcode = 'CMA04';
  end if;

  -- the mapping: every value read once per row (r, materialized), each distinct label looked up once by 0008zi's
  -- functions, the named ids and the components of all rows grouped by record id (no per-row aggregate). The patterns
  -- are 0008zi's, a bounded repetition written as * with the length checked beside it (the same result, faster)
  with r as materialized (
         select u.source_row, cma.device_staged_text(u.source_id) as sid, u.model, u.status, cma.device_staged_text(u.model) as model_t,
                cma.device_staged_text(u.status) as status_t, cma.device_staged_text(u.country) as country,
                cma.device_staged_ref(u.serial) as serial, cma.device_staged_ref(u.warehouse_ref) as wh,
                case when btrim(coalesce(u.customer_ref, '')) ~ '^[A-Za-z0-9_-]+$' and length(btrim(u.customer_ref)) <= 100
                     then btrim(u.customer_ref) end as cust,
                nullif(btrim(coalesce(u.customer_ref, '')), '') is not null as cust_given,
                cma.device_staged_ref(u.subscription_ref) as sub, cma.device_staged_ref(u.order_ref) as ord,
                nullif(btrim(u.first_shipped_on), '')::date as first, nullif(btrim(u.stock_received_on), '')::date as recv,
                nullif(btrim(u.last_shipped_on), '')::date as last, nullif(btrim(u.warranty_until), '')::date as warr,
                nullif(btrim(u.end_of_life_on), '')::date as eol,
                -- the checks proved each empty or a JSON object: read once
                coalesce(nullif(btrim(u.components), '')::jsonb, '{}'::jsonb) as cj,
                coalesce(nullif(btrim(u.external_refs), '')::jsonb, '{}'::jsonb) as rj,
                nullif(btrim(coalesce(u.serial, '')), '') is not null as serial_given,
                nullif(btrim(coalesce(u.warehouse_ref, '')), '') is not null as wh_given,
                nullif(btrim(coalesce(u.subscription_ref, '')), '') is not null as sub_given,
                nullif(btrim(coalesce(u.order_ref, '')), '') is not null as ord_given,
                -- 0009j: the loan a device secures (an id, as subscription_ref) and its language's label
                cma.device_staged_ref(u.pledge_ref) as pledge, nullif(btrim(coalesce(u.pledge_ref, '')), '') is not null as pledge_given,
                u.language, cma.device_staged_text(u.language) as language_t
         from unnest(p_rows) u),
       models as (select l.label, cma.device_model_key_of(v_tenant, l.label) as key from (select distinct r.model as label from r) l),
       statuses as (select l.label, cma.device_status_key_of(v_tenant, l.label) as key from (select distinct r.status as label from r) l),
       markets as (select l.label, cma.market_code_of(v_tenant, l.label) as code from (select distinct r.country as label from r) l),
       languages as (select l.label, cma.device_language_code_of(v_tenant, l.label) as code from (select distinct r.language as label from r) l),
       -- the named ids: an id kept under its name, anything else dropped and counted, as is a name that is no name
       ref_items as materialized (
         select r.sid, x.key, nullif(btrim(coalesce(x.value #>> '{}', '')), '') is not null as given,
                x.key ~ '^[a-z][a-z0-9_]*$' and length(x.key) <= 40 as named,
                cma.device_staged_ref(x.value #>> '{}') as ref
         from r cross join lateral jsonb_each(r.rj) x),
       refs as (select i.sid,
                       jsonb_object_agg(i.key, i.ref) filter (where i.named and i.ref ~ '^[A-Za-z0-9#][A-Za-z0-9_.#:/-]*$') as refs,
                       (count(*) filter (where i.named and i.given and not coalesce(i.ref ~ '^[A-Za-z0-9#][A-Za-z0-9_.#:/-]*$', false))
                        + count(*) filter (where not i.named))::integer as dropped
                from ref_items i group by i.sid),
       -- the components as mapped: each kind's serial (an id, else dropped and counted) and expiry. A kind staged with
       -- neither given (emptied in the register) is kept as an empty object for the components, which close its current
       -- one, and left out of raw; a kind whose serial is given but dropped, with no expiry, is left out
       comp_items as materialized (
         select r.sid, c.key, cma.device_staged_ref(c.value ->> 'serial') as serial,
                nullif(btrim(coalesce(c.value ->> 'serial', '')), '') is not null as serial_given,
                (nullif(btrim(c.value ->> 'expires_on'), '')::date)::text as expires_on
         from r cross join lateral jsonb_each(r.cj) c),
       comp as (select i.sid,
                       jsonb_object_agg(i.key, jsonb_strip_nulls(jsonb_build_object('serial', i.serial, 'expires_on', i.expires_on)))
                         filter (where i.serial is not null or i.expires_on is not null) as comp,
                       jsonb_object_agg(i.key, jsonb_strip_nulls(jsonb_build_object('serial', i.serial, 'expires_on', i.expires_on)))
                         filter (where i.serial is not null or i.expires_on is not null or (not i.serial_given and i.expires_on is null)) as plan,
                       (count(*) filter (where i.serial_given and i.serial is null))::integer as dropped
                from comp_items i group by i.sid)
  select array_agg(row(r.source_row, r.sid, r.serial, mo.key, mk.code, st.key, r.wh, r.cust, r.cust is null and r.cust_given, r.sub, r.ord,
                       r.first, r.recv, r.last, r.warr, r.eol, coalesce(rf.refs, '{}'::jsonb), coalesce(cp.plan, '{}'::jsonb),
                       jsonb_strip_nulls(jsonb_build_object(
                         'source_id', r.sid, 'serial', r.serial, 'model', r.model_t, 'status', r.status_t, 'country', r.country,
                         'warehouse_ref', r.wh, 'customer_ref', r.cust, 'subscription_ref', r.sub, 'order_ref', r.ord,
                         'first_shipped_on', r.first::text, 'stock_received_on', r.recv::text, 'last_shipped_on', r.last::text,
                         'warranty_until', r.warr::text, 'end_of_life_on', r.eol::text,
                         'components', cp.comp, 'external_refs', rf.refs, 'pledge_ref', r.pledge, 'language', r.language_t)),
                       (r.serial_given and r.serial is null)::integer + (r.wh_given and r.wh is null)::integer
                       + (r.sub_given and r.sub is null)::integer + (r.ord_given and r.ord is null)::integer
                       + (r.pledge_given and r.pledge is null)::integer
                       + coalesce(rf.dropped, 0) + coalesce(cp.dropped, 0),
                       r.pledge, lg.code)::cma.device_load_mapped
                   order by r.source_row)
    into v_m
  from r
  left join models mo on mo.label is not distinct from r.model
  left join statuses st on st.label is not distinct from r.status
  left join markets mk on mk.label is not distinct from r.country
  left join languages lg on lg.label is not distinct from r.language
  left join refs rf on rf.sid = r.sid
  left join comp cp on cp.sid = r.sid;
  v_map := round(extract(epoch from clock_timestamp() - v_t) * 1000);
  v_t := clock_timestamp();

  -- the devices. Each row looks up its device by the record id's index (the rows drive every lookup, so no plan rests on
  -- the statistics of a connection this load is filling): a known one whose values differ (or that was missing), kept
  -- with its mapped values by id, and the new rows
  select coalesce(jsonb_object_agg(x.id::text, to_jsonb(m)) filter (where x.differs), '{}'::jsonb),
         coalesce(array_agg(m order by m.source_row) filter (where x.id is null), '{}')
    into v_dmap, v_newm
  from unnest(v_m) m
  left join lateral (select d.id,
                            (d.serial, d.model_key, d.market, d.device_status_key, d.warehouse_ref, d.customer_ref, d.customer_ref_invalid,
                             d.subscription_ref, d.order_ref, d.first_shipped_on, d.stock_received_on, d.last_shipped_on, d.warranty_until,
                             d.end_of_life_on, d.external_refs, d.raw, d.source_deleted_at, d.pledge_ref, d.language)
                            is distinct from
                            (m.serial, m.model_key, m.market, m.device_status_key, m.warehouse_ref, m.customer_ref, m.customer_ref_invalid,
                             m.subscription_ref, m.order_ref, m.first_shipped_on, m.stock_received_on, m.last_shipped_on, m.warranty_until,
                             m.end_of_life_on, m.external_refs, m.raw, null::timestamptz, m.pledge_ref, m.language) as differs
                     from cma.device d
                     where d.tenant_id = v_tenant and d.connection_id = p_connection_id and d.source_id = m.source_id
                     limit 1) x on true;
  -- the changed ones updated by id, each from its mapped values
  with u as (update cma.device d
                set (serial, model_key, market, device_status_key, warehouse_ref, customer_ref, customer_ref_invalid, subscription_ref,
                     order_ref, first_shipped_on, stock_received_on, last_shipped_on, warranty_until, end_of_life_on, external_refs, raw,
                     pledge_ref, language)
                  = (select n.serial, n.model_key, n.market, n.device_status_key, n.warehouse_ref, n.customer_ref, n.customer_ref_invalid,
                            n.subscription_ref, n.order_ref, n.first_shipped_on, n.stock_received_on, n.last_shipped_on, n.warranty_until,
                            n.end_of_life_on, n.external_refs, n.raw, n.pledge_ref, n.language
                     from jsonb_populate_record(null::cma.device_load_mapped, v_dmap -> d.id::text) n),
                    source_deleted_at = null, synced_at = now()
              where d.tenant_id = v_tenant and d.id = any (array(select k::uuid from jsonb_object_keys(v_dmap) k))
              returning d.id)
  select coalesce(array_agg(u.id), '{}') into v_changed from u;
  -- the new ones inserted, in line order
  with i as (insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key,
                                     warehouse_ref, customer_ref, customer_ref_invalid, subscription_ref, order_ref, first_shipped_on,
                                     stock_received_on, last_shipped_on, warranty_until, end_of_life_on, external_refs, raw, pledge_ref,
                                     language)
             select v_tenant, p_connection_id, v_system, m.source_id, m.serial, m.model_key, m.market, m.device_status_key, m.warehouse_ref,
                    m.customer_ref, m.customer_ref_invalid, m.subscription_ref, m.order_ref, m.first_shipped_on, m.stock_received_on,
                    m.last_shipped_on, m.warranty_until, m.end_of_life_on, m.external_refs, m.raw, m.pledge_ref, m.language
             from unnest(v_newm) m
             order by m.source_row
             returning id)
  select coalesce(array_agg(i.id), '{}') into v_new from i;
  v_ins := cardinality(v_new);
  v_ups := round(extract(epoch from clock_timestamp() - v_t) * 1000);
  v_t := clock_timestamp();

  -- the components: each staged kind against the device's current one of that kind, looked up by index from the row;
  -- a kind staged empty closes the current one, or does nothing when there is none. With none current, a kind staged
  -- again whose serial is the one the register emptied (or either serial missing: 0008zi's rule, a replacement is a
  -- serial that differs) is that component again: reopened (replaced_at cleared), its first sighting and so its anchor
  -- kept; a different serial is a replacement, inserted
  select coalesce(array_agg(row(d.id, e.key, e.value ->> 'serial', (e.value ->> 'expires_on')::date, coalesce(c.id, z.id),
                                case when e.value = '{}'::jsonb then case when c.id is null then 'none' else 'close' end
                                     when c.id is null and z.id is not null
                                          and ((e.value ->> 'serial') is null or z.serial is null or (e.value ->> 'serial') = z.serial) then 'reopen'
                                     when c.id is null then 'insert'
                                     when (e.value ->> 'serial') is not null and c.serial is not null and (e.value ->> 'serial') <> c.serial then 'replace'
                                     when (c.serial, c.expires_on) is distinct from (e.value ->> 'serial', (e.value ->> 'expires_on')::date) then 'update'
                                     else 'same' end)::cma.device_load_component), '{}')
    into v_plan
  from unnest(v_m) m
  cross join lateral (select d.id from cma.device d
                      where d.tenant_id = v_tenant and d.connection_id = p_connection_id and d.source_id = m.source_id
                      limit 1) d
  cross join lateral jsonb_each(m.components) e
  left join lateral (select c.id, c.serial, c.expires_on from cma.device_component c
                     where c.tenant_id = v_tenant and c.device_id = d.id and c.component_key = e.key and c.replaced_at is null
                     limit 1) c on true
  -- with none current and the kind staged with a value: the kind's last closed component
  left join lateral (select z.id, z.serial from cma.device_component z
                     where c.id is null and e.value <> '{}'::jsonb
                       and z.tenant_id = v_tenant and z.device_id = d.id and z.component_key = e.key and z.replaced_at is not null
                     order by z.replaced_at desc, z.first_seen_at desc, z.id desc
                     limit 1) z on true;
  -- a replaced one closed, and one whose kind the register emptied, by id
  v_rid := array(select p.current_id from unnest(v_plan) p where p.action = 'replace');
  v_cid := array(select p.current_id from unnest(v_plan) p where p.action = 'close');
  update cma.device_component c set replaced_at = now()
  where c.tenant_id = v_tenant and c.id = any (v_rid || v_cid);
  v_repl := cardinality(v_rid);
  insert into cma.device_component (tenant_id, device_id, component_key, serial, expires_on)
  select v_tenant, p.device_id, p.component_key, p.serial, p.expires_on
  from unnest(v_plan) p
  where p.action in ('insert', 'replace');
  -- a changed one updated in place, and a reopened one current again, by id, from its staged values
  select coalesce(jsonb_object_agg(p.current_id::text, jsonb_build_object('serial', p.serial, 'expires_on', p.expires_on)), '{}'::jsonb)
    into v_umap
  from unnest(v_plan) p where p.action in ('update', 'reopen');
  update cma.device_component c
     set serial = v_umap -> c.id::text ->> 'serial', expires_on = (v_umap -> c.id::text ->> 'expires_on')::date, replaced_at = null
   where c.tenant_id = v_tenant and c.id = any (array(select k::uuid from jsonb_object_keys(v_umap) k));
  -- a known device counts as updated when its values or any of its components changed
  select count(*) into v_upd
  from (select unnest(v_changed)
        union
        select p.device_id from unnest(v_plan) p where p.action not in ('same', 'none')
        except
        select unnest(v_new)) x;
  v_cmp := round(extract(epoch from clock_timestamp() - v_t) * 1000);

  -- a full snapshot: the connection's devices it does not hold are missing now (a hashed set of the rows' record ids)
  if p_is_full then
    v_t := clock_timestamp();
    update cma.device d set source_deleted_at = now(), synced_at = now()
    where d.tenant_id = v_tenant and d.connection_id = p_connection_id and d.source_deleted_at is null
      and d.source_id not in (select m.source_id from unnest(v_m) m where m.source_id is not null);
    get diagnostics v_missing = row_count;
    v_mis := round(extract(epoch from clock_timestamp() - v_t) * 1000);
  end if;

  return jsonb_build_object('rows', v_rows, 'inserted', v_ins, 'updated', v_upd, 'unchanged', v_rows - v_ins - v_upd, 'missing_now', v_missing,
    'components_replaced', v_repl, 'components_closed', cardinality(v_cid),
    'unmapped_model', (select count(*) from unnest(v_m) m where m.model_key is null),
    'unmapped_status', (select count(*) from unnest(v_m) m where m.device_status_key is null),
    'unmapped_market', (select count(*) from unnest(v_m) m where m.market is null),
    'unmapped_language', (select count(*) from unnest(v_m) m where m.language is null and m.raw ? 'language'),
    'customer_ref_invalid', (select count(*) from unnest(v_m) m where m.customer_ref_invalid),
    'refs_dropped', (select coalesce(sum(m.refs_dropped), 0) from unnest(v_m) m),
    'map_ms', v_map, 'upsert_ms', v_ups, 'components_ms', v_cmp, 'missing_ms', v_mis);
exception when check_violation or not_null_violation or foreign_key_violation then
  raise exception 'invalid device: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- As 116, the staged batch read with the two columns
-- based on: 116_asset_sync_load.sql
create or replace function cma.device_snapshot_apply(p_batch_key text, p_connection_id uuid, p_is_full boolean)
returns jsonb
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_rows   cma.device_load_row[];
  v_counts jsonb;
  v_t      timestamptz;
  v_stage  numeric;
  v_user   uuid;
begin
  -- the refusals in 0008zj's order (the load repeats them, unchanged)
  v_user := cma.assert_any_permission(array['tenant.configure', 'ingest.write']);
  perform cma.active_connection_adapter(p_connection_id);
  perform cma.assert_assets_connection(p_connection_id);
  if not cma.has_permission(v_user, 'tenant.configure')
     and (select ic.token_secret_name from cma.integration_connection ic where ic.tenant_id = v_tenant and ic.id = p_connection_id) is null then
    raise exception 'connection % has no token secret name: it is loaded from files (cma.load_device_snapshot), not by the ingest', p_connection_id
      using errcode = 'CMA04';
  end if;
  perform pg_advisory_xact_lock(hashtext('cma-device-load'), hashtext(p_connection_id::text));
  if p_is_full is null then
    raise exception 'is_full must be true (a full snapshot) or false (a partial one)' using errcode = 'CMA04';
  end if;
  if coalesce(p_batch_key, '') !~ '^[a-z0-9_-]{1,64}$' then
    raise exception 'a batch key is 1 to 64 lower-case letters, digits, - and _' using errcode = 'CMA04';
  end if;
  v_t := clock_timestamp();
  select array_agg(row(s.source_row, s.source_id, s.serial, s.model, s.status, s.country, s.warehouse_ref, s.customer_ref, s.subscription_ref,
                       s.order_ref, s.first_shipped_on, s.stock_received_on, s.last_shipped_on, s.warranty_until, s.end_of_life_on,
                       s.components, s.external_refs, s.pledge_ref, s.language)::cma.device_load_row order by s.source_row)
    into v_rows
  from cma.device_import_row s where s.tenant_id = v_tenant and s.batch_key = p_batch_key;
  if v_rows is null then
    raise exception 'no staged rows of batch % in the current tenant', p_batch_key using errcode = 'CMA02';
  end if;
  v_stage := round(extract(epoch from clock_timestamp() - v_t) * 1000);
  v_counts := cma.device_rows_apply(p_connection_id, v_rows, p_is_full);
  v_t := clock_timestamp();
  delete from cma.device_import_row s where s.tenant_id = v_tenant and s.batch_key = p_batch_key;
  return v_counts || jsonb_build_object('stage_ms', v_stage, 'cleanup_ms', round(extract(epoch from clock_timestamp() - v_t) * 1000));
end
$$;

-- As 116, the chunk's rows with the two keys: allowed, each at most 500 characters, an @ kept as a bare @; a row
-- without them reads both as empty
-- based on: 116_asset_sync_load.sql
create or replace function cma.ingest_load_device_chunk(p_connection_id uuid, p_rows jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_rows  cma.device_load_row[];
  v_t     timestamptz;
  v_n     integer;
  v_bad   text;
  v_stage numeric;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  perform cma.assert_assets_connection(p_connection_id);
  if (select c.token_secret_name from cma.integration_connection c
      where c.tenant_id = cma.current_tenant_id() and c.id = p_connection_id) is null then
    raise exception 'connection % has no token secret name: it is loaded from files (cma.load_device_snapshot), not by the ingest', p_connection_id
      using errcode = 'CMA04';
  end if;
  v_t := clock_timestamp();
  v_n := case when jsonb_typeof(p_rows) = 'array' then jsonb_array_length(p_rows) end;
  if v_n is null or v_n not between 1 and 5000
     or exists (select 1 from jsonb_array_elements(p_rows) e where jsonb_typeof(e) <> 'object') then
    raise exception 'a chunk is a JSON array of 1 to 5,000 row objects' using errcode = 'CMA04';
  end if;
  -- the staging's columns only; the line a whole number from 2 to 10,000,000, as the staging takes it
  select string_agg(distinct k, ', ' order by k) into v_bad
  from jsonb_array_elements(p_rows) e, jsonb_object_keys(e) k
  where k not in ('source_row', 'source_id', 'serial', 'model', 'status', 'country', 'warehouse_ref', 'customer_ref', 'subscription_ref',
                  'order_ref', 'first_shipped_on', 'stock_received_on', 'last_shipped_on', 'warranty_until', 'end_of_life_on',
                  'components', 'external_refs', 'pledge_ref', 'language');
  if v_bad is not null then
    raise exception 'a chunk''s rows hold the staging''s columns only, not %', left(v_bad, 200) using errcode = 'CMA04';
  end if;
  if exists (select 1 from jsonb_array_elements(p_rows) e
             where jsonb_typeof(e -> 'source_row') <> 'null'
               and (jsonb_typeof(e -> 'source_row') <> 'number' or (e ->> 'source_row') !~ '^\d{1,8}$'
                    or (e ->> 'source_row')::integer not between 2 and 10000000)) then
    raise exception 'a chunk''s source_row is a whole number from 2 to 10,000,000' using errcode = 'CMA04';
  end if;
  select array_agg(row(r.source_row, cma.device_staged_without_at(r.source_id), cma.device_staged_without_at(r.serial),
                       cma.device_staged_without_at(r.model), cma.device_staged_without_at(r.status), cma.device_staged_without_at(r.country),
                       cma.device_staged_without_at(r.warehouse_ref), cma.device_staged_without_at(r.customer_ref),
                       cma.device_staged_without_at(r.subscription_ref), cma.device_staged_without_at(r.order_ref),
                       cma.device_staged_without_at(r.first_shipped_on), cma.device_staged_without_at(r.stock_received_on),
                       cma.device_staged_without_at(r.last_shipped_on), cma.device_staged_without_at(r.warranty_until),
                       cma.device_staged_without_at(r.end_of_life_on),
                       case when strpos(coalesce(r.components, ''), '@') > 0 then cma.device_staged_object_without_at(r.components) else r.components end,
                       case when strpos(coalesce(r.external_refs, ''), '@') > 0 then cma.device_staged_object_without_at(r.external_refs) else r.external_refs end,
                       cma.device_staged_without_at(r.pledge_ref), cma.device_staged_without_at(r.language)
                      )::cma.device_load_row order by r.source_row)
    into v_rows
  from jsonb_populate_recordset(null::cma.device_load_row, p_rows) r;
  -- the staging's lengths, before anything is read further (the first row by line, its first column)
  select format('line %s: %s is longer than the staging takes', coalesce(r.source_row::text, '?'), x.col) into v_bad
  from unnest(v_rows) r
  cross join lateral (values (1, 'source_id', length(r.source_id) > 500), (2, 'serial', length(r.serial) > 500),
                             (3, 'model', length(r.model) > 500), (4, 'status', length(r.status) > 500),
                             (5, 'country', length(r.country) > 500), (6, 'warehouse_ref', length(r.warehouse_ref) > 500),
                             (7, 'customer_ref', length(r.customer_ref) > 500), (8, 'subscription_ref', length(r.subscription_ref) > 500),
                             (9, 'order_ref', length(r.order_ref) > 500), (10, 'first_shipped_on', length(r.first_shipped_on) > 40),
                             (11, 'stock_received_on', length(r.stock_received_on) > 40), (12, 'last_shipped_on', length(r.last_shipped_on) > 40),
                             (13, 'warranty_until', length(r.warranty_until) > 40), (14, 'end_of_life_on', length(r.end_of_life_on) > 40),
                             (15, 'components', length(r.components) > 4000), (16, 'external_refs', length(r.external_refs) > 4000),
                             (17, 'pledge_ref', length(r.pledge_ref) > 500), (18, 'language', length(r.language) > 500)) as x(n, col, too_long)
  where x.too_long
  order by r.source_row, x.n
  limit 1;
  if v_bad is not null then
    raise exception '%', v_bad using errcode = 'CMA04';
  end if;
  v_stage := round(extract(epoch from clock_timestamp() - v_t) * 1000);
  return cma.device_rows_apply(p_connection_id, v_rows, false) || jsonb_build_object('stage_ms', v_stage);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The register's two fields as configuration
-- ---------------------------------------------------------------------------------------------
-- As 0008zt (136), with pledge_ref as a field, and pledge_ref and language among an asset register's device fields
alter table cma.connection_field drop constraint if exists connection_field_field_check;
alter table cma.connection_field add constraint connection_field_field_check
  check (field = any (array['market', 'language', 'country', 'currency', 'store', 'amount', 'source_channel', 'category', 'ref', 'created_at',
                            'reason', 'serial', 'model', 'status', 'warehouse_ref', 'customer_ref', 'subscription_ref', 'order_ref',
                            'first_shipped_on', 'stock_received_on', 'last_shipped_on', 'warranty_until', 'end_of_life_on', 'expires_on',
                            'segment', 'pledge_ref']));
alter table cma.connection_field drop constraint if exists connection_field_entity_field_check;
alter table cma.connection_field add constraint connection_field_entity_field_check
  check (case when entity = 'contact' then field = any (array['country', 'language', 'currency', 'store', 'ref', 'created_at', 'segment'])
              when entity = 'device' then field = any (array['serial', 'model', 'status', 'country', 'warehouse_ref', 'customer_ref',
                                                             'subscription_ref', 'order_ref', 'first_shipped_on', 'stock_received_on',
                                                             'last_shipped_on', 'warranty_until', 'end_of_life_on', 'ref', 'pledge_ref',
                                                             'language'])
              when entity = 'device_component' then field = any (array['serial', 'expires_on'])
              when field = 'reason' then entity in ('deal', 'ticket')
              else field = any (array['market', 'language', 'currency', 'amount', 'source_channel', 'category']) end);

-- ---------------------------------------------------------------------------------------------
-- 6. The loan catalog, the values per model and the settings (tenant configuration)
-- ---------------------------------------------------------------------------------------------
-- A tab name's part: trimmed, no control character and none of the characters a spreadsheet's tab name refuses
-- ([ ] : * ? / \); with p_apostrophe false no ' either (a tab name cannot end with one)
create or replace function cma.pledge_label_ok(p_value text, p_max integer, p_apostrophe boolean)
returns boolean
language sql immutable
as $$
  select p_value is not null and p_value = btrim(p_value) and length(p_value) between 1 and p_max
     and p_value !~ '[[:cntrl:]]' and translate(p_value, '[]:*?/\', '') = p_value
     and (p_apostrophe or strpos(p_value, '''') = 0)
$$;

-- The audit image of a loan keeps no lender label (D8): as 0008zi (112) left cma.audit_row(), plus a branch for
-- cma.pledge_loan that leaves lender_label out of both images and, on an update, says whether it changed
-- based on: 112_assets.sql
create or replace function cma.audit_row()
returns trigger
language plpgsql
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
begin
  if tg_op = 'DELETE' and tg_table_schema = 'cma'
     and tg_table_name in ('telephony_call', 'telephony_call_tag', 'call_link')
     and coalesce(current_setting('cma.audit_keys_only', true), '') = 'uncounted_line' then
    v_old := jsonb_strip_nulls(jsonb_build_object(
      'id', v_old -> 'id', 'tenant_id', v_old -> 'tenant_id', 'connection_id', v_old -> 'connection_id',
      'source_id', v_old -> 'source_id', 'call_source_id', v_old -> 'call_source_id', 'tag_ref', v_old -> 'tag_ref',
      'telephony_call_id', v_old -> 'telephony_call_id', 'crm_call_id', v_old -> 'crm_call_id',
      'reason', 'uncounted_line'));
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'invitation' then
    v_old := v_old - 'token_hash';
    v_new := v_new - 'token_hash';
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'ingest_event' then
    v_old := v_old - 'raw';
    v_new := v_new - 'raw';
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'review' then
    v_old := cma.review_image_without_at_reference(v_old);
    v_new := cma.review_image_without_at_reference(v_new);
  end if;
  -- 0009j: a loan's lender label is an investor's name (D8): never in the log. Both images leave it out; a change of it
  -- is recorded as changed, never as its value
  if tg_table_schema = 'cma' and tg_table_name = 'pledge_loan' then
    if v_old is not null and v_new is not null then
      v_new := v_new || jsonb_build_object('lender_label_changed', (v_old ->> 'lender_label') is distinct from (v_new ->> 'lender_label'));
    end if;
    v_old := v_old - 'lender_label';
    v_new := v_new - 'lender_label';
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'device_import_row' then
    v_old := case when v_old is not null then jsonb_build_object('id', v_old -> 'id', 'tenant_id', v_old -> 'tenant_id',
                                                                 'batch_key', v_old -> 'batch_key', 'source_row', v_old -> 'source_row') end;
    v_new := case when v_new is not null then jsonb_build_object('id', v_new -> 'id', 'tenant_id', v_new -> 'tenant_id',
                                                                 'batch_key', v_new -> 'batch_key', 'source_row', v_new -> 'source_row') end;
  end if;
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  values (
    (coalesce(v_new, v_old) ->> 'tenant_id')::uuid,
    tg_table_name,
    lower(tg_op),
    v_old,
    v_new,
    cma.current_user_id(),
    cma.current_actor_label()
  );
  return null;   -- after trigger, return value is ignored
end
$$;

create table if not exists cma.pledge_loan (
  id            uuid primary key default uuidv7(),
  tenant_id     uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key           text not null check (key ~ '^[A-Za-z0-9#][A-Za-z0-9 _.#:/-]{0,99}$'),
  number        integer not null check (number between 1 and 999),
  lender_label  text not null check (cma.pledge_label_ok(lender_label, 60, true) and strpos(lender_label, '@') = 0),
  area_label    text not null check (cma.pledge_label_ok(area_label, 10, false)),
  name_suffix   text not null check (cma.pledge_label_ok(name_suffix, 20, false)),
  layout        smallint not null check (layout in (1, 2)),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, key),
  unique (tenant_id, number)
);
comment on table cma.pledge_loan is 'The loans devices secure (Assets → Pledge lists): the register''s loan reference (key), the loan''s number (LOAN SPV and the tab prefix), the tab name''s parts and the file''s layout. The lender label is an investor''s personal data: set in Studio only. Tenant configuration (0009j)';
comment on column cma.pledge_loan.key is 'The value of cma.device.pledge_ref that names this loan (Pulse4all: the option name of maatje_id, such as 2)';
comment on column cma.pledge_loan.number is 'The loan''s number: the file''s LOAN SPV and its tabs'' prefix (1 to 999)';
comment on column cma.pledge_loan.lender_label is 'The lender''s name in the tab names (1 to 60 characters, no @ and none of [ ] : * ? / \); personal data, never in the repository, a seed, a fixture, a log or a record (D8): cma.audit_row() leaves it out of the audit images. A quarter file keeps its copy, frozen (cma.pledge_snapshot_row)';
comment on column cma.pledge_loan.layout is 'The column order of the loan''s a- and b-tabs: 1 or 2, as the original file lays them out';
comment on column cma.pledge_loan.is_active is 'false: the loan''s devices are left out of the files and the checks (a repaid loan)';
create or replace trigger set_updated_at before update on cma.pledge_loan
  for each row execute function cma.set_updated_at();
select cma.setup_tenant_table('cma.pledge_loan');

create table if not exists cma.pledge_model_value (
  id                      uuid primary key default uuidv7(),
  tenant_id               uuid not null default cma.current_tenant_id() references cma.tenant (id),
  model_key               text not null,
  type_label              text not null check (type_label = btrim(type_label) and length(type_label) between 1 and 20 and type_label !~ '[[:cntrl:]@]'),
  acquisition_value       numeric(12,2) not null check (acquisition_value >= 0),
  depreciation_per_month  numeric(10,2) not null check (depreciation_per_month >= 0),
  receipts                numeric(10,2) not null check (receipts >= 0),
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, model_key),
  foreign key (tenant_id, model_key) references cma.device_model (tenant_id, key)
);
comment on table cma.pledge_model_value is 'The pledge values per device model: the Type AED text, the acquisition value, the depreciation per month and the receipts, in EUR as the file states them. Tenant configuration (0009j)';
comment on column cma.pledge_model_value.receipts is 'A configured amount per model (Receipts (in EUR - incl BTW)), never collected payments';
create or replace trigger set_updated_at before update on cma.pledge_model_value
  for each row execute function cma.set_updated_at();
select cma.setup_tenant_table('cma.pledge_model_value');

-- Sets a loan by its key (tenant.configure): the key as the register writes it (trimmed, an id), the number, the three
-- labels (trimmed), the layout and whether it is active. Answers the loan's id. CMA04 for a value outside its checks,
-- CMA03 for a number another key holds
create or replace function cma.set_pledge_loan(p_key text, p_number integer, p_lender_label text, p_area_label text, p_name_suffix text,
                                               p_layout integer, p_is_active boolean default true)
returns uuid
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_key    text := btrim(coalesce(p_key, ''));
  v_id     uuid;
begin
  perform cma.assert_permission('tenant.configure');
  if v_key !~ '^[A-Za-z0-9#][A-Za-z0-9 _.#:/-]{0,99}$' then
    raise exception 'a loan''s key is the register''s loan reference, an id of 1 to 100 characters' using errcode = 'CMA04';
  end if;
  if p_number is null or p_number not between 1 and 999 then
    raise exception 'a loan''s number is a whole number from 1 to 999' using errcode = 'CMA04';
  end if;
  if not coalesce(cma.pledge_label_ok(btrim(p_lender_label), 60, true) and strpos(p_lender_label, '@') = 0, false) then
    raise exception 'a lender label is 1 to 60 characters without an @ or any of [ ] : * ? / \' using errcode = 'CMA04';
  end if;
  if not coalesce(cma.pledge_label_ok(btrim(p_area_label), 10, false), false) then
    raise exception 'an area label is 1 to 10 characters without an apostrophe or any of [ ] : * ? / \' using errcode = 'CMA04';
  end if;
  if not coalesce(cma.pledge_label_ok(btrim(p_name_suffix), 20, false), false) then
    raise exception 'a name suffix is 1 to 20 characters without an apostrophe or any of [ ] : * ? / \' using errcode = 'CMA04';
  end if;
  if p_layout is null or p_layout not in (1, 2) then
    raise exception 'a loan''s layout is 1 or 2' using errcode = 'CMA04';
  end if;
  if exists (select 1 from cma.pledge_loan l where l.tenant_id = v_tenant and l.number = p_number and l.key <> v_key) then
    raise exception 'loan number % is another key''s already', p_number using errcode = 'CMA03';
  end if;
  insert into cma.pledge_loan (tenant_id, key, number, lender_label, area_label, name_suffix, layout, is_active)
  values (v_tenant, v_key, p_number, btrim(p_lender_label), btrim(p_area_label), btrim(p_name_suffix), p_layout, coalesce(p_is_active, true))
  on conflict (tenant_id, key) do update
    set number = excluded.number, lender_label = excluded.lender_label, area_label = excluded.area_label,
        name_suffix = excluded.name_suffix, layout = excluded.layout, is_active = excluded.is_active
  returning id into v_id;
  return v_id;
end
$$;

-- Sets a model's pledge values (tenant.configure): the model a key of the tenant's catalog (CMA02 otherwise), the Type
-- AED text (1 to 20 characters), and the three amounts, each 0 or more with at most two decimals (CMA04 otherwise).
-- Answers the row's id
create or replace function cma.set_pledge_model_value(p_model_key text, p_type_label text, p_acquisition_value numeric,
                                                      p_depreciation_per_month numeric, p_receipts numeric)
returns uuid
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_id     uuid;
begin
  perform cma.assert_permission('tenant.configure');
  if not exists (select 1 from cma.device_model m where m.tenant_id = v_tenant and m.key = p_model_key) then
    raise exception 'no device model % in the catalog', coalesce(p_model_key, '(none)') using errcode = 'CMA02';
  end if;
  if btrim(coalesce(p_type_label, '')) = '' or length(btrim(p_type_label)) > 20 or p_type_label ~ '[[:cntrl:]@]' then
    raise exception 'a Type AED text is 1 to 20 characters' using errcode = 'CMA04';
  end if;
  if p_acquisition_value is null or p_acquisition_value < 0 or p_acquisition_value <> round(p_acquisition_value, 2) or p_acquisition_value >= 10000000000
     or p_depreciation_per_month is null or p_depreciation_per_month < 0 or p_depreciation_per_month <> round(p_depreciation_per_month, 2)
     or p_depreciation_per_month >= 100000000
     or p_receipts is null or p_receipts < 0 or p_receipts <> round(p_receipts, 2) or p_receipts >= 100000000 then
    raise exception 'the values are amounts of 0 or more with at most two decimals' using errcode = 'CMA04';
  end if;
  insert into cma.pledge_model_value (tenant_id, model_key, type_label, acquisition_value, depreciation_per_month, receipts)
  values (v_tenant, p_model_key, btrim(p_type_label), p_acquisition_value, p_depreciation_per_month, p_receipts)
  on conflict (tenant_id, model_key) do update
    set type_label = excluded.type_label, acquisition_value = excluded.acquisition_value,
        depreciation_per_month = excluded.depreciation_per_month, receipts = excluded.receipts
  returning id into v_id;
  return v_id;
end
$$;

insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('pledges.snapshot_local_time', 'time', null, '00:05',
     'The time in the tenant''s zone from which a quarter''s pledge-list file is taken on the quarter''s first day (1 January, 1 April, 1 July, 1 October), valued at that day (00:00 to 23:59)'),
  ('pledges.file_name_prefix', 'text', null, 'Pledge_Lists',
     'The start of a pledge-list file''s name, before _<Month>_<year>.xlsx: 1 to 60 letters, digits, _ and -')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- Their forms, checked beside cma.check_tenant_setting() (its branches unchanged), as 132's data-quality setting
create or replace function cma.check_pledges_setting()
returns trigger
language plpgsql
as $$
begin
  if new.key = 'pledges.snapshot_local_time' and new.value = '24:00' then
    raise exception 'Setting % takes a time from 00:00 to 23:59', new.key using errcode = 'CMA04';
  elsif new.key = 'pledges.file_name_prefix' and new.value !~ '^[A-Za-z0-9_-]{1,60}$' then
    raise exception 'Setting % takes 1 to 60 letters, digits, _ and -', new.key using errcode = 'CMA04';
  end if;
  return new;
end
$$;
revoke execute on function cma.check_pledges_setting() from public;
drop trigger if exists check_pledges_setting on cma.tenant_setting;
create trigger check_pledges_setting before insert or update on cma.tenant_setting
  for each row execute function cma.check_pledges_setting();

-- ---------------------------------------------------------------------------------------------
-- 7. The permissions and the scheduler
-- ---------------------------------------------------------------------------------------------
insert into cma.permission (key, description) values
  ('pledges.view', 'See Assets → Pledge lists and download its quarter files and today''s version (no default role: granted through a role, D7)'),
  ('pledges.snapshot', 'Take the quarter''s pledge-list file on the quarter''s first day (the scheduler''s system user only; no default role)')
on conflict (key) do update set description = excluded.description;

-- 0005a's scheduler user, now with its five permissions
-- based on: 132_perf.sql
create or replace function cma.ensure_scheduler_user(p_tenant_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_role uuid;
  v_user uuid;
begin
  insert into cma.app_role (tenant_id, key, name, is_system, is_assignable)
  values (p_tenant_id, 'scheduler', 'Scheduler', true, false)
  on conflict (tenant_id, key) do update set is_assignable = false, is_system = true
  returning id into v_role;
  if v_role is null then
    select id into v_role from cma.app_role where tenant_id = p_tenant_id and key = 'scheduler';
  end if;
  insert into cma.role_permission (tenant_id, role_id, permission_key)
  values (p_tenant_id, v_role, 'workday.close_forgotten'), (p_tenant_id, v_role, 'follow_up.refresh'), (p_tenant_id, v_role, 'flash.snapshot'),
         (p_tenant_id, v_role, 'data_quality.refresh'), (p_tenant_id, v_role, 'pledges.snapshot')
  on conflict do nothing;

  insert into cma.app_user (tenant_id, email, display_name, status, kind)
  values (p_tenant_id, 'scheduler@system.invalid', 'Scheduler', 'active', 'system')
  on conflict (tenant_id, email) do update set kind = 'system', status = 'active'
  returning id into v_user;
  if v_user is null then
    select id into v_user from cma.app_user where tenant_id = p_tenant_id and email = 'scheduler@system.invalid';
  end if;
  insert into cma.user_role (tenant_id, user_id, role_id)
  values (p_tenant_id, v_user, v_role)
  on conflict do nothing;
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
  values (p_tenant_id, v_user, 'scheduler', 'scheduler')
  on conflict do nothing;
  return v_user;
end
$$;
revoke execute on function cma.ensure_scheduler_user(uuid) from public;

do $$
declare
  t record;
begin
  for t in select id from cma.tenant loop
    perform cma.ensure_scheduler_user(t.id);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. The rows: one implementation for the page, the take and today's file
-- ---------------------------------------------------------------------------------------------
-- The subscriptions a device's subscription reference can name, by Installed base's rule (cma.flash_devices_of, 136):
-- the register names no connection, so a reference is matched among the subscriptions the CMA holds (not missing from
-- the latest full read) of the stores of the device's market, the first by id when two share it
create or replace function cma.linkable_subscriptions_of(p_tenant_id uuid)
returns table (market text, source_id text, subscription_id uuid, status text, source_created_at timestamptz)
language sql stable
rows 1000
as $$
  select distinct on (sm.market, x.source_id) sm.market, x.source_id, x.id, x.status, x.source_created_at
  from cma.subscription x
  join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = x.connection_id
  where x.tenant_id = p_tenant_id and x.source_deleted_at is null
  order by sm.market, x.source_id, x.id
$$;

-- Whole months from the first shipment to the valuation date (age's years × 12 + months); 0 without a first shipment
-- or with one after the valuation date
create or replace function cma.pledge_months_of(p_first_shipped_on date, p_valuation_date date)
returns integer
language sql immutable
as $$
  select case when p_first_shipped_on is null or p_valuation_date is null or p_first_shipped_on > p_valuation_date then 0
              else (extract(year from age(p_valuation_date, p_first_shipped_on)) * 12
                    + extract(month from age(p_valuation_date, p_first_shipped_on)))::integer end
$$;

-- The current value: acquisition less months × depreciation, two decimals, never below 0; null without values
create or replace function cma.pledge_current_value_of(p_acquisition numeric, p_depreciation numeric, p_months integer)
returns numeric
language sql immutable
as $$
  select case when p_acquisition is null or p_depreciation is null then null
              else round(greatest(0, p_acquisition - coalesce(p_months, 0) * p_depreciation), 2) end
$$;

-- Every device the register still holds whose loan reference is an active loan's key, as the file's rows (see the
-- header). customer_id: the customer reference, In Storage when the register holds none, null for a reference that is
-- no id (customer_ref_invalid: a check before the next file). start_date: the linked subscription's creation date in the
-- tenant's zone, only for a device with a customer reference. The values null for a model without pledge values (a check).
-- checks: the checks before the next file the device fails, each rule here once (no_model_values, no_first_shipped,
-- no_language, customer_ref_invalid, no_start_date; unknown_loan is a device's without a row, cma.pledge_unknown_loans_of)
create or replace function cma.pledge_rows_of(p_tenant_id uuid, p_valuation_date date)
returns table (device_id uuid, source_id text, loan_number integer, loan_key text, serial text, type_label text, market text,
               language text, customer_id text, start_date date, first_shipped_on date, months_depreciating integer,
               depreciation_per_month numeric, acquisition_value numeric, receipts numeric, current_value numeric,
               customer_ref_invalid boolean, has_values boolean, subscription_ref text, language_label text, model_key text, checks text[])
language sql stable
rows 1000
as $$
  with d as materialized (
    select dv.id, dv.source_id, dv.serial, dv.model_key, dv.market, dv.language, dv.customer_ref, dv.customer_ref_invalid,
           dv.subscription_ref, dv.first_shipped_on, dv.raw ->> 'language' as language_label, l.number, l.key
    from cma.device dv
    join cma.pledge_loan l on l.tenant_id = dv.tenant_id and l.key = dv.pledge_ref and l.is_active
    where dv.tenant_id = p_tenant_id and dv.pledge_ref is not null and dv.source_deleted_at is null
  ), sub as materialized (
    select s.market, s.source_id, s.source_created_at
    from cma.linkable_subscriptions_of(p_tenant_id) s
  ), z as (
    select t.timezone as zone from cma.tenant t where t.id = p_tenant_id
  )
  select d.id, d.source_id, d.number, d.key, d.serial, mv.type_label, d.market, upper(d.language),
         case when d.customer_ref is not null then d.customer_ref when not d.customer_ref_invalid then 'In Storage' end,
         case when d.customer_ref is not null then (sub.source_created_at at time zone (select z.zone from z))::date end,
         d.first_shipped_on, cma.pledge_months_of(d.first_shipped_on, p_valuation_date),
         mv.depreciation_per_month, mv.acquisition_value, mv.receipts,
         cma.pledge_current_value_of(mv.acquisition_value, mv.depreciation_per_month, cma.pledge_months_of(d.first_shipped_on, p_valuation_date)),
         d.customer_ref_invalid, mv.model_key is not null, d.subscription_ref, d.language_label, d.model_key,
         array_remove(array[case when mv.model_key is null then 'no_model_values' end,
                            case when d.first_shipped_on is null then 'no_first_shipped' end,
                            case when d.language is null then 'no_language' end,
                            case when d.customer_ref_invalid then 'customer_ref_invalid' end,
                            case when d.customer_ref is not null and sub.source_created_at is null then 'no_start_date' end], null)
  from d
  left join cma.pledge_model_value mv on mv.tenant_id = p_tenant_id and mv.model_key = d.model_key
  left join sub on sub.market = d.market and sub.source_id = d.subscription_ref
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. The quarter files: frozen
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.pledge_snapshot (
  id              uuid primary key default uuidv7(),
  tenant_id       uuid not null default cma.current_tenant_id() references cma.tenant (id),
  valuation_date  date not null check (extract(day from valuation_date) = 1 and extract(month from valuation_date) in (1, 4, 7, 10)),
  taken_at        timestamptz not null default now(),
  taken_by        uuid not null,
  loans           integer not null check (loans >= 0),
  devices         integer not null check (devices between 0 and 50000),
  file_name_prefix text not null default 'Pledge_Lists' check (file_name_prefix ~ '^[A-Za-z0-9_-]{1,60}$'),
  sources         jsonb not null default '{}'::jsonb check (jsonb_typeof(sources) = 'object' and strpos(sources::text, '@') = 0),
  unique (tenant_id, id),
  unique (tenant_id, valuation_date),
  foreign key (tenant_id, taken_by) references cma.app_user (tenant_id, id)
);
comment on table cma.pledge_snapshot is 'A quarter file of the pledge lists: its valuation date (a quarter''s first day), when and by whom it was taken, its loans and devices, and the sources'' last reads at the take (cma.flash_sources_of). Written by the take only; frozen (0009j)';
comment on column cma.pledge_snapshot.file_name_prefix is 'pledges.file_name_prefix at the take: the file''s name stays the one it was taken with';
comment on column cma.pledge_snapshot.taken_by is 'The acting user of the take: the scheduler''s system user, or the person who ran cma.pledge_snapshot_take_current()';

create table if not exists cma.pledge_snapshot_row (
  id                      uuid primary key default uuidv7(),
  tenant_id               uuid not null default cma.current_tenant_id() references cma.tenant (id),
  snapshot_id             uuid not null,
  valuation_date          date not null,
  loan_number             integer not null check (loan_number between 1 and 999),
  lender_label            text not null,
  area_label              text not null,
  name_suffix             text not null,
  layout                  smallint not null check (layout in (1, 2)),
  serial                  text,
  type_label              text,
  market                  text,
  language                text check (language ~ '^[A-Z]{2}$'),
  customer_id             text,
  start_date              date,
  first_shipped_on        date,
  months_depreciating     integer not null check (months_depreciating >= 0),
  depreciation_per_month  numeric(10,2),
  acquisition_value       numeric(12,2),
  receipts                numeric(10,2),
  current_value           numeric(12,2),
  unique (tenant_id, id),
  foreign key (tenant_id, snapshot_id) references cma.pledge_snapshot (tenant_id, id) deferrable initially deferred
);
comment on table cma.pledge_snapshot_row is 'A quarter file''s rows as cma.pledge_rows_of gave them at the take, with the loan''s number, lender label, area label, name suffix and layout copied in, so a later catalog change never alters an old file. Written by the take only; frozen; not audited row by row (0009j)';
create index if not exists pledge_snapshot_row_file_idx on cma.pledge_snapshot_row (tenant_id, snapshot_id, loan_number, serial);

select cma.setup_tenant_table('cma.pledge_snapshot');
select cma.setup_tenant_table('cma.pledge_snapshot_row');
-- The rows copy the lender labels and are written in bulk once a quarter: no row image per row in the append-only audit
-- log (the header's audit row carries the counts), as Flash's id lists
drop trigger if exists audit on cma.pledge_snapshot_row;
-- Read only for the application: the take, with the owner's rights, is the one writer
revoke insert, update, delete on cma.pledge_snapshot, cma.pledge_snapshot_row from cma_app;

-- Frozen: no update, delete or truncate, whoever asks (a deliberate removal is an operator's act outside the
-- application: disabling this trigger in a session of its own). A trigger function: nobody gets execute
create or replace function cma.pledge_snapshot_frozen()
returns trigger
language plpgsql
as $$
begin
  raise exception 'a quarter file is frozen: % on % is refused', lower(tg_op), tg_table_name using errcode = 'CMA03';
end
$$;
revoke execute on function cma.pledge_snapshot_frozen() from public;
drop trigger if exists frozen on cma.pledge_snapshot;
create trigger frozen before update or delete on cma.pledge_snapshot
  for each row execute function cma.pledge_snapshot_frozen();
drop trigger if exists frozen_truncate on cma.pledge_snapshot;
create trigger frozen_truncate before truncate on cma.pledge_snapshot
  for each statement execute function cma.pledge_snapshot_frozen();
drop trigger if exists frozen on cma.pledge_snapshot_row;
create trigger frozen before update or delete on cma.pledge_snapshot_row
  for each row execute function cma.pledge_snapshot_frozen();
drop trigger if exists frozen_truncate on cma.pledge_snapshot_row;
create trigger frozen_truncate before truncate on cma.pledge_snapshot_row
  for each statement execute function cma.pledge_snapshot_frozen();

-- ---------------------------------------------------------------------------------------------
-- 10. The take
-- ---------------------------------------------------------------------------------------------
-- The file of a valuation date, written once under the tenant's lock (the owner's alone: the takes below call it with
-- their own permission checked; it checks again, as Flash's writers do: pledges.snapshot or tenant.configure, and the
-- session's tenant). Answers taken (with loans and devices), already_taken (the file held, its counts) or no_pledges (no
-- row: no active loan or no pledged device the register holds); CMA04 above 50,000 rows
create or replace function cma.pledge_snapshot_write(p_tenant_id uuid, p_valuation_date date)
returns jsonb
language plpgsql
as $$
declare
  v_snap  uuid := uuidv7();
  v_user  uuid := cma.current_user_id();
  v_rows  integer;
  v_loans integer;
  s       record;
begin
  perform cma.assert_any_permission(array['pledges.snapshot', 'tenant.configure']);
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a quarter file is taken for the current tenant only' using errcode = 'CMA06';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_tenant_id::text || '/pledge_snapshot', 0));
  select x.id, x.taken_at, x.loans, x.devices into s from cma.pledge_snapshot x
  where x.tenant_id = p_tenant_id and x.valuation_date = p_valuation_date;
  if found then
    return jsonb_build_object('answer', 'already_taken', 'valuation_date', p_valuation_date, 'taken_at', s.taken_at,
                              'loans', s.loans, 'devices', s.devices);
  end if;
  -- the rows first (their key to the header is checked at the commit), then the header with their counts
  with ins as (
    insert into cma.pledge_snapshot_row (tenant_id, snapshot_id, valuation_date, loan_number, lender_label, area_label, name_suffix, layout,
                                         serial, type_label, market, language, customer_id, start_date, first_shipped_on,
                                         months_depreciating, depreciation_per_month, acquisition_value, receipts, current_value)
    select p_tenant_id, v_snap, p_valuation_date, r.loan_number, l.lender_label, l.area_label, l.name_suffix, l.layout,
           r.serial, r.type_label, r.market, r.language, r.customer_id, r.start_date, r.first_shipped_on, r.months_depreciating,
           r.depreciation_per_month, r.acquisition_value, r.receipts, r.current_value
    from cma.pledge_rows_of(p_tenant_id, p_valuation_date) r
    join cma.pledge_loan l on l.tenant_id = p_tenant_id and l.number = r.loan_number
    returning loan_number
  )
  select count(*), count(distinct ins.loan_number) into v_rows, v_loans from ins;
  if v_rows = 0 then
    return jsonb_build_object('answer', 'no_pledges', 'valuation_date', p_valuation_date);
  end if;
  if v_rows > 50000 then
    raise exception 'a pledge-list file holds at most 50,000 rows, this one % (nothing taken)', v_rows using errcode = 'CMA04';
  end if;
  insert into cma.pledge_snapshot (id, tenant_id, valuation_date, taken_at, taken_by, loans, devices, file_name_prefix, sources)
  values (v_snap, p_tenant_id, p_valuation_date, now(), v_user, v_loans, v_rows, cma.setting_of(p_tenant_id, 'pledges.file_name_prefix'),
          cma.flash_sources_of(p_tenant_id));
  return jsonb_build_object('answer', 'taken', 'valuation_date', p_valuation_date, 'taken_at', now(), 'loans', v_loans, 'devices', v_rows);
end
$$;

-- The quarter's take as of an instant (the owner's alone; the job's entry passes now): pledges.snapshot and the current
-- tenant first; then, in the tenant's zone, the local date a quarter's first day and the local time at or past
-- pledges.snapshot_local_time, else not_due; then the day's file once
create or replace function cma.pledge_snapshot_take_at(p_tenant_id uuid, p_now timestamptz)
returns jsonb
language plpgsql
as $$
declare
  v_zone  text;
  v_local timestamp;
  v_time  time;
begin
  perform cma.assert_permission('pledges.snapshot');
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a quarter file is taken for the current tenant only' using errcode = 'CMA06';
  end if;
  -- an instant other than now is the owner's alone (169): the application can never take a day that has not come
  if p_now is null or (p_now is distinct from now() and current_user <> 'cma_owner') then
    raise exception 'a quarter file is taken as of now' using errcode = 'CMA06';
  end if;
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  v_local := p_now at time zone v_zone;
  v_time := cma.setting_of(p_tenant_id, 'pledges.snapshot_local_time')::time;
  if extract(day from v_local) <> 1 or extract(month from v_local) not in (1, 4, 7, 10) or v_local::time < v_time then
    return jsonb_build_object('answer', 'not_due', 'local_date', v_local::date);
  end if;
  return cma.pledge_snapshot_write(p_tenant_id, v_local::date);
end
$$;

-- The job's entry (pledges.snapshot): the current tenant, as of now. SECURITY DEFINER, owned by cma_owner, search path
-- pinned, executable by the application only: the application holds no write on the two tables, so this and
-- cma.pledge_snapshot_take_current are the only ways a file is ever written
create or replace function cma.pledge_snapshot_take(p_tenant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, cma, pg_temp
as $$
begin
  perform cma.assert_permission('pledges.snapshot');
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a quarter file is taken for the current tenant only' using errcode = 'CMA06';
  end if;
  return cma.pledge_snapshot_take_at(p_tenant_id, now());
end
$$;

-- The current quarter's first day once (tenant.configure; SECURITY DEFINER as the take): valued at that day, from the
-- mirrors as they are now. For the first comparison with the quarter's file sent by hand, and after a first day the job
-- missed. Answers taken, already_taken or no_pledges
create or replace function cma.pledge_snapshot_take_current()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, cma, pg_temp
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('tenant.configure');
  return cma.pledge_snapshot_write(v_tenant, date_trunc('quarter', cma.tenant_today_of(v_tenant))::date);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 11. The reads (pledges.view)
-- ---------------------------------------------------------------------------------------------
-- The devices the register holds whose loan reference no loan of the catalog has as its key (the check unknown_loan),
-- with the reference; an inactive loan's are no finding (the loan is in the catalog)
create or replace function cma.pledge_unknown_loans_of(p_tenant_id uuid)
returns table (serial text, source_id text, pledge_ref text)
language sql stable
rows 100
as $$
  select dv.serial, dv.source_id, dv.pledge_ref
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.pledge_ref is not null and dv.source_deleted_at is null
    and not exists (select 1 from cma.pledge_loan l where l.tenant_id = p_tenant_id and l.key = dv.pledge_ref)
$$;

-- The checks before the next file, each row a device and a check it fails: unknown_loan (cma.pledge_unknown_loans_of;
-- the reference as its value), and of the pledged devices (an active loan's) the checks of cma.pledge_rows_of:
-- no_model_values (the model's key as its value, or none), no_first_shipped, no_language (the register's label, or none),
-- customer_ref_invalid (a customer reference that is no id) and no_start_date (a customer reference without a linked
-- subscription's creation date)
create or replace function cma.pledge_findings_of(p_tenant_id uuid, p_valuation_date date)
returns table (check_key text, serial text, source_id text, value text)
language sql stable
rows 100
as $$
  select 'unknown_loan', u.serial, u.source_id, u.pledge_ref from cma.pledge_unknown_loans_of(p_tenant_id) u
  union all
  select c.k, r.serial, r.source_id,
         case c.k when 'no_model_values' then r.model_key when 'no_language' then r.language_label end
  from cma.pledge_rows_of(p_tenant_id, p_valuation_date) r
  cross join lateral unnest(r.checks) as c(k)
$$;

create or replace function cma.pledge_check_keys()
returns text[]
language sql immutable
as $$
  select array['unknown_loan', 'no_model_values', 'no_first_shipped', 'no_language', 'customer_ref_invalid', 'no_start_date']
$$;

-- The page (pledges.view): files (every quarter file, the latest first: valuation date, taken at, loans, devices), today
-- (the tenant's date and per active loan with devices its number, lender label, devices, devices In Storage and the sums
-- of acquisition value, current value and receipts, as text with two decimals), checks (each check's count),
-- unmapped_languages (the register's labels of pledged devices without a code, with their counts), quarter (the current
-- quarter's first day, whether its file is held, and whether the take is due by now: a first day past, or today past
-- pledges.snapshot_local_time), file_name_prefix, is_set_up (a loan in the catalog)
create or replace function cma.pledge_page()
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_today   date;
  v_quarter date;
  v_local   timestamp;
  v_res     jsonb;
begin
  perform cma.assert_permission('pledges.view');
  v_today := cma.tenant_today_of(v_tenant);
  v_quarter := date_trunc('quarter', v_today)::date;
  v_local := now() at time zone (select t.timezone from cma.tenant t where t.id = v_tenant);
  -- the rows once: today's sums and the checks they fail; the unknown loans apart (devices without a row)
  with r as materialized (select * from cma.pledge_rows_of(v_tenant, v_today)),
       f as materialized (select 'unknown_loan' as check_key, u.pledge_ref as value from cma.pledge_unknown_loans_of(v_tenant) u
                          union all
                          select c.k, case when c.k = 'no_language' then r.language_label end from r cross join lateral unnest(r.checks) as c(k))
  select jsonb_build_object(
    'files', coalesce((select jsonb_agg(jsonb_build_object('valuation_date', s.valuation_date, 'taken_at', s.taken_at, 'loans', s.loans,
                                                            'devices', s.devices) order by s.valuation_date desc)
                       from cma.pledge_snapshot s where s.tenant_id = v_tenant), '[]'::jsonb),
    'today', jsonb_build_object('valuation_date', v_today,
      'loans', coalesce((select jsonb_agg(jsonb_build_object('number', x.number, 'lender_label', x.lender_label, 'devices', x.devices,
                                                              'in_storage', x.in_storage, 'acquisition_value', x.acq::text,
                                                              'current_value', x.cur::text, 'receipts', x.rec::text) order by x.number)
                         from (select l.number, l.lender_label, count(*) as devices, count(*) filter (where r.customer_id = 'In Storage') as in_storage,
                                      coalesce(sum(r.acquisition_value), 0)::numeric(14,2) as acq, coalesce(sum(r.current_value), 0)::numeric(14,2) as cur,
                                      coalesce(sum(r.receipts), 0)::numeric(14,2) as rec
                               from r join cma.pledge_loan l on l.tenant_id = v_tenant and l.number = r.loan_number
                               group by l.number, l.lender_label) x), '[]'::jsonb)),
    'checks', (select jsonb_object_agg(k, (select count(*) from f where f.check_key = k)) from unnest(cma.pledge_check_keys()) k),
    'unmapped_languages', coalesce((select jsonb_agg(jsonb_build_object('label', y.value, 'devices', y.n) order by y.n desc, y.value)
                                    from (select f.value, count(*) as n from f where f.check_key = 'no_language' and f.value is not null
                                          group by f.value) y), '[]'::jsonb),
    'quarter', jsonb_build_object('start', v_quarter,
      'taken', exists (select 1 from cma.pledge_snapshot s where s.tenant_id = v_tenant and s.valuation_date = v_quarter),
      'due', v_today > v_quarter or v_local::time >= cma.setting_of(v_tenant, 'pledges.snapshot_local_time')::time),
    'file_name_prefix', cma.setting_of(v_tenant, 'pledges.file_name_prefix'),
    'is_set_up', exists (select 1 from cma.pledge_loan l where l.tenant_id = v_tenant))
  into v_res;
  return v_res;
end
$$;

-- A check's devices (pledges.view): serial, record id and value, by serial, at most p_limit (1 to 1,000); CMA04 for a
-- check outside the list or a limit outside its range. Answers total_rows on every row
create or replace function cma.pledge_finding_rows(p_check text, p_limit integer default 500)
returns table (serial text, source_id text, value text, total_rows bigint)
language plpgsql stable
rows 100
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('pledges.view');
  if p_check is null or not (p_check = any (cma.pledge_check_keys())) then
    raise exception 'a check is one of %', array_to_string(cma.pledge_check_keys(), ', ') using errcode = 'CMA04';
  end if;
  if p_limit is null or p_limit not between 1 and 1000 then
    raise exception 'a limit is a whole number from 1 to 1000' using errcode = 'CMA04';
  end if;
  return query
    select f.serial, f.source_id, f.value, count(*) over ()
    from cma.pledge_findings_of(v_tenant, cma.tenant_today_of(v_tenant)) f
    where f.check_key = p_check
    order by f.serial nulls last, f.source_id
    limit p_limit;
end
$$;

-- A file's rows (pledges.view): the quarter file of p_valuation_date as it was taken (CMA02 when none), or today's
-- version for null (the rows now, valued at the tenant's today, with the active loans' labels and layouts). By loan
-- number and serial; at most 50,000 rows (CMA04 above). file_name_prefix on every row: the stored file's, or the
-- setting's for today's version
create or replace function cma.pledge_file(p_valuation_date date default null)
returns table (valuation_date date, taken_at timestamptz, loan_number integer, lender_label text, area_label text, name_suffix text,
               layout smallint, serial text, type_label text, market text, language text, customer_id text, start_date date,
               first_shipped_on date, months_depreciating integer, depreciation_per_month numeric, acquisition_value numeric,
               receipts numeric, current_value numeric, file_name_prefix text)
language plpgsql stable
rows 1000
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_today  date;
  v_n      bigint;
  v_prefix text;
  s        record;
begin
  perform cma.assert_permission('pledges.view');
  if p_valuation_date is null then
    v_today := cma.tenant_today_of(v_tenant);
    v_prefix := cma.setting_of(v_tenant, 'pledges.file_name_prefix');
    return query
      select v_today, null::timestamptz, r.loan_number, l.lender_label, l.area_label, l.name_suffix, l.layout, r.serial, r.type_label,
             r.market, r.language, r.customer_id, r.start_date, r.first_shipped_on, r.months_depreciating, r.depreciation_per_month,
             r.acquisition_value, r.receipts, r.current_value, v_prefix
      from cma.pledge_rows_of(v_tenant, v_today) r
      join cma.pledge_loan l on l.tenant_id = v_tenant and l.number = r.loan_number
      order by r.loan_number, r.serial nulls last, r.source_id;
    -- read once, counted after: an error now discards the rows already returned
    get diagnostics v_n = row_count;
    if v_n > 50000 then
      raise exception 'a pledge-list file holds at most 50,000 rows, this one %', v_n using errcode = 'CMA04';
    end if;
    return;
  end if;
  select x.id, x.taken_at, x.file_name_prefix into s from cma.pledge_snapshot x where x.tenant_id = v_tenant and x.valuation_date = p_valuation_date;
  if not found then
    raise exception 'no quarter file of %', p_valuation_date using errcode = 'CMA02';
  end if;
  return query
    select p_valuation_date, s.taken_at, x.loan_number, x.lender_label, x.area_label, x.name_suffix, x.layout, x.serial, x.type_label,
           x.market, x.language, x.customer_id, x.start_date, x.first_shipped_on, x.months_depreciating, x.depreciation_per_month,
           x.acquisition_value, x.receipts, x.current_value, s.file_name_prefix
    from cma.pledge_snapshot_row x
    where x.tenant_id = v_tenant and x.snapshot_id = s.id
    order by x.loan_number, x.serial nulls last, x.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 12. Grants and settings of the functions
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.device_language_code_of(uuid,text)', 'cma.set_device_language_alias(text,text)',
    'cma.device_rows_apply(uuid,cma.device_load_row[],boolean)', 'cma.device_snapshot_apply(text,uuid,boolean)',
    'cma.ingest_load_device_chunk(uuid,jsonb)',
    'cma.pledge_label_ok(text,integer,boolean)', 'cma.set_pledge_loan(text,integer,text,text,text,integer,boolean)',
    'cma.set_pledge_model_value(text,text,numeric,numeric,numeric)',
    'cma.linkable_subscriptions_of(uuid)', 'cma.pledge_months_of(date,date)', 'cma.pledge_current_value_of(numeric,numeric,integer)',
    'cma.pledge_rows_of(uuid,date)', 'cma.pledge_unknown_loans_of(uuid)', 'cma.pledge_findings_of(uuid,date)', 'cma.pledge_check_keys()',
    'cma.pledge_page()', 'cma.pledge_finding_rows(text,integer)', 'cma.pledge_file(date)',
    'cma.pledge_snapshot_take(uuid)', 'cma.pledge_snapshot_take_current()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- the take's bodies: the owner's alone (the two takes run them with the owner's rights)
  execute 'revoke execute on function cma.pledge_snapshot_write(uuid,date) from public, cma_app';
  execute 'revoke execute on function cma.pledge_snapshot_take_at(uuid,timestamptz) from public, cma_app';
  -- the staging trigger's function: nobody's (it runs whoever writes the row)
  execute 'revoke execute on function cma.device_import_staging_insert() from public';
  -- JIT off for the reads and the take, as 0008zn (section 14 of 122): a read of thousands of rows otherwise pays JIT's
  -- compilation on a session's first calls. The SQL helpers stay without a setting, so their callers inline them
  foreach f in array array['cma.pledge_page()', 'cma.pledge_finding_rows(text,integer)', 'cma.pledge_file(date)',
                           'cma.pledge_snapshot_write(uuid,date)'] loop
    execute format('alter function %s set jit = off', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 13. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009j', 'Assets → Pledge lists: cma.device.pledge_ref (the register''s loan reference, an id) and cma.device.language (a code through cma.device_language_alias, cma.set_device_language_alias, cma.device_language_code_of), raw keeping the label and the reference (cma.device_raw_ok); the load''s row types, the staging and its COPY target with both columns, cma.device_import_staging_insert, cma.device_snapshot_apply, cma.ingest_load_device_chunk and cma.device_rows_apply (from 116; unmapped_language in its answer); connection_field''s checks with pledge_ref and language for a device; cma.pledge_loan and cma.pledge_model_value with their setters (tenant.configure); the settings pledges.snapshot_local_time and pledges.file_name_prefix (cma.check_pledges_setting); cma.linkable_subscriptions_of (Installed base''s link rule); cma.pledge_rows_of; the frozen quarter files cma.pledge_snapshot and cma.pledge_snapshot_row (trigger frozen, no write for the application, rows not audited one by one); cma.pledge_snapshot_take (pledges.snapshot, the scheduler''s; cma.ensure_scheduler_user from 132) and cma.pledge_snapshot_take_current (tenant.configure); the reads cma.pledge_page, cma.pledge_finding_rows and cma.pledge_file (pledges.view, no default role)')
on conflict (version) do nothing;

commit;
reset role;
