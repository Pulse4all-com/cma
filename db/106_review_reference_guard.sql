-- =============================================================================================
-- 106_review_reference_guard.sql: addition 0008zf, a review's transaction reference never holds an email address
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 104_reviews.sql (0008ze).
-- Rerunnable, forward-only, in one transaction. Run as your own IAM login: dev first, then
-- 107_verify_review_reference_guard.sql (dev), then 105, 77, 75, 67 and 33 again (dev); then prod, before the ingest
-- image of brief B18.1 runs: that image finishes a run that left a reference out with the count ref_dropped, which only
-- this addition's cma.ingest_sync_run_finish() accepts. The ingest of main before B18.1 keeps working on it: it sends
-- the reference it reads, and only one with an @ is refused, which comes back only when a backfill re-reads that
-- review. Nothing in the web reads what this changes. So prod runs this as soon as dev has passed, before the merge
-- (PROD_RUNBOOK 13.12).
--
-- Why (Decision log, 25 October 2026; brief B18.1): in prod, 1 of the 845 reviews of the first backfill held an email
-- address as its transaction reference (a manual invite of June 2024 without an event type). 0008ze stored it in
-- cma.review.transaction_ref and in raw.transaction.reference, and cma.audit_row() kept it in that review's audit
-- images. The adapter now keeps a reference only when it matches the connection setting transaction_ref_pattern (by
-- default letters, digits and # _ . : / -, never an @ or a space); this addition removes what is stored and refuses it
-- from now on.
--
-- What it does
--   1. the scrub helper   cma.review_image_without_at_reference(image): a review's row image (jsonb) without an
--                         @ reference: transaction_ref null and raw's transaction removed when either holds an @
--                         (raw.transaction holds the reference only, 0008ze's raw check); any other image as it is.
--                         Immutable; the application and the owner only
--   2. the audit image    cma.audit_row() as 0008q left it, plus: both images of a review pass the helper, so no
--                         audit row of a review keeps an @ reference, the cleanup's own row included (its old image
--                         is written clean, so the cleanup writes no new copy)
--   3. the cleanup        cma.clear_review_at_references() (the owner's only), run once here: every review whose
--                         transaction_ref or raw.transaction.reference holds an @ loses both (reviews_cleared); its
--                         link stays, because an @ never names an order (order names and ids hold none). Then every
--                         audit row of table review whose images hold an @ reference is corrected by the helper
--                         (audit_rows_scrubbed). The log is append-only for the application; the owner corrects it
--                         here as a data-protection fix. The cleanup's own audit rows stay, written clean by 2, so the
--                         trail shows that the cleanup happened, when and by whom
--   4. the counts         the script's one result row: reviews_cleared and audit_rows_scrubbed
--   5. run counts         cma.ingest_sync_run_finish() as 0008p left it, plus the count ref_dropped: the references
--                         the adapter left out of a run because the connection's pattern refused them (never the
--                         values)
--   6. the guard          check review_reference_no_at on cma.review: neither transaction_ref nor
--                         raw #>> '{transaction,reference}' holds an @. An ingest write that breaks it fails the batch
--                         with CMA04 (0008ze's handler); the adapter drops such a reference before it sends it, so the
--                         check is the last line, never the first
--
-- SQLSTATEs as before: CMA04 invalid.
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
  if not exists (select 1 from cma.schema_migration where version = '0008ze') then
    raise exception 'addition 0008ze (104_reviews.sql) must run before 0008zf';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The scrub helper
-- ---------------------------------------------------------------------------------------------
-- A review's row image without an @ reference: transaction_ref null when it holds an @, raw's transaction removed when
-- its reference holds one; null for null, any other image unchanged
create or replace function cma.review_image_without_at_reference(p_image jsonb)
returns jsonb
language sql immutable
as $$
  select case
    when p_image is null or jsonb_typeof(p_image) <> 'object' then p_image
    else (case when strpos(coalesce(p_image ->> 'transaction_ref', ''), '@') > 0
               then jsonb_set(p_image, '{transaction_ref}', 'null'::jsonb) else p_image end)
         #- (case when strpos(coalesce(p_image #>> '{raw,transaction,reference}', ''), '@') > 0
                  then '{raw,transaction}'::text[] else '{}'::text[] end)
  end
$$;
revoke execute on function cma.review_image_without_at_reference(jsonb) from public;
grant execute on function cma.review_image_without_at_reference(jsonb) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 2. The audit image of a review carries no @ reference
-- ---------------------------------------------------------------------------------------------
-- As 0008q (76) left it, plus: both images of a review pass the helper above. Before the cleanup below, so the
-- cleanup's own audit row is written without the address.
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

-- ---------------------------------------------------------------------------------------------
-- 3. The cleanup: no stored review and no audit image of one keeps an @ reference
-- ---------------------------------------------------------------------------------------------
-- Every review whose transaction_ref or raw.transaction.reference holds an @ loses both (its link stays: an @ never
-- names an order); then every audit row of table review whose images hold one is corrected by the helper. The
-- cleanup's own audit rows are written clean by cma.audit_row() above. Answers the two counts. The owner's only: the
-- audit log is append-only for the application, and this is a data-protection correction of it
create or replace function cma.clear_review_at_references()
returns table (reviews_cleared bigint, audit_rows_scrubbed bigint)
language plpgsql
as $$
declare
  v_reviews bigint;
  v_audit   bigint;
begin
  update cma.review r
     set transaction_ref = case when strpos(coalesce(r.transaction_ref, ''), '@') > 0 then null else r.transaction_ref end,
         raw = case when strpos(coalesce(r.raw #>> '{transaction,reference}', ''), '@') > 0 then r.raw - 'transaction' else r.raw end
   where strpos(coalesce(r.transaction_ref, ''), '@') > 0
      or strpos(coalesce(r.raw #>> '{transaction,reference}', ''), '@') > 0;
  get diagnostics v_reviews = row_count;
  update cma.audit_log a
     set old_row = cma.review_image_without_at_reference(a.old_row),
         new_row = cma.review_image_without_at_reference(a.new_row)
   where a.table_name = 'review'
     and (strpos(coalesce(a.old_row ->> 'transaction_ref', ''), '@') > 0
          or strpos(coalesce(a.old_row #>> '{raw,transaction,reference}', ''), '@') > 0
          or strpos(coalesce(a.new_row ->> 'transaction_ref', ''), '@') > 0
          or strpos(coalesce(a.new_row #>> '{raw,transaction,reference}', ''), '@') > 0);
  get diagnostics v_audit = row_count;
  return query select v_reviews, v_audit;
end
$$;
revoke execute on function cma.clear_review_at_references() from public;

-- 4. Run it: the counts are the result Studio shows (1 and the review's audit rows in prod on the first run, 0 and 0
--    on a rerun)
select * from cma.clear_review_at_references();

-- ---------------------------------------------------------------------------------------------
-- 5. A run's counts take ref_dropped
-- ---------------------------------------------------------------------------------------------
-- As 0008p (74) left it, plus ref_dropped among the whole-number counts
create or replace function cma.ingest_sync_run_finish(p_run_id uuid, p_status text, p_counts jsonb, p_error text default null)
returns void
language plpgsql
as $$
declare
  v_status text;
begin
  perform cma.assert_permission('ingest.write');
  if p_status not in ('succeeded', 'failed') then
    raise exception 'status must be succeeded or failed' using errcode = 'CMA04';
  end if;
  if p_counts is not null and (jsonb_typeof(p_counts) <> 'object'
     or exists (select 1 from jsonb_each(p_counts) e
                where e.key not in ('fetched', 'upserted', 'stale', 'skipped', 'failed', 'dropped', 'ref_dropped')
                   or jsonb_typeof(e.value) <> 'number' or (e.value #>> '{}') !~ '^\d+$')) then
    raise exception 'counts are whole numbers for fetched, upserted, stale, skipped, failed, dropped and ref_dropped' using errcode = 'CMA04';
  end if;
  select r.status into v_status from cma.sync_run r where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id for update;
  if v_status is null then
    raise exception 'no sync run % in the current tenant', p_run_id using errcode = 'CMA02';
  end if;
  if v_status <> 'running' then
    raise exception 'sync run % is already finished', p_run_id using errcode = 'CMA03';
  end if;
  update cma.sync_run r
     set status = p_status, finished_at = now(), counts = coalesce(p_counts, '{}'::jsonb), error = left(nullif(btrim(p_error), ''), 200)
   where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The guard
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_constraint c where c.conrelid = 'cma.review'::regclass and c.conname = 'review_reference_no_at') then
    alter table cma.review add constraint review_reference_no_at
      check (strpos(coalesce(transaction_ref, ''), '@') = 0 and strpos(coalesce(raw #>> '{transaction,reference}', ''), '@') = 0);
  end if;
end
$$;
comment on column cma.review.transaction_ref is 'The platform''s transaction reference when the adapter''s pattern (connection setting transaction_ref_pattern) accepts it: an order name or id, never an email address (check review_reference_no_at, 0008zf); null otherwise';

-- ---------------------------------------------------------------------------------------------
-- 7. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zf', 'Review reference guard: a review''s transaction reference never holds an email address. cma.review_image_without_at_reference(); cma.audit_row() passes both images of a review through it; cma.clear_review_at_references() clears an @ reference from the stored reviews and their audit rows (transaction_ref null, raw''s transaction removed); a run''s counts take ref_dropped (cma.ingest_sync_run_finish); the check review_reference_no_at on cma.review')
on conflict (version) do nothing;

commit;
reset role;
