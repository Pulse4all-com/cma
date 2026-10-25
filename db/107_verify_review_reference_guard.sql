-- =============================================================================================
-- 107_verify_review_reference_guard.sql: verifies addition 0008zf, the review reference guard
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure, privileges and that
-- the database holds no @ reference; block B works on a throwaway tenant inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; connections, channels and reviews are invented data
-- values, and the only email-like value is an example.invalid address that the checks expect to be refused or
-- removed. Every check writes one row, PASS or FAIL, and the last result lists them with the verdict, because Cloud
-- SQL Studio shows no notices. Run as your own IAM login in dev, after 106_review_reference_guard.sql; then 105, 77,
-- 75, 67 and 33 again.
--   A  structure and privileges: the addition row after 0008ze; the check review_reference_no_at on cma.review,
--      validated; the scrub helper immutable, the application's and the owner's, not PUBLIC's; the cleanup the owner's
--      only; cma.audit_row() with the review branch and 0008q's three branches; no review and no audit row of a review
--      in this database holds an @ (the acceptance query of brief B18.1)
--   B  behaviour, on a throwaway tenant with a reviews connection and one channel: the guard refuses an @ reference
--      in transaction_ref and in raw (CMA04 through ingest, 23514 for a direct update); a normal reference is kept and
--      a dropped one stored as nothing; a review staged as 0008ze could store it (the check dropped inside the block)
--      gets a clean audit image at write time; the cleanup clears it and a legacy audit row, keeps the link, leaves its
--      own audit row clean, finds nothing on a rerun, and the check validates again; the helper's cases; a run's
--      counts take ref_dropped
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 107 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008zf;
create temp table verify_0008zf (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zf_code(p_sql text)
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

-- One review as the adapter hands it to cma.ingest_upsert_reviews: a reference in the item and in raw, either may be null
create or replace function pg_temp.v0008zf_item(p_id text, p_channel text, p_ref text, p_raw_ref text)
returns jsonb
language sql
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'reviewId', p_id, 'channelId', p_channel, 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
    'rating', 4, 'submittedAt', '2024-06-16T10:00:00Z', 'updatedAt', '2024-06-16T10:00:00Z', 'transactionRef', p_ref,
    'raw', jsonb_strip_nulls(jsonb_build_object('id', p_id, 'channelRef', p_channel, 'rating', 4, 'state', 'APPROVED',
                                                'transaction', case when p_raw_ref is null then null
                                                                    else jsonb_build_object('reference', p_raw_ref) end))))
$$;

-- A. Structure, privileges and the database's state (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_src     text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008ze
  insert into verify_0008zf values (1, 'A1 addition 0008zf recorded, after 0008ze',
    case when exists (select 1 from cma.schema_migration where version = '0008zf')
              and exists (select 1 from cma.schema_migration where version = '0008ze') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the guard: one validated check on cma.review naming both places
  select pg_get_constraintdef(c.oid) || case when c.convalidated then '' else ' (not validated)' end into v_bad
  from pg_constraint c where c.conrelid = 'cma.review'::regclass and c.conname = 'review_reference_no_at' and c.contype = 'c';
  insert into verify_0008zf values (2, 'A2 the check review_reference_no_at on cma.review, validated, on transaction_ref and raw',
    case when v_bad like '%transaction_ref%' and v_bad like '%{transaction,reference}%' and v_bad like '%@%'
              and v_bad not like '%(not validated)%' and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce(v_bad, 'missing'));

  -- A3. the functions: the helper immutable, invoker's rights, the application's and not PUBLIC's; the cleanup the
  --     owner's only; cma.audit_row() with the review branch and 0008q's three branches
  v_bad := '';
  if (select provolatile from pg_proc where oid = to_regprocedure('cma.review_image_without_at_reference(jsonb)')) is distinct from 'i'
     or (select prosecdef from pg_proc where oid = to_regprocedure('cma.review_image_without_at_reference(jsonb)'))
     or not has_function_privilege('cma_app', 'cma.review_image_without_at_reference(jsonb)', 'execute')
     or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                where p.oid = to_regprocedure('cma.review_image_without_at_reference(jsonb)') and a.grantee = 0) then
    v_bad := v_bad || 'helper; ';
  end if;
  if to_regprocedure('cma.clear_review_at_references()') is null
     or has_function_privilege('cma_app', 'cma.clear_review_at_references()', 'execute')
     or has_function_privilege('cma_readonly', 'cma.clear_review_at_references()', 'execute')
     or (select prosecdef from pg_proc where oid = to_regprocedure('cma.clear_review_at_references()')) then
    v_bad := v_bad || 'cleanup; ';
  end if;
  select prosrc into v_src from pg_proc where oid = 'cma.audit_row()'::regprocedure;
  if v_src !~ 'tg_table_name = ''review''' or v_src !~ 'review_image_without_at_reference\(v_old\)'
     or v_src !~ 'review_image_without_at_reference\(v_new\)' or v_src !~ 'token_hash' or v_src !~ 'ingest_event'
     or v_src !~ 'uncounted_line' then
    v_bad := v_bad || 'audit_row; ';
  end if;
  insert into verify_0008zf values (3, 'A3 the helper, the cleanup''s rights and cma.audit_row() with the review branch',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the database holds no @ in a review or in an audit row of one (brief B18.1's acceptance query)
  v_bad := (select count(*) from cma.review r where r.raw::text like '%@%' or coalesce(r.transaction_ref, '') like '%@%')::text
           || ' ' || (select count(*) from cma.audit_log a
                      where a.table_name = 'review' and (coalesce(a.old_row::text, '') like '%@%' or coalesce(a.new_row::text, '') like '%@%'))::text;
  insert into verify_0008zf values (4, 'A4 no review and no audit row of a review holds an @',
    case when v_bad = '0 0' and not v_provoke then 'PASS' else 'FAIL' end, 'reviews, audit rows: ' || v_bad);
end
$$;

-- B. Behaviour on a throwaway tenant (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_ing1 uuid; v_rev uuid; v_id uuid; v_legacy uuid;
  v_txt text; v_a text;
  v_mail constant text := 'buyer.ref@example.invalid';
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- the tenant, its Ingest user and a reviews connection with one channel (as the owner, then the Ingest user)
    v_t1 := cma.create_tenant('verify-0008zf-one', 'Verify 0008zf one', 'Europe/Amsterdam');
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyreviews', 'Verify reviews', 'acc-zf', 'reviews') returning id into v_rev;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_review_channels(v_rev, '[{"channelId": "chl-zf", "name": "Shop ZF", "locale": "en_GB"}]');

    -- B1. the guard refuses an @ reference: in the item and raw, in raw only (the Ingest user, CMA04, nothing stored);
    --     a direct update of a stored review by the owner (23514)
    v_txt := pg_temp.v0008zf_code(format('select * from cma.ingest_upsert_reviews(%L, %L)', v_rev,
                                         jsonb_build_array(pg_temp.v0008zf_item('rev-at-1', 'chl-zf', v_mail, v_mail))))
             || ' ' || pg_temp.v0008zf_code(format('select * from cma.ingest_upsert_reviews(%L, %L)', v_rev,
                                                   jsonb_build_array(pg_temp.v0008zf_item('rev-at-2', 'chl-zf', null, v_mail))))
             || ' ' || (select count(*) from cma.review r where r.tenant_id = v_t1);
    perform cma.ingest_upsert_reviews(v_rev, jsonb_build_array(pg_temp.v0008zf_item('rev-ok-1', 'chl-zf', 'ORD-990001', 'ORD-990001'),
                                                               pg_temp.v0008zf_item('rev-ok-2', 'chl-zf', null, null)));
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' ' || pg_temp.v0008zf_code(format('update cma.review set transaction_ref = %L where tenant_id = %L and source_id = %L',
                                                         v_mail, v_t1, 'rev-ok-1'))
             || ' ' || pg_temp.v0008zf_code(format('update cma.review set raw = raw || %L::jsonb where tenant_id = %L and source_id = %L',
                                                   jsonb_build_object('transaction', jsonb_build_object('reference', v_mail)), v_t1, 'rev-ok-2'));
    v_rows := v_rows || array['11', 'B1 the guard: an @ reference refused through ingest (in the item, in raw) and by a direct update',
      case when v_txt = 'CMA04 CMA04 0 23514 23514' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. a normal reference is kept in the column and raw; a review without one stores nothing of it
    v_txt := (select string_agg(r.source_id || ':' || coalesce(r.transaction_ref, '-') || ':' || coalesce(r.raw #>> '{transaction,reference}', '-'),
                                ' ' order by r.source_id)
              from cma.review r where r.tenant_id = v_t1);
    v_rows := v_rows || array['12', 'B2 a normal reference kept in the column and raw, none stored as nothing',
      case when v_txt = 'rev-ok-1:ORD-990001:ORD-990001 rev-ok-2:-:-' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. a review as 0008ze could store it (the check dropped inside this block, as the owner, then the Ingest user):
    --     the row holds the address, its insert audit row does not (cma.audit_row() scrubs the image at write time)
    alter table cma.review drop constraint review_reference_no_at;
    perform set_config('role', 'cma_app', true);
    perform cma.ingest_upsert_reviews(v_rev, jsonb_build_array(pg_temp.v0008zf_item('rev-at-3', 'chl-zf', v_mail, v_mail)));
    perform set_config('role', 'cma_owner', true);
    select r.id into v_id from cma.review r where r.tenant_id = v_t1 and r.source_id = 'rev-at-3';
    v_txt := (select (strpos(coalesce(r.transaction_ref, ''), '@') > 0 and strpos(r.raw::text, '@') > 0)::text
              from cma.review r where r.id = v_id)
             || ' ' || (select count(*) || ':' || bool_and(a.new_row ->> 'transaction_ref' is null and not ((a.new_row -> 'raw') ? 'transaction')
                                                     and a.new_row ->> 'source_id' = 'rev-at-3')
                        from cma.audit_log a where a.table_name = 'review' and a.row_id = v_id::text and a.action = 'insert');
    v_rows := v_rows || array['13', 'B3 the audit image of a review is written without the @ reference',
      case when v_txt = 'true 1:true' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. the cleanup: a legacy audit row as before 0008zf (both images with the address); the counts; the review
    --     without the reference, its link and rating kept; the legacy row scrubbed, its other keys kept; the cleanup's
    --     own audit row clean; nothing @ left for the tenant; a rerun finds nothing; the check validates again
    insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_label)
    select r.tenant_id, 'review', 'update', to_jsonb(r), to_jsonb(r) || '{"has_reply": true}'::jsonb, 'verify-0008zf-legacy'
    from cma.review r where r.id = v_id
    returning id into v_legacy;
    v_a := (select r.link_level || ':' || r.rating from cma.review r where r.id = v_id);
    v_txt := (select c.reviews_cleared || '/' || c.audit_rows_scrubbed from cma.clear_review_at_references() c);
    v_txt := v_txt || ' ' || (select coalesce(r.transaction_ref, '-') || ':' || (r.raw ? 'transaction')::text || ':'
                                     || (r.link_level || ':' || r.rating = v_a)::text
                              from cma.review r where r.id = v_id)
             || ' ' || (select (a.old_row ->> 'transaction_ref' is null and a.new_row ->> 'transaction_ref' is null
                                and not ((a.old_row -> 'raw') ? 'transaction') and not ((a.new_row -> 'raw') ? 'transaction')
                                and a.old_row ->> 'source_id' = 'rev-at-3' and a.new_row ->> 'has_reply' = 'true')::text
                        from cma.audit_log a where a.id = v_legacy)
             || ' ' || (select count(*) || ':' || coalesce(bool_and(strpos(a.old_row::text, '@') = 0 and strpos(a.new_row::text, '@') = 0), false)
                        from cma.audit_log a where a.table_name = 'review' and a.row_id = v_id::text and a.action = 'update'
                          and a.id <> v_legacy)
             || ' ' || (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'review'
                          and (strpos(coalesce(a.old_row::text, ''), '@') > 0 or strpos(coalesce(a.new_row::text, ''), '@') > 0))
             || ' ' || (select c.reviews_cleared || '/' || c.audit_rows_scrubbed from cma.clear_review_at_references() c);
    -- the check again, in a statement of its own (an ALTER TABLE inside the statement that ran the cleanup meets its
    -- pending trigger events)
    v_txt := v_txt || ' ' || pg_temp.v0008zf_code('alter table cma.review add constraint review_reference_no_at check (strpos(coalesce(transaction_ref, '''')'
                                                  || ', ''@'') = 0 and strpos(coalesce(raw #>> ''{transaction,reference}'', ''''), ''@'') = 0)');
    v_rows := v_rows || array['14', 'B4 the cleanup: counts, the review and the legacy audit row cleared, its own row clean, a rerun, the check again',
      case when v_txt = '1/1 -:false:true true 1:true 0 0/0 ok' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. the helper: nothing for nothing, a non-object as it is, the reference cleared where it holds an @ and only there
    v_txt := coalesce(cma.review_image_without_at_reference(null)::text, 'null')
             || ' ' || cma.review_image_without_at_reference('"text"'::jsonb)::text
             || ' ' || (cma.review_image_without_at_reference('{"transaction_ref": "ORD-1", "raw": {"transaction": {"reference": "ORD-1"}}}')
                        = '{"transaction_ref": "ORD-1", "raw": {"transaction": {"reference": "ORD-1"}}}'::jsonb)::text
             || ' ' || cma.review_image_without_at_reference(jsonb_build_object('transaction_ref', v_mail, 'raw',
                                                                                jsonb_build_object('transaction', jsonb_build_object('reference', 'ORD-1'))))::text
             || ' ' || cma.review_image_without_at_reference(jsonb_build_object('transaction_ref', 'ORD-1', 'raw',
                                                                                jsonb_build_object('id', 'x', 'transaction', jsonb_build_object('reference', v_mail))))::text;
    v_rows := v_rows || array['15', 'B5 the helper: null, a non-object, a clean image, the column only, raw only',
      case when v_txt = 'null "text" true {"raw": {"transaction": {"reference": "ORD-1"}}, "transaction_ref": null} '
                        || '{"raw": {"id": "x"}, "transaction_ref": "ORD-1"}'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. a reviews run finishes with ref_dropped among its counts (the Ingest user); a key outside the list is still
    --     refused (CMA04)
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_id := cma.ingest_sync_run_start(v_rev, 'reviews_poll', 'reviews', null, null);
    v_txt := pg_temp.v0008zf_code(format('select cma.ingest_sync_run_finish(%L, ''succeeded'', ''{"fetched": 3, "upserted": 2, "ref_dropped": 1}'')', v_id));
    -- the counts read in a statement of their own (the one that finished the run sees the row as it was before)
    v_txt := v_txt || ' ' || (select r.counts::text from cma.sync_run r where r.id = v_id);
    v_txt := v_txt || ' ' || pg_temp.v0008zf_code(format('select cma.ingest_sync_run_finish(cma.ingest_sync_run_start(%L, ''reviews_poll'', ''reviews'', null, null), '
                                                   || '''succeeded'', ''{"fetched": 1, "references": 1}'')', v_rev));
    v_rows := v_rows || array['16', 'B6 a run''s counts take ref_dropped; a key outside the list is refused',
      case when v_txt = 'ok {"fetched": 3, "upserted": 2, "ref_dropped": 1} CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['19', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zf (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zf values (19, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zf
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008zf where result = 'PASS') = 10
                       and not exists (select 1 from verify_0008zf where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('107_verify_review_reference_guard: %s PASS, %s FAIL', (select count(*) from verify_0008zf where result = 'PASS'),
                                                                          (select count(*) from verify_0008zf where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008zf_code(text);
drop function if exists pg_temp.v0008zf_item(text, text, text, text);
reset role;
