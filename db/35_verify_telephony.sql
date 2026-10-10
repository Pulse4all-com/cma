-- =============================================================================================
-- 35_verify_telephony.sql: verifies migration 0007a, telephony
-- =============================================================================================
-- Block A checks structure and privileges; blocks B to F each work on two throwaway tenants inside
-- a subtransaction that is always rolled back. All universal: no seed is assumed. Cloud SQL Studio
-- shows no notices: a check that fails raises "FAIL …" and stops the block. The last result is the
-- verdict. Run as your own IAM login, dev and prod, after 34_telephony.sql; then
-- 33_verify_intake_core.sql and 31_verify_ingest_crm_records.sql again.
--   A  structure and privileges: tables, RLS, audit, no deletes, column privileges, functions,
--      views without raw payloads or hashes, the derived talk time, the one-link-per-side indexes
--   B  telephony calls: created, answered and ended in order and out of order (ended first), the
--      stale guard, unanswered and archived calls, the raw payload filtered, deletion and restore,
--      refusals that write nothing
--   C  tags opened and closed by difference, re-tagging after untagging, the tag and line catalogs
--      refreshed keeping their configuration
--   D  the call link: hash, direction and 120 seconds, nearest first, each side once, null hashes,
--      deleted calls and older calls left out, a second candidate left unlinked; unlink_call and
--      what the next run links
--   E  the privacy deletion clearing linked (and formerly linked) telephony hashes
--   F  permissions (configuration versus ingest), tenant isolation for every new table, no deletes
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
  if not exists (select 1 from cma.schema_migration where version = '0007a') or v_provoke then
    raise exception 'FAIL A1: migration 0007a not recorded';
  end if;

  -- A2. five tenant tables, each with row-level security, the tenant policy and the audit trigger
  foreach v_t in array array['telephony_call', 'telephony_tag', 'telephony_call_tag', 'telephony_number', 'call_link'] loop
    if to_regclass('cma.' || v_t) is null then
      raise exception 'FAIL A2: table cma.% is missing', v_t;
    end if;
    if not (select relrowsecurity from pg_class where oid = to_regclass('cma.' || v_t))
       or not exists (select 1 from pg_policy where polrelid = to_regclass('cma.' || v_t) and polname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = to_regclass('cma.' || v_t) and tgname = 'audit') then
      raise exception 'FAIL A2: cma.% lacks row-level security, its tenant policy or its audit trigger', v_t;
    end if;
  end loop;

  -- A3. the app inserts and never deletes; a tagging changes only in its end, a link only in its
  --     retirement
  foreach v_t in array array['telephony_call', 'telephony_tag', 'telephony_call_tag', 'telephony_number', 'call_link'] loop
    if has_table_privilege('cma_app', 'cma.' || v_t, 'delete') or not has_table_privilege('cma_app', 'cma.' || v_t, 'insert') then
      raise exception 'FAIL A3: cma_app must insert into and never delete from cma.%', v_t;
    end if;
  end loop;
  if not has_table_privilege('cma_app', 'cma.telephony_call', 'update')
     or has_table_privilege('cma_app', 'cma.telephony_call_tag', 'update')
     or has_column_privilege('cma_app', 'cma.telephony_call_tag', 'tagged_at', 'update')
     or has_column_privilege('cma_app', 'cma.telephony_call_tag', 'tag_ref', 'update')
     or not has_column_privilege('cma_app', 'cma.telephony_call_tag', 'untagged_at', 'update')
     or has_table_privilege('cma_app', 'cma.call_link', 'update')
     or has_column_privilege('cma_app', 'cma.call_link', 'crm_call_id', 'update')
     or has_column_privilege('cma_app', 'cma.call_link', 'delta_seconds', 'update')
     or not has_column_privilege('cma_app', 'cma.call_link', 'unlinked_at', 'update')
     or not has_column_privilege('cma_app', 'cma.call_link', 'unlinked_by', 'update') then
    raise exception 'FAIL A3: telephony_call_tag and call_link must be updatable in their end columns only';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'cma.telephony_call_tag'::regclass and tgname = 'check_close_once')
     or not exists (select 1 from pg_trigger where tgrelid = 'cma.call_link'::regclass and tgname = 'check_retire_once') then
    raise exception 'FAIL A3: the close-once and retire-once triggers are missing';
  end if;

  -- A4. the functions: the app may execute them, readers and public may not; none runs as its owner
  foreach v_fn in array array[
    'cma.ingest_upsert_telephony_calls(uuid,jsonb)', 'cma.ingest_upsert_telephony_catalog(uuid,text,jsonb)',
    'cma.link_calls(timestamptz)', 'cma.set_telephony_number(uuid,text,text,boolean)',
    'cma.set_telephony_tag(uuid,text,boolean)', 'cma.unlink_call(uuid)', 'cma.ingest_contact_forget(uuid,text)',
    'cma.telephony_raw(jsonb)', 'cma.telephony_tag_ref(jsonb)'
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
    if (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      raise exception 'FAIL A4: % must run with the caller''s rights', v_fn;
    end if;
  end loop;

  -- A5. reporting views: readers see each view and never the table; no raw payload, hash, key or
  --     secret name; the exact column list of cma_read.telephony_call
  foreach v_t in array array['telephony_call', 'telephony_tag', 'telephony_call_tag', 'telephony_number', 'call_link'] loop
    if not has_table_privilege('cma_readonly', 'cma_read.' || v_t, 'select') or has_table_privilege('cma_readonly', 'cma.' || v_t, 'select') then
      raise exception 'FAIL A5: readers must see cma_read.% and not cma.%', v_t, v_t;
    end if;
  end loop;
  select string_agg(table_name || '.' || column_name, ', ') into v_cols
  from information_schema.columns
  where table_schema = 'cma_read'
    and table_name in ('telephony_call', 'telephony_tag', 'telephony_call_tag', 'telephony_number', 'call_link')
    and (column_name in ('raw', 'counterpart_hash', 'key', 'settings') or column_name like '%hash%'
         or column_name like '%secret%' or column_name like '%token%');
  if v_cols is not null then
    raise exception 'FAIL A5: reporting views expose %', v_cols;
  end if;
  select string_agg(column_name, ', ' order by ordinal_position) into v_cols
  from information_schema.columns where table_schema = 'cma_read' and table_name = 'telephony_call';
  if v_cols is distinct from 'id, tenant_id, connection_id, source_system, source_id, direction, status, missed_reason, started_at, answered_at, ended_at, duration_seconds, talk_seconds, user_ref, number_ref, is_archived, source_version_at, source_deleted_at, synced_at' then
    raise exception 'FAIL A5: cma_read.telephony_call exposes [%]', v_cols;
  end if;

  -- A6. talk time is derived by the database; one current link per side and one current tagging per
  --     call and tag, enforced by partial unique indexes
  if (select attgenerated from pg_attribute where attrelid = 'cma.telephony_call'::regclass and attname = 'talk_seconds') <> 's' then
    raise exception 'FAIL A6: talk_seconds is not a stored generated column';
  end if;
  select count(*) into v_n from pg_index i
  where i.indisunique and i.indpred is not null
    and i.indexrelid in ('cma.call_link_telephony_idx'::regclass, 'cma.call_link_crm_idx'::regclass,
                         'cma.telephony_call_tag_current_idx'::regclass);
  if v_n <> 3 then
    raise exception 'FAIL A6: % of 3 partial unique indexes (one current link per side, one current tagging)', v_n;
  end if;
end
$$;

-- B. Telephony calls (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_ing1     uuid;
  v_tel      uuid;
  v_txt      text;
  v_hash     text := repeat('ab', 32);
  v_s        timestamptz := timestamptz '2026-10-12 10:00:00+00';
  v1         timestamptz := timestamptz '2026-10-12 10:00:01+00';
  v2         timestamptz := timestamptz '2026-10-12 10:00:21+00';
  v3         timestamptz := timestamptz '2026-10-12 10:05:02+00';
  v4         timestamptz := timestamptz '2026-10-12 11:00:00+00';
  r          record;
  q          record;
  e_created  jsonb;
  e_answered jsonb;
  e_ended    jsonb;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007a-one', 'Verify 0007a one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0007a-two', 'Verify 0007a two', 'Europe/Amsterdam');
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_tel', 'Verify telephony one', '900') returning id into v_tel;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);

    -- the three states of one call as the read-back gives them, each at its event's time
    e_created := jsonb_build_object('direction', 'OUTBOUND', 'status', 'initial', 'startedAt', v_s, 'userRef', 'u-1',
                                    'numberRef', 'n-1', 'counterpartHash', upper(v_hash), 'versionAt', v1);
    e_answered := e_created || jsonb_build_object('status', 'answered', 'answeredAt', v_s + interval '20 seconds', 'versionAt', v2);
    e_ended := e_answered || jsonb_build_object('status', 'done', 'endedAt', v_s + interval '5 minutes', 'durationSeconds', 300,
                                                'versionAt', v3,
                                                'raw', jsonb_build_object(
                                                  'status', 'done', 'country_code_a2', 'GB', 'cost', '0.12', 'hangup_cause', 'normal',
                                                  'started_at', 1760263200, 'missed_call_reason', null,
                                                  'raw_digits', '+44 0000 000001', 'asset', 'https://example.com/recording.mp3',
                                                  'comments', jsonb_build_array(jsonb_build_object('content', 'Verify note')),
                                                  'contact', jsonb_build_object('first_name', 'Verify'), 'user_name', 'Verify Agent',
                                                  'free', '+44000000001', 'long', repeat('x', 300)));

    -- B1. out of order: ended arrives first and is inserted; created and answered come later and are
    --     stale; the call ends ended, with talk time 280 s and the filtered raw payload
    select string_agg(o, ',' order by n) into v_txt from (
      select 1 as n, (select u.outcome from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(e_ended || '{"sourceId": "a1"}')) u) as o
      union all
      select 2, (select u.outcome from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(e_created || '{"sourceId": "a1"}')) u)
      union all
      select 3, (select u.outcome from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(e_answered || '{"sourceId": "a1"}')) u)
    ) x;
    select * into r from cma.telephony_call where connection_id = v_tel and source_id = 'a1';
    if v_txt is distinct from 'inserted,stale,stale' or r.status <> 'done' or r.ended_at is null or r.talk_seconds <> 280
       or r.duration_seconds <> 300 or r.source_version_at <> v3 or r.direction <> 'outbound' or r.counterpart_hash <> v_hash
       or r.source_system <> 'verify_tel' or v_provoke then
      raise exception 'FAIL B1: out-of-order events gave % and left %, %, talk %', v_txt, r.status, r.source_version_at, r.talk_seconds;
    end if;
    if r.raw <> '{"cost": "0.12", "status": "done", "started_at": 1760263200, "hangup_cause": "normal", "country_code_a2": "GB"}'::jsonb then
      raise exception 'FAIL B1: the raw payload kept %', r.raw;
    end if;

    -- B2. in order: inserted, updated, updated, ending in the same state as B1's call; a resend of
    --     the same version is an update that changes nothing
    select string_agg(o, ',' order by n) into v_txt from (
      select 1 as n, (select u.outcome from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(e_created || '{"sourceId": "a2"}')) u) as o
      union all
      select 2, (select u.outcome from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(e_answered || '{"sourceId": "a2"}')) u)
      union all
      select 3, (select u.outcome from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(e_ended || '{"sourceId": "a2"}')) u)
      union all
      select 4, (select u.outcome from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(e_ended || '{"sourceId": "a2"}')) u)
    ) x;
    select * into q from cma.telephony_call where connection_id = v_tel and source_id = 'a2';
    if v_txt is distinct from 'inserted,updated,updated,updated'
       or (q.status, q.started_at, q.answered_at, q.ended_at, q.duration_seconds, q.talk_seconds, q.user_ref, q.number_ref,
           q.counterpart_hash, q.source_version_at, q.raw)
          is distinct from
          (r.status, r.started_at, r.answered_at, r.ended_at, r.duration_seconds, r.talk_seconds, r.user_ref, r.number_ref,
           r.counterpart_hash, r.source_version_at, r.raw) then
      raise exception 'FAIL B2: in-order events gave % and a different final state', v_txt;
    end if;

    -- B3. an unanswered inbound call has no talk time and keeps its missed reason; archiving is a
    --     newer version
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 'a3', 'direction', 'inbound', 'status', 'done', 'missedReason', 'no_available_agent',
                         'startedAt', v_s, 'endedAt', v_s + interval '40 seconds', 'durationSeconds', 40, 'versionAt', v3)));
    select * into r from cma.telephony_call where connection_id = v_tel and source_id = 'a3';
    if r.talk_seconds is not null or r.answered_at is not null or r.missed_reason <> 'no_available_agent' or r.is_archived then
      raise exception 'FAIL B3: the unanswered call holds talk %, reason %', r.talk_seconds, r.missed_reason;
    end if;
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 'a3', 'direction', 'inbound', 'status', 'done', 'missedReason', 'no_available_agent',
                         'startedAt', v_s, 'endedAt', v_s + interval '40 seconds', 'durationSeconds', 40, 'isArchived', true,
                         'versionAt', v4)));
    if not (select is_archived from cma.telephony_call where connection_id = v_tel and source_id = 'a3') then
      raise exception 'FAIL B3: the archived call is not archived';
    end if;

    -- B4. deletion clears the hash and the raw payload and keeps id and times; a deletion of an
    --     unknown call writes nothing; a newer read restores the call
    select string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 'a2', 'deletedAt', v4),
      jsonb_build_object('sourceId', 'a9', 'deletedAt', v4))) u;
    select * into r from cma.telephony_call where connection_id = v_tel and source_id = 'a2';
    if v_txt is distinct from 'deleted,unknown' or r.source_deleted_at is null or r.counterpart_hash is not null or r.raw <> '{}'::jsonb
       or r.started_at is null or exists (select 1 from cma.telephony_call where connection_id = v_tel and source_id = 'a9') then
      raise exception 'FAIL B4: deletion gave % and left hash %, raw %', v_txt, r.counterpart_hash, r.raw;
    end if;
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(e_ended || jsonb_build_object('sourceId', 'a2', 'versionAt', v4 + interval '1 minute')));
    if (select source_deleted_at from cma.telephony_call where connection_id = v_tel and source_id = 'a2') is not null then
      raise exception 'FAIL B4: a newer read did not restore the deleted call';
    end if;

    -- B5. refusals, each writing nothing (the valid call in the same batch included): no version,
    --     direction unknown or missing, a phone number as hash, a bad duration, tags not a list, an
    --     empty tag, more than 500 calls
    foreach v_txt in array array[
      '{"direction": "inbound"}',
      '{"direction": "unknown", "versionAt": "2026-10-12T10:00:00Z"}',
      '{"versionAt": "2026-10-12T10:00:00Z"}',
      '{"direction": "inbound", "counterpartHash": "+44000000001", "versionAt": "2026-10-12T10:00:00Z"}',
      '{"direction": "inbound", "durationSeconds": "long", "versionAt": "2026-10-12T10:00:00Z"}',
      '{"direction": "inbound", "tags": {"t": 1}, "versionAt": "2026-10-12T10:00:00Z"}',
      '{"direction": "inbound", "tags": [""], "versionAt": "2026-10-12T10:00:00Z"}'
    ] loop
      begin
        perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
          jsonb_build_object('sourceId', 'b1', 'direction', 'inbound', 'versionAt', v1),
          v_txt::jsonb || '{"sourceId": "b2"}'));
        raise exception 'FAIL B5: the call % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    begin
      perform cma.ingest_upsert_telephony_calls(v_tel,
        (select jsonb_agg(jsonb_build_object('sourceId', 'x' || g, 'direction', 'inbound', 'versionAt', v1)) from generate_series(1, 501) g));
      raise exception 'FAIL B5: 501 calls were accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    if exists (select 1 from cma.telephony_call where connection_id = v_tel and source_id in ('b1', 'b2', 'x1')) then
      raise exception 'FAIL B5: a refused batch wrote a call';
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- C. Tags with history and the catalogs (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_ing1     uuid;
  v_tel      uuid;
  v_n        int;
  v_txt      text;
  v_s        timestamptz := timestamptz '2026-10-12 10:00:00+00';
  r          record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007a-one', 'Verify 0007a one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0007a-two', 'Verify 0007a two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'admin';
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_tel', 'Verify telephony one', '900') returning id into v_tel;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform set_config('app.user_id', v_ing1::text, true);

    -- C1. tags a and b at v1: two current taggings; both join the catalog (b with its name)
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 't1', 'direction', 'outbound', 'versionAt', v_s + interval '1 minute',
                         'tags', jsonb_build_array('tg-a', jsonb_build_object('tagRef', 'tg-b', 'name', 'Verify B')))));
    if (select string_agg(tag_ref || '@' || to_char(tagged_at at time zone 'UTC', 'HH24:MI') || '-' || coalesce(to_char(untagged_at at time zone 'UTC', 'HH24:MI'), 'now'), ','
                          order by tag_ref, tagged_at) from cma.telephony_call_tag where connection_id = v_tel)
       is distinct from 'tg-a@10:01-now,tg-b@10:01-now'
       or (select string_agg(tag_ref || ':' || name || ':' || is_counted, ',' order by tag_ref) from cma.telephony_tag where connection_id = v_tel)
          is distinct from 'tg-a:tg-a:true,tg-b:Verify B:true' or v_provoke then
      raise exception 'FAIL C1: the first tags are %', (select string_agg(tag_ref, ',') from cma.telephony_call_tag where connection_id = v_tel);
    end if;

    -- C2. by difference: at v2 only b (a closes at v2); at v3 a and b again (a reopens in a new row,
    --     b stays open from v1); a stale read with no tags changes nothing; a read without a tags key
    --     leaves them; an empty set at v5 closes both; a tag listed twice opens once
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 't1', 'direction', 'outbound', 'versionAt', v_s + interval '2 minutes', 'tags', jsonb_build_array('tg-b'))));
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 't1', 'direction', 'outbound', 'versionAt', v_s + interval '3 minutes', 'tags', jsonb_build_array('tg-a', 'tg-b'))));
    select string_agg(u.outcome, ',') into v_txt from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 't1', 'direction', 'outbound', 'versionAt', v_s + interval '90 seconds', 'tags', '[]'::jsonb))) u;
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 't1', 'direction', 'outbound', 'versionAt', v_s + interval '4 minutes')));
    if v_txt <> 'stale'
       or (select string_agg(tag_ref || '@' || to_char(tagged_at at time zone 'UTC', 'HH24:MI') || '-' || coalesce(to_char(untagged_at at time zone 'UTC', 'HH24:MI'), 'now'), ','
                             order by tag_ref, tagged_at) from cma.telephony_call_tag where connection_id = v_tel)
          is distinct from 'tg-a@10:01-10:02,tg-a@10:03-now,tg-b@10:01-now' then
      raise exception 'FAIL C2: after untag, re-tag, stale and no-tags reads the history is %',
        (select string_agg(tag_ref || '@' || tagged_at || '-' || coalesce(untagged_at::text, 'now'), ',' order by tag_ref, tagged_at)
         from cma.telephony_call_tag where connection_id = v_tel);
    end if;
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 't1', 'direction', 'outbound', 'versionAt', v_s + interval '5 minutes', 'tags', '[]'::jsonb)));
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 't1', 'direction', 'outbound', 'versionAt', v_s + interval '6 minutes', 'tags', jsonb_build_array('tg-c', 'tg-c'))));
    if (select string_agg(tag_ref || '@' || to_char(tagged_at at time zone 'UTC', 'HH24:MI') || '-' || coalesce(to_char(untagged_at at time zone 'UTC', 'HH24:MI'), 'now'), ','
                          order by tag_ref, tagged_at) from cma.telephony_call_tag where connection_id = v_tel)
       is distinct from 'tg-a@10:01-10:02,tg-a@10:03-10:05,tg-b@10:01-10:05,tg-c@10:06-now' then
      raise exception 'FAIL C2: after the empty set and a doubled tag the history is %',
        (select string_agg(tag_ref || '@' || tagged_at || '-' || coalesce(untagged_at::text, 'now'), ',' order by tag_ref, tagged_at)
         from cma.telephony_call_tag where connection_id = v_tel);
    end if;

    -- C3. a closed tagging never changes, and only its end is writable
    begin
      update cma.telephony_call_tag set untagged_at = now() where connection_id = v_tel and tag_ref = 'tg-b';
      raise exception 'FAIL C3: a closed tagging was closed again';
    exception when sqlstate 'CMA03' then null;
    end;
    begin
      update cma.telephony_call_tag set tagged_at = now() where connection_id = v_tel and tag_ref = 'tg-c';
      raise exception 'FAIL C3: the application changed when a tag was set';
    exception when insufficient_privilege then null;
    end;

    -- C4. the tag catalog: refreshed, configured, refreshed again: is_counted stays, the name follows
    --     the source, missing tags are archived
    v_n := cma.ingest_upsert_telephony_catalog(v_tel, 'tag',
      '[{"tagRef": "tg-a", "name": "Verify A"}, {"tagRef": "tg-b", "name": "Verify B"}, {"tagRef": "tg-z", "name": "Verify Z"}]');
    if v_n <> 3 or (select status from cma.telephony_tag where connection_id = v_tel and tag_ref = 'tg-c') <> 'archived' then
      raise exception 'FAIL C4: the first refresh gave % active tags', v_n;
    end if;
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_telephony_tag(v_tel, 'tg-a', false);
    perform set_config('app.user_id', v_ing1::text, true);
    v_n := cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg-a", "name": "Verify A (renamed)"}]');
    if v_n <> 1
       or (select string_agg(tag_ref || ':' || name || ':' || is_counted || ':' || status, ',' order by tag_ref)
           from cma.telephony_tag where connection_id = v_tel)
          is distinct from 'tg-a:Verify A (renamed):false:active,tg-b:Verify B:true:archived,tg-c:tg-c:true:archived,tg-z:Verify Z:true:archived' then
      raise exception 'FAIL C4: the tag catalog is %', (select string_agg(tag_ref || ':' || is_counted || ':' || status, ',' order by tag_ref)
                                                       from cma.telephony_tag where connection_id = v_tel);
    end if;

    -- C5. the line catalog: digits kept only in E.164, market and is_counted configured and kept by the
    --     next refresh, a missing line archived; a market outside the catalog and an unknown kind are
    --     refused; a line configured before the source lists it joins with its ref as name
    v_n := cma.ingest_upsert_telephony_catalog(v_tel, 'number',
      '[{"numberRef": "n-1", "name": "Verify line NL", "digits": "+31 00 000 0001"}, {"numberRef": "n-2", "name": "Verify line two", "digits": "not a number"}]');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_telephony_number(v_tel, 'n-1', 'NL', true);
    perform cma.set_telephony_number(v_tel, 'n-2', null, false);
    perform cma.set_telephony_number(v_tel, 'n-9', 'NL', true);
    begin
      perform cma.set_telephony_number(v_tel, 'n-1', 'FR', true);
      raise exception 'FAIL C5: a line market outside the catalog was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    perform set_config('app.user_id', v_ing1::text, true);
    begin
      perform cma.ingest_upsert_telephony_catalog(v_tel, 'user', '[]');
      raise exception 'FAIL C5: an unknown catalog kind was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    v_n := cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-1", "name": "Verify line NL (renamed)", "digits": "+310000000001"}]');
    if v_n <> 1
       or (select string_agg(number_ref || ':' || name || ':' || coalesce(digits, '-') || ':' || coalesce(market, '-') || ':' || is_counted || ':' || status, ','
                             order by number_ref) from cma.telephony_number where connection_id = v_tel)
          is distinct from 'n-1:Verify line NL (renamed):+310000000001:NL:true:active,n-2:Verify line two:-:-:false:archived,n-9:n-9:-:NL:true:archived' then
      raise exception 'FAIL C5: the line catalog is %', (select string_agg(number_ref || ':' || coalesce(digits, '-') || ':' || coalesce(market, '-') || ':' || status, ','
                                                         order by number_ref) from cma.telephony_number where connection_id = v_tel);
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- D. The call link (throwaway tenants, rolled back)
--    Telephony calls T1 to T8 on one connection, CRM calls K1 to K8 on another, all at or near
--    10:00 UTC on 12 October 2026 unless stated:
--      T1 out H1 10:00     K1 out H1 10:00:30, K2 out H1 10:01:30  -> T1-K1 (nearest), K2 left
--      T2 in  H2 10:00     K3 out H2 10:00:10                      -> different direction
--      T3 out --  10:00    K4 out --  10:00                        -> no hash, no link
--      T4 out H3 10:00     K5 out H3 10:02:30                      -> 150 s apart
--      T5 out H4 10:00, T6 out H4 10:01, K6 out H4 10:00:50        -> T6-K6 (10 s), T5 left
--      T7 out H5 two days earlier, K7 5 s later                    -> only with an earlier start
--      T8 out H6 10:00     K8 out H6 10:00, deleted                -> deleted, no link
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_agent    uuid;
  v_ing1     uuid;
  v_tel      uuid;
  v_crm      uuid;
  v_n        int;
  v_txt      text;
  v_link     uuid;
  v_s        timestamptz := timestamptz '2026-10-12 10:00:00+00';
  h1         text := repeat('11', 32);
  h2         text := repeat('22', 32);
  h3         text := repeat('33', 32);
  h4         text := repeat('44', 32);
  h5         text := repeat('55', 32);
  h6         text := repeat('66', 32);
  r          record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007a-one', 'Verify 0007a one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0007a-two', 'Verify 0007a two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id from (values (v_admin, 'admin'), (v_agent, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_tel', 'Verify telephony one', '900') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_crm', 'Verify CRM one', '111') returning id into v_crm;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);

    perform cma.ingest_upsert_telephony_calls(v_tel, (
      select jsonb_agg(jsonb_build_object('sourceId', x.id, 'direction', x.dir, 'counterpartHash', x.h, 'startedAt', x.at,
                                          'versionAt', v_s + interval '10 minutes'))
      from (values ('T1', 'outbound', h1, v_s), ('T2', 'inbound', h2, v_s), ('T3', 'outbound', null, v_s),
                   ('T4', 'outbound', h3, v_s), ('T5', 'outbound', h4, v_s), ('T6', 'outbound', h4, v_s + interval '60 seconds'),
                   ('T7', 'outbound', h5, v_s - interval '2 days'), ('T8', 'outbound', h6, v_s)) as x(id, dir, h, at)));
    perform cma.ingest_upsert_calls(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', x.id, 'direction', 'outbound', 'counterpartHash', x.h, 'occurredAt', x.at,
                                          'updatedAt', v_s + interval '10 minutes'))
      from (values ('K1', h1, v_s + interval '30 seconds'), ('K2', h1, v_s + interval '90 seconds'), ('K3', h2, v_s + interval '10 seconds'),
                   ('K4', null, v_s), ('K5', h3, v_s + interval '150 seconds'), ('K6', h4, v_s + interval '50 seconds'),
                   ('K7', h5, v_s - interval '2 days' + interval '5 seconds'), ('K8', h6, v_s)) as x(id, h, at)));
    perform cma.ingest_upsert_calls(v_crm, jsonb_build_array(jsonb_build_object('sourceId', 'K8', 'deletedAt', v_s + interval '11 minutes')));

    -- D1. from an hour before: T1-K1 (nearest of two) and T6-K6 (nearest of two); nothing else
    v_n := cma.link_calls(v_s - interval '1 hour');
    select string_agg(t.source_id || '>' || k.source_id || ':' || l.delta_seconds || ':' || l.method, ',' order by t.source_id) into v_txt
    from cma.call_link l join cma.telephony_call t on t.id = l.telephony_call_id join cma.crm_call k on k.id = l.crm_call_id
    where l.unlinked_at is null;
    if v_n <> 2 or v_txt is distinct from 'T1>K1:-30:hash_time,T6>K6:10:hash_time' or v_provoke then
      raise exception 'FAIL D1: link_calls made % link(s): %', v_n, v_txt;
    end if;
    if (select linked_by from cma.call_link l join cma.telephony_call t on t.id = l.telephony_call_id where t.source_id = 'T1') <> v_ing1 then
      raise exception 'FAIL D1: the link does not name the Ingest user';
    end if;

    -- D2. a second run links nothing; an earlier start reaches T7-K7; a start without a time is refused
    v_n := cma.link_calls(v_s - interval '1 hour');
    if v_n <> 0 then
      raise exception 'FAIL D2: a second run made % link(s)', v_n;
    end if;
    v_n := cma.link_calls(v_s - interval '3 days');
    if v_n <> 1 or not exists (select 1 from cma.call_link l join cma.telephony_call t on t.id = l.telephony_call_id
                               join cma.crm_call k on k.id = l.crm_call_id where t.source_id = 'T7' and k.source_id = 'K7' and l.delta_seconds = -5) then
      raise exception 'FAIL D2: the earlier start made % link(s)', v_n;
    end if;
    begin
      perform cma.link_calls(null);
      raise exception 'FAIL D2: link_calls without a start was accepted';
    exception when sqlstate 'CMA04' then null;
    end;

    -- D3. each side once, also when written directly; a link is never rewritten
    begin
      insert into cma.call_link (telephony_call_id, crm_call_id, method, delta_seconds)
      values ((select id from cma.telephony_call where source_id = 'T6'), (select id from cma.crm_call where source_id = 'K2'), 'hash_time', 0);
      raise exception 'FAIL D3: a second current link for T6 was accepted';
    exception when unique_violation then null;
    end;
    begin
      update cma.call_link set crm_call_id = (select id from cma.crm_call where source_id = 'K2');
      raise exception 'FAIL D3: the application rewrote a link';
    exception when insufficient_privilege then null;
    end;

    -- D4. unlink: the Ingest user and an agent may not; a person with tenant.configure retires T1-K1
    --     once, recorded with their id; an unknown link is refused; the next run never links T1-K1
    --     again but pairs T1 with its other candidate K2
    select l.id into v_link from cma.call_link l join cma.telephony_call t on t.id = l.telephony_call_id where t.source_id = 'T1';
    begin
      perform cma.unlink_call(v_link);
      raise exception 'FAIL D4: the Ingest user retired a link';
    exception when sqlstate 'CMA06' then null;
    end;
    perform set_config('app.user_id', v_agent::text, true);
    begin
      perform cma.unlink_call(v_link);
      raise exception 'FAIL D4: an agent retired a link';
    exception when sqlstate 'CMA06' then null;
    end;
    begin
      perform cma.link_calls(v_s - interval '1 hour');
      raise exception 'FAIL D4: an agent ran link_calls';
    exception when sqlstate 'CMA06' then null;
    end;
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.unlink_call(v_link);
    begin
      perform cma.unlink_call(v_link);
      raise exception 'FAIL D4: a link was retired twice';
    exception when sqlstate 'CMA03' then null;
    end;
    begin
      perform cma.unlink_call(uuidv7());
      raise exception 'FAIL D4: an unknown link was retired';
    exception when sqlstate 'CMA02' then null;
    end;
    select * into r from cma.call_link where id = v_link;
    if r.unlinked_at is null or r.unlinked_by <> v_admin then
      raise exception 'FAIL D4: the retired link holds %, %', r.unlinked_at, r.unlinked_by;
    end if;
    begin
      update cma.call_link set unlinked_at = now(), unlinked_by = v_admin where id = v_link;
      raise exception 'FAIL D4: a retired link was retired again directly';
    exception when sqlstate 'CMA03' then null;
    end;
    v_n := cma.link_calls(v_s - interval '1 hour');
    select string_agg(t.source_id || '>' || k.source_id || ':' || l.delta_seconds, ',' order by t.source_id) into v_txt
    from cma.call_link l join cma.telephony_call t on t.id = l.telephony_call_id join cma.crm_call k on k.id = l.crm_call_id
    where l.unlinked_at is null;
    if v_n <> 1 or v_txt is distinct from 'T1>K2:-90,T6>K6:10,T7>K7:-5'
       or (select count(*) from cma.call_link) <> 4 then
      raise exception 'FAIL D4: after the unlink the links are % (% made)', v_txt, v_n;
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- E. The privacy deletion (throwaway tenants, rolled back)
--    Contact c1 has CRM calls K1 (linked to T1) and K4 (linked to T4, then the link is retired);
--    contact c2 has K2 (linked to T2); T3 carries c1's hash but was never linked.
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_ing1     uuid;
  v_tel      uuid;
  v_crm      uuid;
  v_res      jsonb;
  v_s        timestamptz := timestamptz '2026-10-12 10:00:00+00';
  h1         text := repeat('a1', 32);
  h2         text := repeat('b2', 32);
  h4         text := repeat('d4', 32);
begin
  begin
    v_t1 := cma.create_tenant('verify-0007a-one', 'Verify 0007a one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0007a-two', 'Verify 0007a two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'admin';
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_tel', 'Verify telephony one', '900') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_crm', 'Verify CRM one', '111') returning id into v_crm;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);

    perform cma.ingest_upsert_records(v_crm, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'contactId', 'c1', 'createdAt', v_s, 'updatedAt', v_s),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd2', 'contactId', 'c2', 'createdAt', v_s, 'updatedAt', v_s)));
    perform cma.ingest_upsert_contacts(v_crm, jsonb_build_array(
      jsonb_build_object('sourceId', 'c1', 'country', 'NL', 'updatedAt', v_s),
      jsonb_build_object('sourceId', 'c2', 'country', 'NL', 'updatedAt', v_s)));
    perform cma.ingest_upsert_telephony_calls(v_tel, (
      select jsonb_agg(jsonb_build_object('sourceId', x.id, 'direction', 'outbound', 'counterpartHash', x.h, 'startedAt', x.at,
                                          'versionAt', v_s + interval '10 minutes'))
      from (values ('T1', h1, v_s), ('T2', h2, v_s), ('T3', h1, v_s + interval '1 day'), ('T4', h4, v_s)) as x(id, h, at)));
    perform cma.ingest_upsert_calls(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', x.id, 'direction', 'outbound', 'counterpartHash', x.h, 'occurredAt', v_s,
                                          'updatedAt', v_s + interval '10 minutes'))
      from (values ('K1', h1), ('K2', h2), ('K4', h4)) as x(id, h)));
    perform cma.ingest_upsert_associations(v_crm, (
      select jsonb_agg(jsonb_build_object('fromType', 'crm_call', 'fromId', x.k, 'toType', 'contact', 'toId', x.c,
                                          'removed', false, 'changedAt', v_s))
      from (values ('K1', 'c1'), ('K2', 'c2'), ('K4', 'c1')) as x(k, c)));
    perform cma.link_calls(v_s - interval '1 hour');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.unlink_call((select l.id from cma.call_link l join cma.telephony_call t on t.id = l.telephony_call_id where t.source_id = 'T4'));
    perform set_config('app.user_id', v_ing1::text, true);
    if (select count(*) from cma.call_link where unlinked_at is null) <> 2 or v_provoke then
      raise exception 'FAIL E1: % current links before the deletion, expected 2', (select count(*) from cma.call_link where unlinked_at is null);
    end if;

    -- E1. forget c1: its CRM calls and the telephony calls linked to them (now or formerly) lose the
    --     hash; c2's calls and the never-linked T3 keep theirs; ids, times and links stay
    v_res := cma.ingest_contact_forget(v_crm, 'c1');
    if v_res <> '{"contacts": 1, "refs": 0, "calls": 2, "submissions": 0, "telephony_calls": 2}'::jsonb
       or (select string_agg(source_id || ':' || coalesce(left(counterpart_hash, 2), '-'), ',' order by source_id) from cma.telephony_call)
          is distinct from 'T1:-,T2:b2,T3:a1,T4:-'
       or (select string_agg(source_id || ':' || coalesce(left(counterpart_hash, 2), '-'), ',' order by source_id) from cma.crm_call)
          is distinct from 'K1:-,K2:b2,K4:-'
       or (select count(*) from cma.call_link) <> 3 or (select count(*) from cma.telephony_call where started_at is null) <> 0 then
      raise exception 'FAIL E1: forget answered % and left telephony %', v_res,
        (select string_agg(source_id || ':' || coalesce(left(counterpart_hash, 2), '-'), ',' order by source_id) from cma.telephony_call);
    end if;

    -- E2. without a telephony hash to clear, the answer keeps 0007's shape
    v_res := cma.ingest_contact_forget(v_crm, 'c9');
    if v_res <> '{"contacts": 0, "refs": 0, "calls": 0, "submissions": 0}'::jsonb then
      raise exception 'FAIL E2: forget of an unknown contact answered %', v_res;
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- F. Permissions, tenant isolation and no deletes (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_admin2   uuid;
  v_ing1     uuid;
  v_ing2     uuid;
  v_tel      uuid;
  v_crm      uuid;
  v_tel2     uuid;
  v_crm2     uuid;
  v_t        text;
  v_n        bigint;
  v_txt      text;
  v_s        timestamptz := timestamptz '2026-10-12 10:00:00+00';
  h1         text := repeat('e1', 32);
  h2         text := repeat('f2', 32);
  v_link     uuid;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007a-one', 'Verify 0007a one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0007a-two', 'Verify 0007a two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin@example.invalid', 'Verify admin two') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin), (v_t2, v_admin2)) as x(tid, uid)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = 'admin';
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    select id into v_ing2 from cma.app_user where tenant_id = v_t2 and email = 'ingest@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_tel', 'Verify telephony one', '900') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_crm', 'Verify CRM one', '111') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verify_tel', 'Verify telephony two', '901') returning id into v_tel2;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verify_crm', 'Verify CRM two', '222') returning id into v_crm2;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);

    -- F1. the Ingest user cannot configure; a configuring person cannot write as the ingest
    perform set_config('app.user_id', v_ing1::text, true);
    foreach v_txt in array array[
      format('select cma.set_telephony_number(%L, ''n-1'', null, true)', v_tel),
      format('select cma.set_telephony_tag(%L, ''tg-1'', false)', v_tel),
      format('select cma.unlink_call(%L)', uuidv7())
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
    perform set_config('app.user_id', v_admin::text, true);
    foreach v_txt in array array[
      format('select cma.ingest_upsert_telephony_calls(%L, ''[]'')', v_tel),
      format('select cma.ingest_upsert_telephony_catalog(%L, ''tag'', ''[]'')', v_tel),
      format('select cma.ingest_contact_forget(%L, ''c1'')', v_crm)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL F1: a configuring person ran %', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;

    -- F2. tenant one fills every new table: a tagged call, a line, a link
    perform cma.set_telephony_number(v_tel, 'n-1', null, true);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 'T1', 'direction', 'outbound', 'counterpartHash', h1, 'startedAt', v_s,
                         'versionAt', v_s, 'tags', jsonb_build_array('tg-1'))));
    perform cma.ingest_upsert_calls(v_crm, jsonb_build_array(
      jsonb_build_object('sourceId', 'K1', 'direction', 'outbound', 'counterpartHash', h1, 'occurredAt', v_s, 'updatedAt', v_s),
      jsonb_build_object('sourceId', 'K2', 'direction', 'outbound', 'counterpartHash', h2, 'occurredAt', v_s, 'updatedAt', v_s)));
    if cma.link_calls(v_s - interval '1 hour') <> 1 then
      raise exception 'FAIL F2: tenant one''s calls did not link';
    end if;
    select id into v_link from cma.call_link;

    -- F3. tenant two sees none of it, cannot write to tenant one's connection, cannot configure it,
    --     and its calls with the same hashes and times never link to tenant one's
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    foreach v_t in array array['telephony_call', 'telephony_tag', 'telephony_call_tag', 'telephony_number', 'call_link'] loop
      execute format('select count(*) from cma.%I', v_t) into v_n;
      if v_n <> 0 then
        raise exception 'FAIL F3: tenant two sees % row(s) of tenant one in cma.%', v_n, v_t;
      end if;
    end loop;
    foreach v_txt in array array[
      format('select cma.ingest_upsert_telephony_calls(%L, ''[]'')', v_tel),
      format('select cma.ingest_upsert_telephony_catalog(%L, ''number'', ''[]'')', v_tel)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL F3: tenant two ran %', v_txt;
      exception when sqlstate 'CMA02' then null;
      end;
    end loop;
    perform cma.ingest_upsert_telephony_calls(v_tel2, jsonb_build_array(
      jsonb_build_object('sourceId', 'T2', 'direction', 'outbound', 'counterpartHash', h2, 'startedAt', v_s, 'versionAt', v_s)));
    perform cma.ingest_upsert_calls(v_crm2, jsonb_build_array(
      jsonb_build_object('sourceId', 'K9', 'direction', 'outbound', 'counterpartHash', h1, 'occurredAt', v_s, 'updatedAt', v_s)));
    if cma.link_calls(v_s - interval '1 hour') <> 0 or (select count(*) from cma.call_link) <> 0 then
      raise exception 'FAIL F3: tenant two linked across tenants';
    end if;
    perform set_config('app.user_id', v_admin2::text, true);
    foreach v_txt in array array[
      format('select cma.set_telephony_number(%L, ''n-1'', null, false)', v_tel),
      format('select cma.set_telephony_tag(%L, ''tg-1'', false)', v_tel),
      format('select cma.unlink_call(%L)', v_link)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL F3: tenant two''s admin ran %', v_txt;
      exception when sqlstate 'CMA02' then null;
      end;
    end loop;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    if (select string_agg(t.source_id || '>' || k.source_id, ',') from cma.call_link l
        join cma.telephony_call t on t.id = l.telephony_call_id join cma.crm_call k on k.id = l.crm_call_id) is distinct from 'T1>K1'
       or (select is_counted from cma.telephony_number where number_ref = 'n-1') is distinct from true then
      raise exception 'FAIL F3: tenant one''s links or lines changed under tenant two';
    end if;

    -- F4. no deletes on the new tables, whoever acts
    foreach v_t in array array['telephony_call', 'telephony_tag', 'telephony_call_tag', 'telephony_number', 'call_link'] loop
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

-- Verdict: per tenant, the telephony configuration and what has arrived so far
select t.slug as tenant,
       (select count(*) from cma.telephony_number n where n.tenant_id = t.id) as lines,
       (select count(*) from cma.telephony_tag g where g.tenant_id = t.id) as tags,
       (select count(*) from cma.telephony_call c where c.tenant_id = t.id) as telephony_calls,
       (select count(*) from cma.call_link l where l.tenant_id = t.id and l.unlinked_at is null) as call_links,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
