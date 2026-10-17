-- =============================================================================================
-- 77_verify_audit_hardening.sql: verifies addition 0008q, the IT audit's database hardening
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on a throwaway tenant inside a subtransaction that is always rolled
-- back. Universal otherwise: nothing of the seed is used; adapters, lines, users and calls are invented
-- data values, and no call carries a hash or a number. Every check writes one row, PASS or FAIL, and the
-- last result lists them with the verdict, because Cloud SQL Studio shows no notices.
-- Run as your own IAM login in dev, after 76_audit_hardening.sql; then 55, 61, 63, 65 and 41 again.
--   A  structure and privileges: the addition row after 0008p; the uncounted-line trigger unchanged in
--      event, owner, search path and rights and its function asserting tenant.configure; no DELETE grant
--      to the application on a master-data table outside the set-replace tables still to migrate
--      (CMA-060 part 3); no function of cma executable by PUBLIC but the helpers every role's defaults
--      and triggers call; every SECURITY DEFINER function's search path ending in pg_temp; the two
--      indexes of ingest_event; the three report cores bounding their period with coalesce
--   B  behaviour on a throwaway tenant: a direct update of is_counted by the Ingest login (no acting
--      user) is refused (CMA01) and the calls stay; an agent's is refused (CMA06); the admin through
--      set_telephony_number removes the calls, audited with the person; the owner without an acting user
--      (a one-off) may; an ingest event's audit images carry no payload while the event row keeps it;
--      telephony_raw drops a string holding an @ and keeps the rest; calls_of and inbound_calls_of answer
--      the same rows with and without bounds, and their bounds select the period
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 77 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008q;
create temp table verify_0008q (ord int, check_name text, result text, detail text);

-- One answered telephony call as the ingest write takes it, on the line given, without a user, a hash or tags
create or replace function pg_temp.v0008q_call(p_src text, p_dir text, p_start timestamptz, p_line text)
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'sourceId', p_src, 'direction', p_dir, 'startedAt', p_start,
    'answeredAt', p_start + interval '5 seconds', 'endedAt', p_start + interval '65 seconds',
    'durationSeconds', 65, 'numberRef', p_line, 'versionAt', p_start + interval '65 seconds')
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_detail  text;
  v_bad     text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008p
  insert into verify_0008q values (1, 'A1 addition 0008q recorded',
    case when exists (select 1 from cma.schema_migration where version = '0008q')
              and exists (select 1 from cma.schema_migration where version = '0008p') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the trigger and its owner's function unchanged in event, owner, search path and rights (55 A2), and
  --     the function asserting tenant.configure
  select format('tgtype %s, enabled %s, secdef %s, owner %s, config %s, app %s, readers %s, public %s',
                t.tgtype, t.tgenabled, p.prosecdef, pg_get_userbyid(p.proowner), array_to_string(p.proconfig, ','),
                has_function_privilege('cma_app', p.oid, 'execute'), has_function_privilege('cma_readonly', p.oid, 'execute'),
                exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
    into v_detail
  from pg_trigger t join pg_proc p on p.oid = t.tgfoid
  where t.tgrelid = 'cma.telephony_number'::regclass and t.tgname = 'remove_uncounted_calls';
  insert into verify_0008q values (2, 'A2 the uncounted-line trigger unchanged in rights, its function asserting tenant.configure',
    case when v_detail = 'tgtype 21, enabled O, secdef t, owner cma_owner, config search_path=pg_catalog, cma, pg_temp, app f, readers f, public f'
              and (select prosrc from pg_proc where oid = 'cma.remove_calls_of_uncounted_line()'::regprocedure) ~ 'assert_permission\(''tenant\.configure''\)'
              and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_detail, 'no trigger'));

  -- A3. no DELETE grant to the application on a master-data table, except the set-replace tables whose
  --     functions still delete and reinsert (CMA-060 part 2 moves them one by one; they are listed in the
  --     detail so the check measures the progress)
  select string_agg(t, ', ' order by t) into v_bad
  from unnest(array[
    'app_user', 'organisation', 'team', 'skill', 'app_role', 'role_permission', 'channel', 'work_status', 'absence_type', 'app_link',
    'roster_week', 'roster_publication', 'roster_entry', 'telephony_number', 'telephony_tag', 'telephony_missed_reason', 'market',
    'integration_connection', 'connection_pipeline', 'connection_stage', 'connection_form', 'connection_form_field',
    'connection_call_outcome', 'connection_task_status', 'connection_task_type', 'connection_inbox', 'connection_inbox_channel',
    'connection_email_rule', 'form_category', 'writeback_field', 'message_rule', 'invitation', 'commerce_store']) t
  where to_regclass('cma.' || t) is not null and has_table_privilege('cma_app', 'cma.' || t, 'delete');
  select string_agg(t, ', ' order by t) into v_detail
  from unnest(array['app_user_external_id', 'user_role', 'skill_level', 'coverage_target', 'connection_field', 'business_hours',
                    'market_alias', 'business_holiday', 'tenant_setting', 'crm_contact_ref', 'commerce_order_line']) t
  where to_regclass('cma.' || t) is not null and has_table_privilege('cma_app', 'cma.' || t, 'delete');
  insert into verify_0008q values (3, 'A3 no DELETE grant to the application on a master-data table (CMA-060)',
    case when v_bad is null and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce('the application may delete from: ' || v_bad || '; ', '') || coalesce('set-replace deletes still to migrate: ' || v_detail, 'no set-replace delete left'));

  -- A4. no function of cma executable by PUBLIC but the helpers every role's defaults, checks and triggers call
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
  from pg_proc p
  where p.pronamespace = 'cma'::regnamespace
    and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
    and p.proname not in ('assert_permission', 'assert_time_kept', 'audit_row', 'business_date', 'business_day_time', 'current_actor_label',
                          'current_tenant_id', 'current_user_id', 'has_permission', 'is_timezone', 'set_updated_at', 'time_is_kept', 'user_timezone');
  insert into verify_0008q values (4, 'A4 no function executable by PUBLIC but the helpers',
    case when v_bad is null and not v_provoke then 'PASS' else 'FAIL' end, coalesce('executable by PUBLIC: ' || v_bad, ''));

  -- A5. every SECURITY DEFINER function of cma and cma_read pins its search path with pg_temp last
  select string_agg(n.nspname || '.' || p.proname, ', ' order by 1) into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('cma', 'cma_read') and p.prosecdef
    and not exists (select 1 from unnest(p.proconfig) c where c ~ '^search_path=.*pg_temp$');
  insert into verify_0008q values (5, 'A5 every SECURITY DEFINER function pins its search path with pg_temp last',
    case when v_bad is null and not v_provoke then 'PASS' else 'FAIL' end, coalesce('without pg_temp last: ' || v_bad, ''));

  -- A6. the two indexes of ingest_event
  v_bad := '';
  if not exists (select 1 from pg_indexes where schemaname = 'cma' and tablename = 'ingest_event' and indexname = 'ingest_event_recorded_idx'
                 and indexdef like '%(tenant_id, connection_id, recorded_at DESC)%') then v_bad := v_bad || 'ingest_event_recorded_idx missing; '; end if;
  if not exists (select 1 from pg_indexes where schemaname = 'cma' and tablename = 'ingest_event' and indexname = 'ingest_event_needs_review_idx'
                 and indexdef like '%WHERE (status = ''needs_review''%') then v_bad := v_bad || 'ingest_event_needs_review_idx missing; '; end if;
  insert into verify_0008q values (6, 'A6 the two indexes of ingest_event for the sources read',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A7. the three report cores bound their period with coalesce, not with (p is null or ...)
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
  from pg_proc p
  where p.pronamespace = 'cma'::regnamespace and p.proname in ('calls_of', 'inbound_calls_of', 'lead_deals_of')
    and (p.prosrc ~ 'p_from is null or' or p.prosrc !~ 'coalesce\(p_from, ''-infinity''::timestamptz\)' or p.prosrc !~ 'coalesce\(p_to, ''infinity''::timestamptz\)');
  insert into verify_0008q values (7, 'A7 the report cores bound their period on the index (coalesce bounds)',
    case when v_bad is null and not v_provoke then 'PASS' else 'FAIL' end, coalesce('still (p is null or ...): ' || v_bad, ''));
end
$$;

-- B. Behaviour on a throwaway tenant (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_admin uuid; v_agent uuid; v_ing1 uuid; v_tel uuid; v_crm uuid;
  v_n integer; v_calls integer; v_txt text; v_detail text;
  v_s timestamptz := timestamptz '2026-10-12 10:00:00+00';
  v_event uuid;
  j jsonb;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008q-one', 'Verify 0008q one', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id from (values (v_t1, v_admin, 'admin'), (v_t1, v_agent, 'agent')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    select c.connection_id into v_tel from cma.upsert_connection('verifytel', 'Verify phones', 'company-1', null, null) c;
    perform cma.set_connection_kind(v_tel, 'telephony');
    perform cma.set_telephony_number(v_tel, 'line-1', 'NL', true);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tag-a", "name": "Verify tag"}]'::jsonb);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      pg_temp.v0008q_call('q-1', 'outbound', v_s, 'line-1') || jsonb_build_object('tags', jsonb_build_array('tag-a')),
      pg_temp.v0008q_call('q-2', 'inbound', v_s + interval '5 minutes', 'line-1'),
      pg_temp.v0008q_call('q-3', 'inbound', v_s + interval '2 days', 'line-1')));

    -- B1. the Ingest login's path: cma_app rights, the tenant set, no acting user, an actor label as the service
    --     sends it: a direct update of is_counted is refused (CMA01) and the calls, the tagging and the line stay
    perform set_config('app.user_id', '', true);
    perform set_config('app.actor_label', 'ingest-api:verify', true);
    v_n := 0;
    begin
      update cma.telephony_number set is_counted = false where connection_id = v_tel and number_ref = 'line-1';
    exception when sqlstate 'CMA01' then v_n := v_n + 1;
    end;
    select count(*) into v_calls from cma.telephony_call where tenant_id = v_t1 and connection_id = v_tel;
    v_rows := v_rows || array['11', 'B1 a direct update of is_counted without an acting user is refused (CMA01); the calls stay',
      case when v_n = 1 and v_calls = 3
                and (select is_counted from cma.telephony_number where tenant_id = v_t1 and connection_id = v_tel and number_ref = 'line-1')
                and (select count(*) from cma.telephony_call_tag where tenant_id = v_t1 and connection_id = v_tel) = 1
                and not v_provoke then 'PASS' else 'FAIL' end, format('%s refusal, %s calls', v_n, v_calls)];

    -- B2. an agent (an acting person without tenant.configure): CMA06, nothing removed
    perform set_config('app.user_id', v_agent::text, true);
    perform set_config('app.actor_label', '', true);
    v_n := 0;
    begin
      update cma.telephony_number set is_counted = false where connection_id = v_tel and number_ref = 'line-1';
    exception when sqlstate 'CMA06' then v_n := v_n + 1;
    end;
    select count(*) into v_calls from cma.telephony_call where tenant_id = v_t1 and connection_id = v_tel;
    v_rows := v_rows || array['12', 'B2 an agent''s direct update is refused (CMA06); the calls stay',
      case when v_n = 1 and v_calls = 3 and not v_provoke then 'PASS' else 'FAIL' end, format('%s refusal, %s calls', v_n, v_calls)];

    -- B7 (before the calls go). calls_of and inbound_calls_of answer the same rows with null bounds and with
    --     infinite ones, and a bounded period selects its calls: the coalesce bounds keep 0008j's meaning
    perform set_config('app.user_id', v_admin::text, true);
    select format('all %s/%s, infinite %s/%s, day %s/%s, inbound all %s, inbound day %s',
                  (select count(*) from cma.calls_of(v_t1, null, null, null, null)),
                  (select count(*) from cma.calls_of(v_t1, null, null, 'NL', null)),
                  (select count(*) from cma.calls_of(v_t1, '-infinity'::timestamptz, 'infinity'::timestamptz, null, null)),
                  (select count(*) from cma.calls_of(v_t1, '-infinity'::timestamptz, 'infinity'::timestamptz, 'NL', v_tel::text || ':line-1')),
                  (select count(*) from cma.calls_of(v_t1, v_s, v_s + interval '1 day', null, null)),
                  (select count(*) from cma.calls_of(v_t1, v_s + interval '1 day', null, null, null)),
                  (select count(*) from cma.inbound_calls_of(v_t1, null, null)),
                  (select count(*) from cma.inbound_calls_of(v_t1, v_s, v_s + interval '1 day')))
      into v_txt;
    v_rows := v_rows || array['17', 'B7 the report cores answer the same rows with and without bounds, a period selects its calls',
      case when v_txt = 'all 3/3, infinite 3/3, day 2/1, inbound all 2, inbound day 1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. the admin through the screen's function: the rule of 0008f unchanged, the calls removed, the audit
    --     of the deletes naming the person
    perform cma.set_telephony_number(v_tel, 'line-1', 'NL', false);
    select count(*) into v_calls from cma.telephony_call where tenant_id = v_t1 and connection_id = v_tel;
    v_rows := v_rows || array['13', 'B3 the admin switching the line off through set_telephony_number removes the calls, audited with the person',
      case when v_calls = 0
                and (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'telephony_call' and a.action = 'delete' and a.actor_user_id = v_admin) = 3
                and not v_provoke then 'PASS' else 'FAIL' end, format('%s calls left', v_calls)];

    -- B4. the owner without an acting user (a migration or one-off under a personal login): allowed
    perform cma.set_telephony_number(v_tel, 'line-2', 'NL', true);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(pg_temp.v0008q_call('q-4', 'outbound', v_s, 'line-2')));
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.user_id', '', true);
    update cma.telephony_number set is_counted = false where tenant_id = v_t1 and connection_id = v_tel and number_ref = 'line-2';
    select count(*) into v_calls from cma.telephony_call where tenant_id = v_t1 and connection_id = v_tel and number_ref = 'line-2';
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['14', 'B4 the owner without an acting user (a one-off) may switch a line off',
      case when v_calls = 0 and not v_provoke then 'PASS' else 'FAIL' end, format('%s calls left on line-2', v_calls)];

    -- B5. an ingest event's audit images carry no payload, while the event row keeps it: one event recorded,
    --     claimed and finished as the service does it (the connection made by the admin, the event by the Ingest user)
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id into v_crm from cma.upsert_connection('verifycrm', 'Verify CRM', 'portal-1', null, null) c;
    perform set_config('app.user_id', v_ing1::text, true);
    select r.event_id into v_event
    from cma.ingest_record_events(v_crm, jsonb_build_array(jsonb_build_object(
      'key', 'verify:0008q:1', 'sourceType', 'deal', 'objectType', 'deal', 'objectId', 'd-1', 'kind', 'created', 'occurredAt', v_s,
      'raw', jsonb_build_object('verify_marker_payload', 'must not reach the audit', 'subscriptionType', 'deal.creation')))) r;
    perform cma.ingest_claim_events(v_crm, array[v_event], 10);
    v_n := cma.ingest_finish_events(v_crm, array[v_event], 'processed', null);
    select format('%s audit rows, %s with raw, event raw kept %s',
                  count(*), count(*) filter (where (a.old_row ? 'raw') or (a.new_row ? 'raw')),
                  (select e.raw ? 'verify_marker_payload' from cma.ingest_event e where e.id = v_event))
      into v_txt
    from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'ingest_event' and a.row_id = v_event::text;
    v_rows := v_rows || array['15', 'B5 an ingest event''s audit images carry no payload; the event row keeps it',
      case when v_txt = '3 audit rows, 0 with raw, event raw kept t' and v_n = 1 and not v_provoke then 'PASS' else 'FAIL' end, v_txt || format(' (%s finished)', v_n)];

    -- B6. telephony_raw drops a string holding an @, keeps the rest
    j := cma.telephony_raw('{"status": "answered", "login": "someone@example.invalid", "cost": 1.5, "tags_count": 2, "mention": "ask x@y"}'::jsonb);
    v_rows := v_rows || array['16', 'B6 telephony_raw drops a string holding an @ and keeps the rest',
      case when j = '{"cost": 1.5, "status": "answered", "tags_count": 2}'::jsonb and not v_provoke then 'PASS' else 'FAIL' end, j::text];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008q (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008q values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008q
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008q where result = 'PASS') = 14
                       and not exists (select 1 from verify_0008q where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008q where result = 'PASS'),
                                        (select count(*) from verify_0008q where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008q_call(text, text, timestamptz, text);
reset role;
