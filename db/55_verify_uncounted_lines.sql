-- =============================================================================================
-- 55_verify_uncounted_lines.sql: verifies addition 0008f, a telephony connection stores calls on
-- its counted lines only
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used, adapters, lines, tags and calls
-- are invented data values. Every check writes one row, PASS or FAIL, and the last result lists
-- them with the verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login in
-- dev, after 54_uncounted_lines.sql; then 35_verify_telephony.sql, 33_verify_intake_core.sql and
-- 31_verify_ingest_crm_records.sql again (unchanged).
--   A  structure and privileges: the migration row, the trigger on the lines and its SECURITY
--      DEFINER function, the removals the owner's only, the application still never deleting,
--      no stored call left on a line that does not count (in any tenant)
--   B  behaviour: a counted line stored; an uncounted line skipped with its outcome (a deletion
--      too, nothing of the call or its tags written); an unknown line stored; switching a line off
--      removing its calls, taggings and links (a retired link included) and leaving the CRM calls
--      and the connection's other lines; the audit rows of those deletes holding ids only; another
--      connection's and another tenant's calls untouched; switching back deleting nothing and a call
--      on the line stored again; a line added as not counted removing the calls stored while it
--      was unknown; refusals (an agent, the Ingest user, the application calling the removal, a
--      counted or missing line); the lines already off removed per connection, a rerun zeros; the
--      audit exception narrow; the line locks the write and the removal take
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 55 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008f;
create temp table verify_0008f (ord int, check_name text, result text, detail text);

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text;
  v_t       text;
  v_bad     text;
  v_n       integer;
  v_detail  text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded
  insert into verify_0008f values (1, 'A1 addition 0008f recorded',
    case when exists (select 1 from cma.schema_migration where version = '0008f') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the trigger: after insert, or an update of is_counted, for each row, enabled, on the lines;
  --     its function SECURITY DEFINER, owned by cma_owner, search path pinned, executable by nobody
  select format('tgtype %s, columns %s, enabled %s, secdef %s, owner %s, config %s, app %s, readers %s, public %s',
                t.tgtype, t.tgattr::text, t.tgenabled, p.prosecdef, pg_get_userbyid(p.proowner), array_to_string(p.proconfig, ','),
                has_function_privilege('cma_app', p.oid, 'execute'), has_function_privilege('cma_readonly', p.oid, 'execute'),
                exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
  into v_detail
  from pg_trigger t join pg_proc p on p.oid = t.tgfoid
  where t.tgrelid = 'cma.telephony_number'::regclass and t.tgname = 'remove_uncounted_calls';
  insert into verify_0008f values (2, 'A2 the lines'' trigger and its owner''s function',
    case when v_detail = format('tgtype 21, columns %s, enabled O, secdef t, owner cma_owner, config search_path=pg_catalog, cma, pg_temp, app f, readers f, public f',
                                (select attnum from pg_attribute where attrelid = 'cma.telephony_number'::regclass and attname = 'is_counted'))
              and (select tgfoid from pg_trigger where tgrelid = 'cma.telephony_number'::regclass and tgname = 'remove_uncounted_calls')
                  = 'cma.remove_calls_of_uncounted_line()'::regprocedure
              and not v_provoke
         then 'PASS' else 'FAIL' end, coalesce(v_detail, 'no trigger'));

  -- A3. the removals are the owner's: caller's rights, executable by neither the application nor readers
  v_bad := '';
  foreach v_fn in array array['cma.remove_uncounted_line_calls(uuid,uuid,text)', 'cma.remove_all_uncounted_line_calls()'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif (select prosecdef or pg_get_userbyid(proowner) <> 'cma_owner' from pg_proc where oid = to_regprocedure(v_fn))
          or has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      v_bad := v_bad || v_fn || ' is not the owner''s only; ';
    end if;
  end loop;
  insert into verify_0008f values (3, 'A3 the removals are the owner''s only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the application still never deletes from the telephony tables; the call write and the line
  --     setting stay the application's, in the caller's rights
  v_bad := '';
  foreach v_t in array array['telephony_call', 'telephony_call_tag', 'call_link', 'telephony_number'] loop
    if has_table_privilege('cma_app', 'cma.' || v_t, 'delete') then
      v_bad := v_bad || 'cma_app may delete from cma.' || v_t || '; ';
    end if;
  end loop;
  foreach v_fn in array array['cma.ingest_upsert_telephony_calls(uuid,jsonb)', 'cma.set_telephony_number(uuid,text,text,boolean)'] loop
    if not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
       or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not the application''s only, in the caller''s rights; ';
    end if;
  end loop;
  insert into verify_0008f values (4, 'A4 the application never deletes; call write and line setting unchanged in rights',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. no stored call on a line that does not count, in any tenant (the run of 54 removed them)
  select count(*) into v_n
  from cma.telephony_call t
  join cma.telephony_number n on n.tenant_id = t.tenant_id and n.connection_id = t.connection_id and n.number_ref = t.number_ref
  where not n.is_counted;
  insert into verify_0008f values (5, 'A5 no stored call on a line that does not count',
    case when v_n = 0 and not v_provoke then 'PASS' else 'FAIL' end, format('%s call(s) on lines that do not count', v_n));
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
  v_tel      uuid;
  v_tel2     uuid;
  v_telx     uuid;
  v_crm      uuid;
  v_link     uuid;
  v_ids      uuid[];
  v_key      bigint;
  v_shared   boolean;
  v_excl     boolean;
  v_txt      text;
  v_detail   text;
  v_before   text;
  v_ok       boolean;
  v_n        integer;
  v_s        timestamptz := timestamptz '2026-10-12 10:00:00+00';
  v_h1       text := repeat('a1', 32);
  v_h3       text := repeat('a3', 32);
  v_h4       text := repeat('a4', 32);
  v_h5       text := repeat('a5', 32);
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008f-one', 'Verify 0008f one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008f-two', 'Verify 0008f two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin, 'admin'), (v_t1, v_agent, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';

    -- tenant one: two telephony connections and a CRM connection; lines one and three count, two does
    -- not; the second connection has its own line one. Tenant two: the same line one, counted
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id into v_tel from cma.upsert_connection('verifytel', 'Verify phones', 'company-1', null, null) c;
    select c.connection_id into v_tel2 from cma.upsert_connection('verifytelb', 'Verify phones two', 'company-2', null, null) c;
    select c.connection_id into v_crm from cma.upsert_connection('verifycrm', 'Verify customer records', 'portal-1', null, null) c;
    perform cma.set_telephony_number(v_tel, 'line-1', null, true);
    perform cma.set_telephony_number(v_tel, 'line-2', null, false);
    perform cma.set_telephony_number(v_tel, 'line-3', null, true);
    perform cma.set_telephony_number(v_tel2, 'line-1', null, true);
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    select c.connection_id into v_telx from cma.upsert_connection('verifytel', 'Verify phones', 'company-1', null, null) c;
    perform cma.set_telephony_number(v_telx, 'line-1', null, true);
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_telephony_calls(v_telx, jsonb_build_array(jsonb_build_object(
      'sourceId', 'x-1', 'direction', 'outbound', 'startedAt', v_s, 'numberRef', 'line-1', 'versionAt', v_s, 'tags', jsonb_build_array('tag-a'))));
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_key := hashtextextended(v_t1::text || '/telephony_line/' || v_tel::text || '/line-1', 0);

    -- B1. a counted line: the call is stored; its tags opened, closed and reopened; a second call
    select string_agg(u.source_id || ':' || u.outcome, ',' order by u.n) into v_txt
    from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
           jsonb_build_object('sourceId', 'c-1', 'direction', 'outbound', 'startedAt', v_s, 'numberRef', 'line-1',
                              'counterpartHash', v_h1, 'versionAt', v_s + interval '1 minute', 'tags', jsonb_build_array('tag-a')),
           jsonb_build_object('sourceId', 'c-5', 'direction', 'outbound', 'startedAt', v_s, 'numberRef', 'line-1',
                              'counterpartHash', v_h5, 'versionAt', v_s + interval '1 minute', 'tags', jsonb_build_array('tag-a'))))
         with ordinality u(source_id, outcome, n);
    v_shared := exists (select 1 from pg_locks l where l.locktype = 'advisory' and l.pid = pg_backend_pid() and l.mode = 'ShareLock'
                        and l.objsubid = 1 and ((l.classid::bigint << 32) | l.objid::bigint) = v_key);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(jsonb_build_object(
      'sourceId', 'c-1', 'direction', 'outbound', 'startedAt', v_s, 'numberRef', 'line-1', 'counterpartHash', v_h1,
      'versionAt', v_s + interval '2 minutes', 'tags', '[]'::jsonb)));
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(jsonb_build_object(
      'sourceId', 'c-1', 'direction', 'outbound', 'startedAt', v_s, 'numberRef', 'line-1', 'counterpartHash', v_h1,
      'versionAt', v_s + interval '3 minutes', 'tags', jsonb_build_array('tag-a'))));
    v_ok := v_txt = 'c-1:inserted,c-5:inserted'
            and (select count(*) from cma.telephony_call where connection_id = v_tel and number_ref = 'line-1') = 2
            and (select count(*) from cma.telephony_call_tag where connection_id = v_tel and call_source_id = 'c-1') = 2;
    v_rows := v_rows || array['11', 'B1 a counted line: the call is stored',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no outcome')];

    -- B2. a line that does not count: skipped with its outcome, also a deletion and a padded ref;
    --     nothing of the call written, its new tag not added to the catalog; the batch's other call stored
    select string_agg(u.source_id || ':' || u.outcome, ',' order by u.n) into v_txt
    from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
           jsonb_build_object('sourceId', 'c-2', 'direction', 'inbound', 'startedAt', v_s, 'numberRef', 'line-2',
                              'counterpartHash', v_h4, 'versionAt', v_s + interval '1 minute', 'tags', jsonb_build_array('tag-new')),
           jsonb_build_object('sourceId', 'c-3', 'direction', 'outbound', 'startedAt', v_s, 'numberRef', 'line-3',
                              'counterpartHash', v_h3, 'versionAt', v_s + interval '1 minute', 'tags', jsonb_build_array('tag-a')),
           jsonb_build_object('sourceId', 'c-2', 'numberRef', ' line-2 ', 'deletedAt', v_s + interval '5 minutes')))
         with ordinality u(source_id, outcome, n);
    v_ok := v_txt = 'c-2:skipped_uncounted_line,c-3:inserted,c-2:skipped_uncounted_line'
            and not exists (select 1 from cma.telephony_call where connection_id = v_tel and source_id = 'c-2')
            and not exists (select 1 from cma.telephony_call_tag where connection_id = v_tel and call_source_id = 'c-2')
            and not exists (select 1 from cma.telephony_tag where connection_id = v_tel and tag_ref = 'tag-new')
            and exists (select 1 from cma.telephony_call where connection_id = v_tel and source_id = 'c-3');
    v_rows := v_rows || array['12', 'B2 a line that does not count: skipped with its outcome, nothing written',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no outcome')];

    -- B3. a line not in the catalog: the call is stored and the line is not added
    select string_agg(u.source_id || ':' || u.outcome, ',' order by u.n) into v_txt
    from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
           jsonb_build_object('sourceId', 'c-4', 'direction', 'outbound', 'startedAt', v_s, 'numberRef', 'line-9',
                              'counterpartHash', v_h4, 'versionAt', v_s + interval '1 minute', 'tags', jsonb_build_array('tag-a'))))
         with ordinality u(source_id, outcome, n);
    v_ok := v_txt = 'c-4:inserted'
            and exists (select 1 from cma.telephony_call where connection_id = v_tel and source_id = 'c-4' and number_ref = 'line-9')
            and not exists (select 1 from cma.telephony_number where connection_id = v_tel and number_ref = 'line-9');
    v_rows := v_rows || array['13', 'B3 a line not in the catalog: the call is stored',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no outcome')];

    -- the second connection's call on its own line one; CRM calls for c-1, c-3 and c-5; links made,
    -- then c-1's link retired, so line one holds a current and a retired link
    perform cma.ingest_upsert_telephony_calls(v_tel2, jsonb_build_array(jsonb_build_object(
      'sourceId', 'd-1', 'direction', 'outbound', 'startedAt', v_s, 'numberRef', 'line-1', 'versionAt', v_s, 'tags', jsonb_build_array('tag-a'))));
    perform cma.ingest_upsert_calls(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', x.id, 'direction', 'outbound', 'counterpartHash', x.h, 'occurredAt', x.at,
                                          'updatedAt', v_s + interval '10 minutes'))
      from (values ('K1', v_h1, v_s + interval '30 seconds'), ('K3', v_h3, v_s + interval '10 seconds'),
                   ('K5', v_h5, v_s + interval '20 seconds')) as x(id, h, at)));
    v_n := cma.link_calls(v_s - interval '1 hour');
    perform set_config('app.user_id', v_admin::text, true);
    select l.id into v_link from cma.call_link l join cma.telephony_call t on t.id = l.telephony_call_id
    where t.connection_id = v_tel and t.source_id = 'c-1';
    perform cma.unlink_call(v_link);
    select array_agg(t.id) into v_ids from cma.telephony_call t where t.connection_id = v_tel and t.number_ref = 'line-1';
    v_before := format('line one: %s calls, %s taggings, %s links; %s links made',
      (select count(*) from cma.telephony_call where id = any (v_ids)),
      (select count(*) from cma.telephony_call_tag where connection_id = v_tel and call_source_id in ('c-1', 'c-5')),
      (select count(*) from cma.call_link where telephony_call_id = any (v_ids)), v_n);

    -- B4. switching line one off removes its calls, taggings and links (the retired one too); the
    --     CRM calls stay, as do the connection's other lines and the tag catalog
    perform cma.set_telephony_number(v_tel, 'line-1', null, false);
    v_excl := exists (select 1 from pg_locks l where l.locktype = 'advisory' and l.pid = pg_backend_pid() and l.mode = 'ExclusiveLock'
                      and l.objsubid = 1 and ((l.classid::bigint << 32) | l.objid::bigint) = v_key);
    v_ok := v_before = 'line one: 2 calls, 3 taggings, 2 links; 3 links made'
            and not exists (select 1 from cma.telephony_call where connection_id = v_tel and number_ref = 'line-1')
            and not exists (select 1 from cma.telephony_call_tag where connection_id = v_tel and call_source_id in ('c-1', 'c-5'))
            and not exists (select 1 from cma.call_link where telephony_call_id = any (v_ids))
            and (select count(*) from cma.crm_call where connection_id = v_crm and source_id in ('K1', 'K3', 'K5') and source_deleted_at is null) = 3
            and (select count(*) from cma.telephony_call where connection_id = v_tel and source_id in ('c-3', 'c-4')) = 2
            and exists (select 1 from cma.telephony_call_tag where connection_id = v_tel and call_source_id = 'c-3')
            and exists (select 1 from cma.call_link l join cma.telephony_call t on t.id = l.telephony_call_id
                        where t.connection_id = v_tel and t.source_id = 'c-3' and l.unlinked_at is null)
            and exists (select 1 from cma.telephony_tag where connection_id = v_tel and tag_ref = 'tag-a')
            and (select is_counted from cma.telephony_number where connection_id = v_tel and number_ref = 'line-1') = false;
    v_rows := v_rows || array['14', 'B4 switching a line off removes its calls, taggings and links; CRM calls stay',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, v_before];

    -- B5. the audit rows of those deletes: the ids and the reason only, no call data; the person named
    select string_agg(x.table_name || ':' || x.n, ' ' order by x.table_name) into v_detail
    from (select a.table_name, count(*) as n from cma.audit_log a
          where a.tenant_id = v_t1 and a.action = 'delete' and a.table_name in ('telephony_call', 'telephony_call_tag', 'call_link')
          group by a.table_name) x;
    select count(*) into v_n from cma.audit_log a
    where a.tenant_id = v_t1 and a.action = 'delete' and a.table_name in ('telephony_call', 'telephony_call_tag', 'call_link')
      and (a.new_row is not null or a.actor_user_id is distinct from v_admin or a.old_row ->> 'reason' is distinct from 'uncounted_line'
           or exists (select 1 from jsonb_object_keys(a.old_row) k
                      where k not in ('id', 'tenant_id', 'connection_id', 'source_id', 'call_source_id', 'tag_ref',
                                      'telephony_call_id', 'crm_call_id', 'reason'))
           or a.old_row::text like '%' || v_h1 || '%' or a.old_row::text like '%' || v_h5 || '%'
           or a.old_row::text like '%line-1%' or a.old_row::text like '%2026-10-12%'
           or (a.table_name = 'telephony_call' and (a.row_id is null or not (a.row_id::uuid = any (v_ids)))));
    v_rows := v_rows || array['15', 'B5 the audit of those deletes holds ids only, no call data',
      case when v_detail = 'call_link:2 telephony_call:2 telephony_call_tag:3' and v_n = 0 and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_detail, 'no delete rows') || format('; %s row(s) with more than ids', v_n)];

    -- B6. another connection's and another tenant's calls on a line of the same name are untouched
    v_ok := exists (select 1 from cma.telephony_call where connection_id = v_tel2 and source_id = 'd-1' and number_ref = 'line-1')
            and exists (select 1 from cma.telephony_call_tag where connection_id = v_tel2 and call_source_id = 'd-1');
    perform set_config('role', 'cma_owner', true);
    v_ok := v_ok and exists (select 1 from cma.telephony_call where tenant_id = v_t2 and connection_id = v_telx and source_id = 'x-1')
            and exists (select 1 from cma.telephony_call_tag where tenant_id = v_t2 and connection_id = v_telx and call_source_id = 'x-1')
            and not exists (select 1 from cma.audit_log where tenant_id = v_t2 and action = 'delete');
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['16', 'B6 another connection''s and another tenant''s calls untouched',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, ''];

    -- B7. switching line one back on deletes nothing; a call on it is stored again
    v_before := format('%s/%s/%s/%s', (select count(*) from cma.telephony_call), (select count(*) from cma.telephony_call_tag),
                       (select count(*) from cma.call_link), (select count(*) from cma.audit_log where action = 'delete'));
    perform cma.set_telephony_number(v_tel, 'line-1', null, true);
    v_detail := format('%s/%s/%s/%s', (select count(*) from cma.telephony_call), (select count(*) from cma.telephony_call_tag),
                       (select count(*) from cma.call_link), (select count(*) from cma.audit_log where action = 'delete'));
    perform set_config('app.user_id', v_ing1::text, true);
    select string_agg(u.source_id || ':' || u.outcome, ',' order by u.n) into v_txt
    from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(jsonb_build_object(
           'sourceId', 'c-1', 'direction', 'outbound', 'startedAt', v_s, 'numberRef', 'line-1', 'counterpartHash', v_h1,
           'versionAt', v_s + interval '3 minutes', 'tags', jsonb_build_array('tag-a')))) with ordinality u(source_id, outcome, n);
    v_ok := v_before = v_detail and v_txt = 'c-1:inserted'
            and exists (select 1 from cma.telephony_call where connection_id = v_tel and source_id = 'c-1' and number_ref = 'line-1');
    v_rows := v_rows || array['17', 'B7 switching a line back on deletes nothing; a call on it is stored again',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end,
      format('calls/taggings/links/deletes %s before, %s after; %s', v_before, v_detail, coalesce(v_txt, 'no outcome'))];

    -- B8. a line added by hand as not counted removes the calls stored while it was unknown; its next
    --     call is skipped
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_telephony_number(v_tel, 'line-9', null, false);
    perform set_config('app.user_id', v_ing1::text, true);
    select string_agg(u.source_id || ':' || u.outcome, ',' order by u.n) into v_txt
    from cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(jsonb_build_object(
           'sourceId', 'c-6', 'direction', 'inbound', 'startedAt', v_s, 'numberRef', 'line-9', 'versionAt', v_s))) with ordinality u(source_id, outcome, n);
    v_ok := not exists (select 1 from cma.telephony_call where connection_id = v_tel and number_ref = 'line-9')
            and not exists (select 1 from cma.telephony_call_tag where connection_id = v_tel and call_source_id = 'c-4')
            and v_txt = 'c-6:skipped_uncounted_line';
    v_rows := v_rows || array['18', 'B8 a line added as not counted removes the calls stored while it was unknown',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no outcome')];

    -- B9. refusals: an agent and the Ingest user may not switch a line off (CMA06); the application
    --     may not call the removals (42501); the removal refuses a counted (CMA03) and a missing line
    --     (CMA02); line three keeps its call, tagging and link
    v_n := 0;
    v_detail := '';
    perform set_config('app.user_id', v_agent::text, true);
    begin perform cma.set_telephony_number(v_tel, 'line-3', null, false); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    perform set_config('app.user_id', v_ing1::text, true);
    begin perform cma.set_telephony_number(v_tel, 'line-3', null, false); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    perform set_config('app.user_id', v_admin::text, true);
    begin perform cma.remove_uncounted_line_calls(v_t1, v_tel, 'line-3'); exception when insufficient_privilege then v_n := v_n + 1; end;
    begin perform cma.remove_all_uncounted_line_calls(); exception when insufficient_privilege then v_n := v_n + 1; end;
    perform set_config('role', 'cma_owner', true);
    begin perform cma.remove_uncounted_line_calls(v_t1, v_tel, 'line-3'); exception when sqlstate 'CMA03' then v_n := v_n + 1; end;
    begin perform cma.remove_uncounted_line_calls(v_t1, v_tel, 'line-404'); exception when sqlstate 'CMA02' then v_n := v_n + 1; end;
    v_ok := v_n = 6
            and (select is_counted from cma.telephony_number where tenant_id = v_t1 and connection_id = v_tel and number_ref = 'line-3')
            and exists (select 1 from cma.telephony_call where tenant_id = v_t1 and connection_id = v_tel and source_id = 'c-3')
            and exists (select 1 from cma.telephony_call_tag where tenant_id = v_t1 and connection_id = v_tel and call_source_id = 'c-3')
            and exists (select 1 from cma.call_link l join cma.telephony_call t on t.id = l.telephony_call_id
                        where t.tenant_id = v_t1 and t.connection_id = v_tel and t.source_id = 'c-3' and l.unlinked_at is null);
    v_rows := v_rows || array['19', 'B9 refusals: agent, Ingest user, the application calling the removals, a counted or missing line',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, format('%s of 6 refusals', v_n)];

    -- B10. lines already off before 0008f (as the run of 54 finds them): line three marked not counted
    --      with the trigger off keeps its call; the removal of every such line takes it, per connection,
    --      and a rerun answers zeros (still owner)
    alter table cma.telephony_number disable trigger remove_uncounted_calls;
    update cma.telephony_number set is_counted = false where tenant_id = v_t1 and connection_id = v_tel and number_ref = 'line-3';
    alter table cma.telephony_number enable trigger remove_uncounted_calls;
    v_ok := exists (select 1 from cma.telephony_call where tenant_id = v_t1 and connection_id = v_tel and source_id = 'c-3');
    select string_agg(format('%s/%s/%s/%s/%s/%s', r.tenant, r.connection, r.lines_not_counted, r.calls_removed, r.taggings_removed,
                             r.links_removed), ' ' order by r.tenant, r.connection) into v_detail
    from cma.remove_all_uncounted_line_calls() r where r.connection_id in (v_tel, v_tel2, v_telx);
    select string_agg(format('%s/%s/%s/%s/%s/%s', r.tenant, r.connection, r.lines_not_counted, r.calls_removed, r.taggings_removed,
                             r.links_removed), ' ' order by r.tenant, r.connection) into v_txt
    from cma.remove_all_uncounted_line_calls() r where r.connection_id in (v_tel, v_tel2, v_telx);
    v_ok := v_ok and v_detail = 'verify-0008f-one/Verify phones/3/1/1/1 verify-0008f-one/Verify phones two/0/0/0/0 verify-0008f-two/Verify phones/0/0/0/0'
            and v_txt = 'verify-0008f-one/Verify phones/3/0/0/0 verify-0008f-one/Verify phones two/0/0/0/0 verify-0008f-two/Verify phones/0/0/0/0'
            and not exists (select 1 from cma.telephony_call where tenant_id = v_t1 and connection_id = v_tel and number_ref = 'line-3')
            and exists (select 1 from cma.crm_call where tenant_id = v_t1 and connection_id = v_crm and source_id = 'K3');
    v_rows := v_rows || array['20', 'B10 lines already off: their calls removed per connection, a rerun zeros',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_detail, 'no rows') || ' | rerun ' || coalesce(v_txt, 'no rows')];

    -- B11. the exception is narrow: an owner's delete outside the rule keeps its full image, the switch
    --      is off again after a removal, the line's own update and a call's insert keep theirs
    delete from cma.telephony_call_tag where tenant_id = v_t1 and connection_id = v_tel2 and call_source_id = 'd-1';
    v_ok := exists (select 1 from cma.audit_log a
                    where a.tenant_id = v_t1 and a.table_name = 'telephony_call_tag' and a.action = 'delete'
                      and a.old_row ->> 'call_source_id' = 'd-1' and a.old_row ? 'tagged_at' and not a.old_row ? 'reason')
            and coalesce(current_setting('cma.audit_keys_only', true), '') = ''
            and exists (select 1 from cma.audit_log a
                        where a.tenant_id = v_t1 and a.table_name = 'telephony_number' and a.action = 'update'
                          and a.old_row ->> 'number_ref' = 'line-1' and a.old_row ->> 'is_counted' = 'true'
                          and a.new_row ->> 'is_counted' = 'false')
            and exists (select 1 from cma.audit_log a
                        where a.tenant_id = v_t1 and a.table_name = 'telephony_call' and a.action = 'insert'
                          and a.new_row ->> 'source_id' = 'c-3' and a.new_row ->> 'counterpart_hash' = v_h3);
    v_rows := v_rows || array['21', 'B11 the audit exception is narrow',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, ''];

    -- B12. the call write held its batch's line shared, the removal took it exclusively (pg_locks)
    v_rows := v_rows || array['22', 'B12 the line lock: shared for the call write, exclusive for the removal',
      case when v_shared and v_excl and not v_provoke then 'PASS' else 'FAIL' end,
      format('shared %s, exclusive %s', v_shared, v_excl)];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008f (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008f values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008f
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008f where result = 'PASS') = 17
                       and not exists (select 1 from verify_0008f where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008f where result = 'PASS'),
                                        (select count(*) from verify_0008f where result <> 'PASS'))) x
order by ord;
reset role;
