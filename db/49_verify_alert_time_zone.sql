-- =============================================================================================
-- 49_verify_alert_time_zone.sql: verifies addition 0008c, alert times in the tenant's time zone
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on a throwaway tenant inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used. Every check writes one row, PASS
-- or FAIL, and the last result lists them with the verdict, because Cloud SQL Studio shows no
-- notices. Run as your own IAM login in dev, after 48_alert_time_zone.sql; then
-- 45_verify_assignment_alerts.sql and 47_verify_workday_window.sql again (unchanged).
--   A  structure and privileges: the migration row, the two functions and who may execute them,
--      their bodies format the time in the tenant's zone and no longer in the market's
--   B  the alert times: a tenant in Europe/Amsterdam, a GB market in Europe/London, a deal created
--      at 09:17 UTC on yesterday's date (a fixed time of day, so the deal stays within the alert
--      age limit whatever day the script runs; London and Amsterdam differ by an hour all year);
--      the created alert and the assignment alert show the Amsterdam time, not London's
-- Provoke: set provoke below to true; A1 and the two time rows of B must then read FAIL, and the
-- verdict says PROVOKED instead of PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make A1 and the time rows fail

-- Dev only (12 October 2026): a verifier that writes refuses a database without the dev seed
do $$
begin
  if not exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                 where u.email = 'agent.two@example.com' and u.status = 'active') then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 49 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008c;
create temp table verify_0008c (ord int, check_name text, result text, detail text);

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text;
  v_src     text;
  v_bad     text := '';
begin
  -- A1. the addition is recorded
  insert into verify_0008c values (1, 'A1 addition 0008c recorded',
    case when exists (select 1 from cma.schema_migration where version = '0008c') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. both functions exist, executable by the application only
  foreach v_fn in array array['cma.ingest_record_alerts(uuid,text,text[])', 'cma.ingest_assignment_alerts(uuid,text,text[])'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute') then
      v_bad := v_bad || v_fn || ' is not executable by cma_app only; ';
    end if;
  end loop;
  insert into verify_0008c values (2, 'A2 functions executable by cma_app only', case when v_bad = '' then 'PASS' else 'FAIL' end, v_bad);

  -- A3. both bodies format the time in the tenant's zone, neither in the market's
  v_bad := '';
  foreach v_fn in array array['cma.ingest_record_alerts(uuid,text,text[])', 'cma.ingest_assignment_alerts(uuid,text,text[])'] loop
    select p.prosrc into v_src from pg_proc p where p.oid = to_regprocedure(v_fn);
    if v_src like '%m.time_zone%' or v_src not like '%at time zone v_zone, ''HH24:MI''%' then
      v_bad := v_bad || v_fn || ' does not format the time in the tenant''s zone only; ';
    end if;
  end loop;
  insert into verify_0008c values (3, 'A3 time formatted in the tenant''s zone', case when v_bad = '' then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. The alert times (universal, a throwaway tenant, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_at       timestamptz := (date_trunc('day', now() at time zone 'UTC') - interval '1 day' + interval '9 hours 17 minutes') at time zone 'UTC';
  v_iso      text;
  v_ams      text;
  v_lon      text;
  v_want     text;
  v_t1       uuid;
  v_admin    uuid;
  v_a1       uuid;
  v_ing1     uuid;
  v_c1       uuid;
  v_n1       int;
  v_n2       int;
  v_created  text;
  v_assigned text;
  v_rows     text[] := '{}';
begin
  v_iso := to_char(v_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_ams := to_char(v_at at time zone 'Europe/Amsterdam', 'HH24:MI');
  v_lon := to_char(v_at at time zone 'Europe/London', 'HH24:MI');
  -- provoked, the rows expect the market's (London) time
  v_want := case when v_provoke then v_lon else v_ams end;
  begin
    v_t1 := cma.create_tenant('verify-0008c', 'Verify 0008c', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a1@example.invalid', 'a1') returning id into v_a1;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_admin, 'admin'), (v_a1, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.app_user_external_id (tenant_id, user_id, system, external_id) values (v_t1, v_a1, 'verify_owner', 'o1');
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    select c.connection_id into v_c1 from cma.upsert_connection('verify', 'Verify CRM', 'verify-portal-1', null, null) c;
    -- both rules accept records up to seven days old (the most the rule allows), so yesterday's deal counts
    perform cma.upsert_message_rule('New deal', 'deal', '{}'::text[], 'leads.accept', false, false, null, 'normal', 10080);
    perform cma.upsert_assignment_rule('Assigned deal', 'deal', '{}'::text[], 'urgent', 10080);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'pipelineId', 'p-sales', 'label', 'Sales', 'stages', jsonb_build_array(
        jsonb_build_object('stageId', 's-open', 'label', 'Open', 'order', 1, 'isClosed', false)))));
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'g1', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'GB',
                         'ownerRef', 'o1', 'createdAt', v_iso, 'updatedAt', v_iso)));
    v_n1 := cma.ingest_record_alerts(v_c1, 'deal', array['g1']);
    v_n2 := cma.ingest_assignment_alerts(v_c1, 'deal', array['g1']);
    select m.body into v_created from cma.message m where m.ref_id = 'g1' and not (m.target ? 'assignee');
    select m.body into v_assigned from cma.message m where m.ref_id = 'g1' and m.target ? 'assignee';

    -- B1. the instant reads differently in the market's and the tenant's zone, so B3 and B4 tell them apart
    v_rows := v_rows || array['4', 'B1 the deal''s instant differs between London and Amsterdam',
      case when v_lon <> v_ams then 'PASS' else 'FAIL' end, v_iso || ': London ' || v_lon || ', Amsterdam ' || v_ams];
    -- B2. one created alert and one assignment alert
    v_rows := v_rows || array['5', 'B2 one created alert and one assignment alert',
      case when v_n1 = 1 and v_n2 = 1 then 'PASS' else 'FAIL' end, format('%s created, %s assigned', v_n1, v_n2)];
    -- B3. the created alert shows the Amsterdam time
    v_rows := v_rows || array['6', 'B3 created alert in the tenant''s time',
      case when v_created = 'GB · Sales · created ' || v_want then 'PASS' else 'FAIL' end,
      coalesce(v_created, 'no alert') || case when v_provoke then ' (provoked: expected ' || v_want || ')' else '' end];
    -- B4. the assignment alert shows the Amsterdam time
    v_rows := v_rows || array['7', 'B4 assignment alert in the tenant''s time',
      case when v_assigned = 'GB · Sales · assigned ' || v_want then 'PASS' else 'FAIL' end,
      coalesce(v_assigned, 'no alert') || case when v_provoke then ' (provoked: expected ' || v_want || ')' else '' end];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['8', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008c (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008c values (8, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008c
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008c where result = 'PASS') = 7
                       and not exists (select 1 from verify_0008c where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008c where result = 'PASS'),
                                        (select count(*) from verify_0008c where result <> 'PASS'))) x
order by ord;
