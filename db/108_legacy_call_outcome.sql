-- =============================================================================================
-- 108_legacy_call_outcome.sql: addition 0008zg, call outcomes imported from a former telephony system
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 106_review_reference_guard.sql (0008zf). Rerunnable, forward-only, in one transaction. Run as your own IAM login:
-- dev first, then 109_verify_legacy_call_outcome.sql (dev), then 33, 35, 69, 71, 75, 105 and 107 again (dev); then
-- prod. Nothing in the web reads what this adds, and the ingest of main calls none of it, so prod may run it before
-- or after the merge; the job ingest-import-legacy-calls needs it.
--
-- Why (Decision log, 25 October 2026): the outcomes of the calls a former telephony system made (for Pulse4all:
-- Steam's courtesy completions, 14 May 2025 to 31 August 2026) exist only in a file exported from that system. They
-- are imported once, as their own facts, each matched to at most one CRM contact. The current telephony system's
-- calls are never copied: they stay in cma.telephony_call and cma.telephony_call_tag and are read through the tag
-- meanings (docs/definitions.md, R1 and Tag). Nothing personal is stored: an outcome holds its date, its meaning, the
-- old system's tag text and an optional contact id; the email, phone, names and customer id of the file live in the
-- import job's memory only.
--
-- What it adds
--   batches            cma.legacy_call_batch: one imported file per row. The source system (a data value, e.g.
--                      steam), the CRM connection it was matched against, the file's SHA-256 (one live batch per
--                      file and tenant: a second run of the same file reuses the batch; a withdrawn batch frees the
--                      file for a new one), the cutover date (the first day of the current telephony system), the
--                      row counts per source and per match method (counts), started_at, finished_at, withdrawn_at
--                      and withdrawn_by
--   outcomes           cma.legacy_call_outcome: one row per imported row of a batch (source_row, the file's row
--                      number, unique per batch): occurred_on, meaning (the tag meanings' seven keys, the check set
--                      of cma.telephony_tag.meaning), source_label (the old system's tag text, at most 100
--                      characters, never an @), the CRM connection, the contact id or null, the match method
--                      (email_phone, email, phone, customer_id, none, conflict or forgotten) and matched_at. A
--                      contact is present exactly when the method is email_phone, email, phone or customer_id
--   ingest             cma.legacy_call_batch_start(): starts a batch or reuses the live one of the same file;
--                      cma.legacy_call_outcomes_upsert(batch, rows): at most 500 rows, a rerun fills a contact only
--                      where none is set and never changes a set one or a forgotten row; cma.legacy_call_batch_finish():
--                      the counts, with the per-method counts taken from the stored rows; cma.legacy_call_reconcile():
--                      for rows of the current telephony system, the calls on that date with that number's keyed
--                      hash and a current tag meaning courtesy_completed_* (a read; nothing is stored)
--   withdrawal         cma.withdraw_legacy_call_batch(batch): tenant.configure, once, audited; a withdrawn batch's
--                      rows stay stored and are left out of every read
--   privacy            cma.ingest_contact_forget() as 0008p left it, plus: the legacy call outcomes matched to the
--                      contact lose it and read match method forgotten
--   readers            cma_read.legacy_call_batch and cma_read.legacy_call_outcome (every column; there is no
--                      personal data), the outcomes of withdrawn batches left out
--   runs               sync_run.job gains legacy_call_import
--
-- Everything is SECURITY INVOKER and executable by the application only, with its permission checked inside. The
-- application never deletes a batch or an outcome.
--
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008zf') then
    raise exception 'addition 0008zf (106_review_reference_guard.sql) must run before 0008zg';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Batches and outcomes
-- ---------------------------------------------------------------------------------------------
-- A batch's counts: whole numbers under fixed keys (the rows per source, the refused rows, the reconciliation of the
-- current system's rows, and the stored rows per match method); never an id, a value of the file or a text
create or replace function cma.legacy_call_counts_ok(p_counts jsonb)
returns boolean
language sql immutable
as $$
  select p_counts is not null and jsonb_typeof(p_counts) = 'object'
     and not exists (select 1 from jsonb_each(p_counts) e
                     where e.key not in ('total', 'legacy', 'current', 'refused', 'current_found', 'current_not_found', 'stored',
                                         'email_phone', 'email', 'phone', 'customer_id', 'none', 'conflict', 'forgotten')
                        or jsonb_typeof(e.value) <> 'number' or (e.value #>> '{}') !~ '^\d{1,9}$')
$$;
revoke execute on function cma.legacy_call_counts_ok(jsonb) from public;
grant execute on function cma.legacy_call_counts_ok(jsonb) to cma_app;

create table if not exists cma.legacy_call_batch (
  id                 uuid primary key default uuidv7(),
  tenant_id          uuid not null default cma.current_tenant_id() references cma.tenant (id),
  source_system      text not null check (source_system ~ '^[a-z0-9_]{1,40}$'),
  crm_connection_id  uuid not null,
  file_sha256        text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  cutover_date       date not null,
  counts             jsonb not null default '{}'::jsonb check (cma.legacy_call_counts_ok(counts)),
  started_at         timestamptz not null default now(),
  finished_at        timestamptz,
  withdrawn_at       timestamptz,
  withdrawn_by       uuid,
  unique (tenant_id, id),
  unique (tenant_id, id, crm_connection_id),
  check ((withdrawn_at is null) = (withdrawn_by is null)),
  foreign key (tenant_id, crm_connection_id) references cma.integration_connection (tenant_id, id),
  foreign key (tenant_id, withdrawn_by) references cma.app_user (tenant_id, id)
);
comment on table cma.legacy_call_batch is 'One imported file of a former telephony system''s call outcomes: source system, CRM connection, the file''s SHA-256, the cutover date, counts, times, and its withdrawal. No personal data (0008zg)';
comment on column cma.legacy_call_batch.source_system is 'The former telephony system, a data value (for Pulse4all steam)';
comment on column cma.legacy_call_batch.file_sha256 is 'The SHA-256 of the imported file, lower-case hex: one live batch per file and tenant, so a second run of the same file reuses the batch';
comment on column cma.legacy_call_batch.cutover_date is 'The first day of the current telephony system: a row of the former system is dated before it, a row of the current one on or after it';
comment on column cma.legacy_call_batch.counts is 'Whole numbers: total, legacy, current, refused, current_found, current_not_found (the import job''s), and stored with the stored rows per match method (taken from the rows at finish)';
comment on column cma.legacy_call_batch.withdrawn_at is 'When the batch was withdrawn (tenant.configure, once); its outcomes stay stored and are left out of every read';
-- One live batch per file and tenant; a withdrawn batch frees the file for a new one
create unique index if not exists legacy_call_batch_file_idx on cma.legacy_call_batch (tenant_id, file_sha256) where withdrawn_at is null;

create table if not exists cma.legacy_call_outcome (
  id                     uuid primary key default uuidv7(),
  tenant_id              uuid not null default cma.current_tenant_id() references cma.tenant (id),
  batch_id               uuid not null,
  source_row             integer not null check (source_row between 2 and 10000000),
  occurred_on            date not null,
  meaning                text not null check (meaning in ('not_reached', 'incorrect_data', 'call_type', 'courtesy_attempt',
                                                          'courtesy_completed_positive', 'courtesy_completed_neutral',
                                                          'courtesy_completed_negative')),
  source_label           text not null check (length(source_label) between 1 and 100 and source_label = btrim(source_label)
                                              and strpos(source_label, '@') = 0 and source_label !~ '[[:cntrl:]]'),
  crm_connection_id      uuid not null,
  crm_contact_source_id  text check (length(crm_contact_source_id) between 1 and 100 and crm_contact_source_id = btrim(crm_contact_source_id)),
  match_method           text not null check (match_method in ('email_phone', 'email', 'phone', 'customer_id', 'none', 'conflict', 'forgotten')),
  matched_at             timestamptz,
  unique (tenant_id, id),
  unique (tenant_id, batch_id, source_row),
  check ((crm_contact_source_id is not null) = (match_method in ('email_phone', 'email', 'phone', 'customer_id'))),
  check ((matched_at is not null) = (crm_contact_source_id is not null)),
  foreign key (tenant_id, batch_id, crm_connection_id) references cma.legacy_call_batch (tenant_id, id, crm_connection_id),
  foreign key (tenant_id, crm_connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.legacy_call_outcome is 'A former telephony system''s call outcome, one per imported row: date, meaning, the old system''s tag text and the CRM contact matched (or none). Never an email, a phone number, a name or a customer id (0008zg)';
comment on column cma.legacy_call_outcome.source_row is 'The row number in the imported file (the header is row 1), unique per batch';
comment on column cma.legacy_call_outcome.meaning is 'The tag meaning of the row''s label, by the import''s mapping: one of the seven keys of cma.telephony_tag.meaning';
comment on column cma.legacy_call_outcome.source_label is 'The former system''s tag text as the file holds it: at most 100 characters, never an @';
comment on column cma.legacy_call_outcome.crm_contact_source_id is 'The CRM contact matched, kept in the CMA only; null for none, conflict and forgotten';
comment on column cma.legacy_call_outcome.match_method is 'email_phone, email, phone or customer_id (exactly one contact found that way), none, conflict (email and phone found different contacts) or forgotten (the CRM deleted the contact for privacy)';
comment on column cma.legacy_call_outcome.matched_at is 'When the contact was set; null without a contact';
create index if not exists legacy_call_outcome_date_idx on cma.legacy_call_outcome (tenant_id, occurred_on);
create index if not exists legacy_call_outcome_contact_idx on cma.legacy_call_outcome (tenant_id, crm_connection_id, crm_contact_source_id)
  where crm_contact_source_id is not null;

select cma.setup_tenant_table('cma.legacy_call_batch');
select cma.setup_tenant_table('cma.legacy_call_outcome');

-- The application never deletes a batch or an outcome
revoke delete on cma.legacy_call_batch, cma.legacy_call_outcome from cma_app;

-- ---------------------------------------------------------------------------------------------
-- 2. Ingest: start, rows, finish (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- An active CRM connection of the tenant: kind crm, or no kind with only a CRM's rows (as 0008h and 0008ze); CMA02 for
-- no active connection, CMA04 for another kind
create or replace function cma.assert_legacy_crm_connection(p_crm_connection_id uuid)
returns void
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_kind   text;
begin
  perform cma.active_connection_adapter(p_crm_connection_id);
  select c.kind into v_kind from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_crm_connection_id;
  if not (coalesce(v_kind, '') = 'crm'
          or (v_kind is null and cma.connection_held_kinds_of(v_tenant, p_crm_connection_id) = array['crm'])) then
    raise exception 'connection % is not a CRM connection', p_crm_connection_id using errcode = 'CMA04';
  end if;
end
$$;

-- Starts the batch of a file, or reuses the live batch of the same file: answers the batch and started or reused. A
-- live batch of the same file with another source system, CRM connection or cutover date is a conflict (CMA03)
create or replace function cma.legacy_call_batch_start(p_crm_connection_id uuid, p_source_system text, p_file_sha256 text,
                                                       p_cutover_date date)
returns table (batch_id uuid, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_row    cma.legacy_call_batch;
  v_sha    text := lower(btrim(p_file_sha256));
begin
  perform cma.assert_permission('ingest.write');
  perform cma.assert_legacy_crm_connection(p_crm_connection_id);
  if coalesce(p_source_system, '') !~ '^[a-z0-9_]{1,40}$' then
    raise exception 'a source system is 1 to 40 lower-case letters, digits or _' using errcode = 'CMA04';
  end if;
  if coalesce(v_sha, '') !~ '^[0-9a-f]{64}$' then
    raise exception 'a file''s SHA-256 is 64 hex characters' using errcode = 'CMA04';
  end if;
  if p_cutover_date is null then
    raise exception 'a cutover date is needed' using errcode = 'CMA04';
  end if;
  select * into v_row from cma.legacy_call_batch b
  where b.tenant_id = v_tenant and b.file_sha256 = v_sha and b.withdrawn_at is null
  for update;
  if v_row.id is not null then
    if (v_row.source_system, v_row.crm_connection_id, v_row.cutover_date) is distinct from (p_source_system, p_crm_connection_id, p_cutover_date) then
      raise exception 'batch % of this file has another source system, CRM connection or cutover date; withdraw it to import the file again', v_row.id
        using errcode = 'CMA03';
    end if;
    batch_id := v_row.id;
    outcome := 'reused';
    return next;
    return;
  end if;
  insert into cma.legacy_call_batch (tenant_id, source_system, crm_connection_id, file_sha256, cutover_date)
  values (v_tenant, p_source_system, p_crm_connection_id, v_sha, p_cutover_date)
  returning id into batch_id;
  outcome := 'started';
  return next;
exception when unique_violation then
  raise exception 'another run started a batch of this file at the same time' using errcode = 'CMA03';
end
$$;

-- At most 500 rows of a live batch: [{sourceRow, occurredOn (YYYY-MM-DD), meaning, sourceLabel, contactId (or null),
-- matchMethod}]. A row is dated before the batch's cutover date. A new row is inserted. A stored row keeps its facts:
-- another date, meaning or label refuses the whole call (CMA03; withdraw the batch to import the file differently). A
-- rerun fills a contact only where none is set (filled) and never changes a set one (kept) or a forgotten row
-- (forgotten); without a contact the method may change between none and conflict (updated). Answers each row's outcome:
-- inserted, filled, updated, unchanged, kept or forgotten
create or replace function cma.legacy_call_outcomes_upsert(p_batch_id uuid, p_rows jsonb)
returns table (source_row integer, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_batch   cma.legacy_call_batch;
  v_old     cma.legacy_call_outcome;
  i         jsonb;
  v_row     integer;
  v_on      date;
  v_meaning text;
  v_label   text;
  v_contact text;
  v_method  text;
begin
  perform cma.assert_permission('ingest.write');
  select * into v_batch from cma.legacy_call_batch b where b.tenant_id = v_tenant and b.id = p_batch_id;
  if v_batch.id is null then
    raise exception 'no legacy call batch %', p_batch_id using errcode = 'CMA02';
  end if;
  if v_batch.withdrawn_at is not null then
    raise exception 'legacy call batch % is withdrawn', p_batch_id using errcode = 'CMA03';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 500 then
    raise exception 'rows must be an array of at most 500 rows' using errcode = 'CMA04';
  end if;
  for i in select x from jsonb_array_elements(p_rows) x loop
    if jsonb_typeof(i) <> 'object' or jsonb_typeof(i -> 'sourceRow') <> 'number' or (i ->> 'sourceRow') !~ '^\d{1,8}$'
       or coalesce(i ->> 'occurredOn', '') !~ '^\d{4}-\d{2}-\d{2}$' then
      raise exception 'a row needs a whole sourceRow and occurredOn as YYYY-MM-DD' using errcode = 'CMA04';
    end if;
    v_row := (i ->> 'sourceRow')::integer;
    v_on := (i ->> 'occurredOn')::date;
    v_meaning := i ->> 'meaning';
    v_label := i ->> 'sourceLabel';
    v_contact := nullif(i ->> 'contactId', '');
    v_method := i ->> 'matchMethod';
    if v_on >= v_batch.cutover_date then
      raise exception 'row %: dated on or after the batch''s cutover date', v_row using errcode = 'CMA04';
    end if;
    if coalesce(v_method, '') not in ('email_phone', 'email', 'phone', 'customer_id', 'none', 'conflict') then
      raise exception 'row %: the match method is email_phone, email, phone, customer_id, none or conflict', v_row using errcode = 'CMA04';
    end if;

    v_old := null;
    select * into v_old from cma.legacy_call_outcome o
    where o.tenant_id = v_tenant and o.batch_id = p_batch_id and o.source_row = v_row
    for update;
    if v_old.id is null then
      insert into cma.legacy_call_outcome (tenant_id, batch_id, source_row, occurred_on, meaning, source_label, crm_connection_id,
                                           crm_contact_source_id, match_method, matched_at)
      values (v_tenant, p_batch_id, v_row, v_on, v_meaning, v_label, v_batch.crm_connection_id, v_contact, v_method,
              case when v_contact is not null then now() end);
      outcome := 'inserted';
    elsif (v_old.occurred_on, v_old.meaning, v_old.source_label) is distinct from (v_on, v_meaning, v_label) then
      raise exception 'row %: its stored date, meaning or label differs; withdraw the batch to import the file differently', v_row
        using errcode = 'CMA03';
    elsif v_old.match_method = 'forgotten' then
      outcome := 'forgotten';
    elsif v_old.crm_contact_source_id is not null then
      outcome := case when (v_old.crm_contact_source_id, v_old.match_method) is not distinct from (v_contact, v_method)
                      then 'unchanged' else 'kept' end;
    elsif v_contact is not null then
      update cma.legacy_call_outcome o
         set crm_contact_source_id = v_contact, match_method = v_method, matched_at = now()
       where o.tenant_id = v_tenant and o.id = v_old.id;
      outcome := 'filled';
    elsif v_old.match_method <> v_method then
      update cma.legacy_call_outcome o set match_method = v_method where o.tenant_id = v_tenant and o.id = v_old.id;
      outcome := 'updated';
    else
      outcome := 'unchanged';
    end if;
    source_row := v_row;
    return next;
  end loop;
exception when check_violation or not_null_violation or invalid_text_representation or invalid_datetime_format
               or datetime_field_overflow or numeric_value_out_of_range then
  raise exception 'invalid legacy call outcome: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Finishes a run of a live batch: the job's counts (total, legacy, current, refused, current_found, current_not_found;
-- whole numbers) with stored and the stored rows per match method, taken from the rows; finished_at now. Called again
-- by a rerun, it writes the counts of that run. Answers the counts stored
create or replace function cma.legacy_call_batch_finish(p_batch_id uuid, p_counts jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_batch  cma.legacy_call_batch;
  v_counts jsonb;
begin
  perform cma.assert_permission('ingest.write');
  select * into v_batch from cma.legacy_call_batch b where b.tenant_id = v_tenant and b.id = p_batch_id for update;
  if v_batch.id is null then
    raise exception 'no legacy call batch %', p_batch_id using errcode = 'CMA02';
  end if;
  if v_batch.withdrawn_at is not null then
    raise exception 'legacy call batch % is withdrawn', p_batch_id using errcode = 'CMA03';
  end if;
  if p_counts is null or jsonb_typeof(p_counts) <> 'object' or not cma.legacy_call_counts_ok(p_counts)
     or exists (select 1 from jsonb_object_keys(p_counts) k
                where k not in ('total', 'legacy', 'current', 'refused', 'current_found', 'current_not_found')) then
    raise exception 'counts are whole numbers for total, legacy, current, refused, current_found and current_not_found' using errcode = 'CMA04';
  end if;
  select p_counts || jsonb_build_object(
           'stored', count(*),
           'email_phone', count(*) filter (where o.match_method = 'email_phone'),
           'email', count(*) filter (where o.match_method = 'email'),
           'phone', count(*) filter (where o.match_method = 'phone'),
           'customer_id', count(*) filter (where o.match_method = 'customer_id'),
           'none', count(*) filter (where o.match_method = 'none'),
           'conflict', count(*) filter (where o.match_method = 'conflict'),
           'forgotten', count(*) filter (where o.match_method = 'forgotten'))
    into v_counts
  from cma.legacy_call_outcome o
  where o.tenant_id = v_tenant and o.batch_id = p_batch_id;
  update cma.legacy_call_batch b set counts = v_counts, finished_at = now()
  where b.tenant_id = v_tenant and b.id = p_batch_id;
  return v_counts;
end
$$;

-- The reconciliation of the current telephony system's rows (a read; nothing is stored): at most 500 items
-- [{item, hash, date}], answering per item the tenant's telephony calls not deleted at the source whose counterpart's
-- keyed hash is the item's, that started on the item's date in the tenant's time zone (the Day of docs/definitions.md)
-- and that carry a current tag whose meaning is courtesy_completed_positive, _neutral or _negative
create or replace function cma.legacy_call_reconcile(p_items jsonb)
returns table (item integer, calls integer)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_zone   text;
begin
  perform cma.assert_permission('ingest.write');
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500
     or exists (select 1 from jsonb_array_elements(p_items) x
                where jsonb_typeof(x) <> 'object' or jsonb_typeof(x -> 'item') <> 'number' or (x ->> 'item') !~ '^\d{1,8}$'
                   or coalesce(x ->> 'hash', '') !~ '^[0-9a-f]{64}$' or coalesce(x ->> 'date', '') !~ '^\d{4}-\d{2}-\d{2}$') then
    raise exception 'items must be an array of at most 500 {item, hash (64 hex), date (YYYY-MM-DD)}' using errcode = 'CMA04';
  end if;
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;
  return query
    select (x ->> 'item')::integer,
           (select count(*)::integer
            from cma.telephony_call c
            where c.tenant_id = v_tenant and c.counterpart_hash = x ->> 'hash' and c.source_deleted_at is null
              and (c.started_at at time zone v_zone)::date = (x ->> 'date')::date
              and exists (select 1
                          from cma.telephony_call_tag ct
                          join cma.telephony_tag tg on tg.tenant_id = ct.tenant_id and tg.connection_id = ct.connection_id and tg.tag_ref = ct.tag_ref
                          where ct.tenant_id = c.tenant_id and ct.connection_id = c.connection_id and ct.call_source_id = c.source_id
                            and ct.untagged_at is null and starts_with(coalesce(tg.meaning, ''), 'courtesy_completed_')))
    from jsonb_array_elements(p_items) x;
exception when invalid_datetime_format or datetime_field_overflow then
  raise exception 'invalid reconciliation item: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Withdrawal (tenant.configure)
-- ---------------------------------------------------------------------------------------------
-- Withdraws a batch once: withdrawn_at and withdrawn_by set (the audit trail keeps the change), its rows stay stored and
-- are left out of every read, and its file may be imported again as a new batch. A second withdrawal is CMA03. Answers
-- the time of the withdrawal
create or replace function cma.withdraw_legacy_call_batch(p_batch_id uuid)
returns timestamptz
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid;
  v_at     timestamptz;
begin
  v_user := cma.assert_permission('tenant.configure');
  select b.withdrawn_at into v_at from cma.legacy_call_batch b where b.tenant_id = v_tenant and b.id = p_batch_id for update;
  if not found then
    raise exception 'no legacy call batch %', p_batch_id using errcode = 'CMA02';
  end if;
  if v_at is not null then
    raise exception 'legacy call batch % was withdrawn at %', p_batch_id, v_at using errcode = 'CMA03';
  end if;
  update cma.legacy_call_batch b set withdrawn_at = now(), withdrawn_by = v_user
  where b.tenant_id = v_tenant and b.id = p_batch_id
  returning b.withdrawn_at into v_at;
  return v_at;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The privacy deletion
-- ---------------------------------------------------------------------------------------------
-- As 0008p (74) left it (contacts, refs, calls, submissions' answers, emails, threads and tasks; the answer's shape
-- unchanged), plus: every legacy call outcome matched to the contact loses it and reads match method forgotten, so a
-- rerun of its import never fills it again; the answer gains legacy_calls when there were any
create or replace function cma.ingest_contact_forget(p_connection_id uuid, p_contact_source_id text)
returns jsonb
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_contact uuid;
  v_c       integer := 0;
  v_r       integer := 0;
  v_k       integer := 0;
  v_s       integer := 0;
  v_t       integer := 0;
  v_e       integer := 0;
  v_h       integer := 0;
  v_tk      integer := 0;
  v_lc      integer := 0;
  v_res     jsonb;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if coalesce(p_contact_source_id, '') = '' then
    raise exception 'a contact id is needed' using errcode = 'CMA04';
  end if;
  update cma.crm_contact cc
     set country = null, country_source = null, language = null, currency = null, store = null, raw = '{}'::jsonb,
         source_deleted_at = coalesce(cc.source_deleted_at, now()), synced_at = now()
   where cc.tenant_id = v_tenant and cc.connection_id = p_connection_id and cc.source_id = p_contact_source_id
  returning cc.id into v_contact;
  get diagnostics v_c = row_count;
  if v_contact is not null then
    delete from cma.crm_contact_ref r where r.tenant_id = v_tenant and r.contact_id = v_contact;
    get diagnostics v_r = row_count;
  end if;
  -- telephony calls linked to the contact's CRM calls (whether or not those still hold a hash)
  update cma.telephony_call t set counterpart_hash = null, synced_at = now()
  where t.tenant_id = v_tenant and t.counterpart_hash is not null
    and exists (select 1 from cma.call_link l
                join cma.crm_call k on k.tenant_id = l.tenant_id and k.id = l.crm_call_id
                join cma.crm_association a
                  on a.tenant_id = k.tenant_id and a.connection_id = k.connection_id
                 and a.from_type = 'crm_call' and a.from_id = k.source_id
                 and a.to_type = 'contact' and a.to_id = p_contact_source_id
                where l.tenant_id = t.tenant_id and l.telephony_call_id = t.id
                  and k.connection_id = p_connection_id);
  get diagnostics v_t = row_count;
  update cma.crm_call k set counterpart_hash = null, synced_at = now()
  where k.tenant_id = v_tenant and k.connection_id = p_connection_id and k.counterpart_hash is not null
    and exists (select 1 from cma.crm_association a
                where a.tenant_id = k.tenant_id and a.connection_id = k.connection_id
                  and a.from_type = 'crm_call' and a.from_id = k.source_id
                  and a.to_type = 'contact' and a.to_id = p_contact_source_id);
  get diagnostics v_k = row_count;
  update cma.form_submission s set kept_values = '{}'::jsonb, kept_cleared_at = coalesce(s.kept_cleared_at, now()), synced_at = now()
  where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.contact_source_id = p_contact_source_id
    and s.kept_values <> '{}'::jsonb;
  get diagnostics v_s = row_count;
  -- 0008p: the contact's submissions without answers are marked too, so a later read never fills them
  update cma.form_submission s set kept_cleared_at = now()
  where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.contact_source_id = p_contact_source_id
    and s.kept_cleared_at is null;
  update cma.email_message em set contact_source_id = null, synced_at = now()
  where em.tenant_id = v_tenant and em.connection_id = p_connection_id and em.contact_source_id = p_contact_source_id;
  get diagnostics v_e = row_count;
  update cma.email_thread et set contact_source_id = null, synced_at = now()
  where et.tenant_id = v_tenant and et.connection_id = p_connection_id and et.contact_source_id = p_contact_source_id;
  get diagnostics v_h = row_count;
  update cma.crm_task tk set contact_source_id = null, synced_at = now()
  where tk.tenant_id = v_tenant and tk.connection_id = p_connection_id and tk.contact_source_id = p_contact_source_id;
  get diagnostics v_tk = row_count;
  -- 0008zg: the legacy call outcomes matched to the contact, withdrawn batches' included
  update cma.legacy_call_outcome lo set crm_contact_source_id = null, match_method = 'forgotten', matched_at = null
  where lo.tenant_id = v_tenant and lo.crm_connection_id = p_connection_id and lo.crm_contact_source_id = p_contact_source_id;
  get diagnostics v_lc = row_count;
  v_res := jsonb_build_object('contacts', v_c, 'refs', v_r, 'calls', v_k, 'submissions', v_s);
  if v_t > 0 then
    v_res := v_res || jsonb_build_object('telephony_calls', v_t);
  end if;
  if v_e > 0 then
    v_res := v_res || jsonb_build_object('emails', v_e);
  end if;
  if v_h > 0 then
    v_res := v_res || jsonb_build_object('threads', v_h);
  end if;
  if v_tk > 0 then
    v_res := v_res || jsonb_build_object('tasks', v_tk);
  end if;
  if v_lc > 0 then
    v_res := v_res || jsonb_build_object('legacy_calls', v_lc);
  end if;
  return v_res;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. sync_run: the import job
-- ---------------------------------------------------------------------------------------------
alter table cma.sync_run drop constraint if exists sync_run_job_check;
alter table cma.sync_run add constraint sync_run_job_check
  check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls', 'email_poll', 'close_forgotten_workdays',
                 'refresh_follow_up', 'reviews_poll', 'legacy_call_import')) not valid;
alter table cma.sync_run validate constraint sync_run_job_check;

-- ---------------------------------------------------------------------------------------------
-- 6. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.legacy_call_counts_ok(jsonb)',
    'cma.assert_legacy_crm_connection(uuid)',
    'cma.legacy_call_batch_start(uuid,text,text,date)',
    'cma.legacy_call_outcomes_upsert(uuid,jsonb)',
    'cma.legacy_call_batch_finish(uuid,jsonb)',
    'cma.legacy_call_reconcile(jsonb)',
    'cma.withdraw_legacy_call_batch(uuid)',
    'cma.ingest_contact_forget(uuid,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Reporting views
-- ---------------------------------------------------------------------------------------------
-- Every column; there is no personal data
create or replace view cma_read.legacy_call_batch as
  select id, tenant_id, source_system, crm_connection_id, file_sha256, cutover_date, counts, started_at, finished_at,
         withdrawn_at, withdrawn_by
  from cma.legacy_call_batch
  where cma_read.reader_sees(tenant_id);

-- Every column; the outcomes of a withdrawn batch are left out
create or replace view cma_read.legacy_call_outcome as
  select o.id, o.tenant_id, o.batch_id, o.source_row, o.occurred_on, o.meaning, o.source_label, o.crm_connection_id,
         o.crm_contact_source_id, o.match_method, o.matched_at
  from cma.legacy_call_outcome o
  join cma.legacy_call_batch b on b.tenant_id = o.tenant_id and b.id = o.batch_id and b.withdrawn_at is null
  where cma_read.reader_sees(o.tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 8. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zg', 'Legacy call outcomes: cma.legacy_call_batch (source system, CRM connection, the file''s SHA-256 with one live batch per file, cutover date, counts, times, withdrawal) and cma.legacy_call_outcome (the file''s row, date, tag meaning, the old system''s tag text, the CRM contact or none, match method email_phone, email, phone, customer_id, none, conflict or forgotten); start, upsert (a rerun fills a contact only where none is set), finish and the reconciliation read (ingest.write); cma.withdraw_legacy_call_batch (tenant.configure, once); the privacy deletion sets forgotten; the reader views without withdrawn batches; sync_run job legacy_call_import')
on conflict (version) do nothing;

commit;
reset role;
