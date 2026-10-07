-- =============================================================================================
-- 16_verify_team_status_time.sql: verifies addition 0003c
-- =============================================================================================
-- Both blocks are universal: A checks structure and privileges, B works on throwaway tenants,
-- users and statuses inside a subtransaction that is always rolled back. No seed is assumed.
-- Cloud SQL Studio shows no notices: a check that fails raises "FAIL …" and stops the script.
-- The last result is the verdict. Run as your own IAM login, dev and prod.
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
  v_fn      text := 'cma.team_status_time(date, date, uuid)';
begin
  if not exists (select 1 from cma.schema_migration where version = '0003c') then
    raise exception 'FAIL A1: addition 0003c not recorded';
  end if;
  if to_regprocedure(v_fn) is null then
    raise exception 'FAIL A2: % does not exist', v_fn;
  end if;
  if not has_function_privilege('cma_app', v_fn, 'execute')
     or has_function_privilege('cma_readonly', v_fn, 'execute')
     or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
     or v_provoke then
    raise exception 'FAIL A3: execute must be granted to cma_app only (not to cma_readonly or public)';
  end if;
  if (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
    raise exception 'FAIL A4: % must run with the caller''s rights, not as its owner', v_fn;
  end if;
  if not exists (select 1 from cma.permission where key = 'performance.team') then
    raise exception 'FAIL A5: permission performance.team missing from the catalog';
  end if;
end
$$;

-- B. Behaviour on throwaway tenants (universal, always rolled back)
--    Day d for the agent, in UTC, written as Add day by the supervisor:
--    09:00 work · 11:00 other work · 12:00 unpaid pause · 12:30 work · 15:00 paid pause · 15:15 work
--    · 17:00 end. Expected: work 6 h 15 min in 3 stretches, other work 1 h, unpaid pause 30 min,
--    paid pause 15 min.
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_today    date := (now() at time zone 'UTC')::date;
  v_d        date := (now() at time zone 'UTC')::date - 3;
  v_d2       date := (now() at time zone 'UTC')::date - 2;
  v_t1       uuid;
  v_t2       uuid;
  v_agent    uuid;
  v_agent2   uuid;
  v_super    uuid;
  v_analyst  uuid;
  v_analyst2 uuid;
  v_n        int;
  v_m        int;
  v_flag     boolean;
  v_active   boolean;

begin
  begin
    -- Setup as owner: two tenants from the default ladder, people in both, four own statuses
    v_t1 := cma.create_tenant('verify-0003c-one', 'Verify 0003c one', 'UTC');
    v_t2 := cma.create_tenant('verify-0003c-two', 'Verify 0003c two', 'UTC');
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-agent-two@example.invalid', 'Verify agent two') returning id into v_agent2;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-supervisor@example.invalid', 'Verify supervisor') returning id into v_super;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-analyst@example.invalid', 'Verify analyst') returning id into v_analyst;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t2, 'verify-analyst@example.invalid', 'Verify analyst two') returning id into v_analyst2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_agent, 'agent'), (v_agent2, 'agent'), (v_super, 'supervisor'), (v_analyst, 'analytics')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t2, v_analyst2, id from cma.app_role where tenant_id = v_t2 and key = 'analytics';

    -- Own statuses with known flags, so nothing depends on the default ladder's keys
    insert into cma.work_status (tenant_id, key, name, is_working, is_productive, is_paid, is_billable, sort_order)
    values (v_t1, 'verify_work',         'Verify work',         true,  true,  true,  true,  1),
           (v_t1, 'verify_other',        'Verify other work',   true,  false, true,  true,  2),
           (v_t1, 'verify_paid_pause',   'Verify paid pause',   false, false, true,  false, 3),
           (v_t1, 'verify_unpaid_pause', 'Verify unpaid pause', false, false, false, false, 4);

    -- From here on as the application
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_super::text, true);

    perform cma.correct_workday(v_agent, v_d, jsonb_build_array(
      jsonb_build_object('kind', 'start',  'statusKey', 'verify_work',         'at', to_char(v_d, 'YYYY-MM-DD') || 'T09:00:00Z'),
      jsonb_build_object('kind', 'status', 'statusKey', 'verify_other',        'at', to_char(v_d, 'YYYY-MM-DD') || 'T11:00:00Z'),
      jsonb_build_object('kind', 'status', 'statusKey', 'verify_unpaid_pause', 'at', to_char(v_d, 'YYYY-MM-DD') || 'T12:00:00Z'),
      jsonb_build_object('kind', 'status', 'statusKey', 'verify_work',         'at', to_char(v_d, 'YYYY-MM-DD') || 'T12:30:00Z'),
      jsonb_build_object('kind', 'status', 'statusKey', 'verify_paid_pause',   'at', to_char(v_d, 'YYYY-MM-DD') || 'T15:00:00Z'),
      jsonb_build_object('kind', 'status', 'statusKey', 'verify_work',         'at', to_char(v_d, 'YYYY-MM-DD') || 'T15:15:00Z'),
      jsonb_build_object('kind', 'end',                                         'at', to_char(v_d, 'YYYY-MM-DD') || 'T17:00:00Z')),
      'Verify 0003c: a day with every kind of status');
    perform cma.correct_workday(v_agent, v_d2, jsonb_build_array(
      jsonb_build_object('kind', 'start', 'statusKey', 'verify_work', 'at', to_char(v_d2, 'YYYY-MM-DD') || 'T10:00:00Z'),
      jsonb_build_object('kind', 'end',                                'at', to_char(v_d2, 'YYYY-MM-DD') || 'T11:00:00Z')),
      'Verify 0003c: a second day');
    perform cma.correct_workday(v_agent2, v_d, jsonb_build_array(
      jsonb_build_object('kind', 'start', 'statusKey', 'verify_work', 'at', to_char(v_d, 'YYYY-MM-DD') || 'T09:00:00Z'),
      jsonb_build_object('kind', 'end',                                'at', to_char(v_d, 'YYYY-MM-DD') || 'T10:00:00Z')),
      'Verify 0003c: another person');

    -- B1. an agent (performance.own only) is refused
    perform set_config('app.user_id', v_agent::text, true);
    begin
      perform cma.team_status_time(v_d, v_d);
      raise exception 'FAIL B1: an agent read the team''s time per status';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B2. the supervisor gets exact seconds and stretches per status
    perform set_config('app.user_id', v_super::text, true);
    select count(*) filter (where (x.status_key, x.seconds, x.stretches, x.is_capped) in (
             ('verify_work', 22500::bigint, 3, false), ('verify_other', 3600::bigint, 1, false),
             ('verify_unpaid_pause', 1800::bigint, 1, false), ('verify_paid_pause', 900::bigint, 1, false))),
           count(*)
      into v_n, v_m
    from cma.team_status_time(v_d, v_d, v_agent) x;
    if v_n <> 4 or v_m <> 4 or v_provoke then
      raise exception 'FAIL B2: expected the four statuses with exact seconds, got % of % rows right', v_n, v_m;
    end if;

    -- B3. analytics reads it too (performance.team) but holds no workday.team
    perform set_config('app.user_id', v_analyst::text, true);
    begin
      select count(*) into v_n from cma.team_status_time(v_d, v_d, v_agent);
    exception when sqlstate 'CMA06' then
      raise exception 'FAIL B3: analytics (performance.team without workday.team) was refused';
    end;
    if v_n <> 4 then
      raise exception 'FAIL B3: analytics got % rows instead of 4', v_n;
    end if;
    begin
      perform cma.team_hours(v_d, v_d);
      raise exception 'FAIL B3b: analytics read Team hours; the test assumes it holds no workday.team';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B4. per person per day, working and paid seconds equal workday_summary (and so Team hours)
    perform set_config('app.user_id', v_super::text, true);
    select count(*) into v_n
    from (select x.user_id, x.business_date,
                 sum(x.seconds) filter (where x.is_working) as working,
                 sum(x.seconds) filter (where x.is_paid)    as paid
          from cma.team_status_time(v_d, v_d2) x
          group by x.user_id, x.business_date) t
    full join (select s.user_id, s.business_date, s.working_seconds, s.paid_seconds
               from cma.workday_summary s
               where s.business_date between v_d and v_d2) s
      on s.user_id = t.user_id and s.business_date = t.business_date
    where t.user_id is null or s.user_id is null
       or coalesce(t.working, 0) <> s.working_seconds or coalesce(t.paid, 0) <> s.paid_seconds;
    if v_n <> 0 then
      raise exception 'FAIL B4: % person-days differ from workday_summary', v_n;
    end if;
    select count(distinct (x.user_id, x.business_date)) into v_n from cma.team_status_time(v_d, v_d2) x;
    if v_n <> 3 then
      raise exception 'FAIL B4b: expected 3 person-days in the range, got %', v_n;
    end if;

    -- B5. the person filter returns that person only
    select count(*), count(*) filter (where x.user_id <> v_agent2) into v_n, v_m
    from cma.team_status_time(v_d, v_d2, v_agent2) x;
    if v_n <> 1 or v_m <> 0 then
      raise exception 'FAIL B5: the person filter returned % rows, % of another person', v_n, v_m;
    end if;

    -- B6. a flag change shows at once; B7. a status set inactive stays in history
    perform set_config('role', 'cma_owner', true);
    update cma.work_status set is_productive = true where tenant_id = v_t1 and key = 'verify_other';
    update cma.work_status set status = 'inactive'  where tenant_id = v_t1 and key = 'verify_paid_pause';
    perform set_config('role', 'cma_app', true);
    select x.is_productive into v_flag from cma.team_status_time(v_d, v_d, v_agent) x where x.status_key = 'verify_other';
    if v_flag is distinct from true then
      raise exception 'FAIL B6: the changed flag did not show';
    end if;
    select x.status_active into v_active from cma.team_status_time(v_d, v_d, v_agent) x where x.status_key = 'verify_paid_pause';
    if v_active is distinct from false then
      raise exception 'FAIL B7: an inactive status vanished from history or shows as active';
    end if;

    -- B8. the range runs forward, has both ends and covers at most 92 days
    begin
      perform cma.team_status_time(v_today - 92, v_today);
      raise exception 'FAIL B8a: a range of 93 days was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.team_status_time(v_d2, v_d);
      raise exception 'FAIL B8b: a backward range was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.team_status_time(null, v_d);
      raise exception 'FAIL B8c: a range without a start was accepted';
    exception when sqlstate 'CMA04' then null;
    end;

    -- B9. today's open day shows its running stretch, not capped, with the same seconds as
    --     workday_summary (now() is fixed within the transaction, so both read the same moment)
    perform set_config('app.user_id', v_agent::text, true);
    perform cma.open_workday();
    perform set_config('app.user_id', v_super::text, true);
    select count(*) into v_n from cma.team_status_time(v_today, v_today, v_agent) x
    where x.business_date = v_today and x.stretches = 1 and not x.is_capped
      and x.seconds = (select s.working_seconds from cma.workday_summary s
                       where s.user_id = v_agent and s.business_date = v_today);
    if v_n <> 1 then
      raise exception 'FAIL B9: today''s open day did not show its running stretch';
    end if;

    -- B10. another tenant sees nothing of the first
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    select count(*) into v_n from cma.team_status_time(v_d, v_today);
    if v_n <> 0 then
      raise exception 'FAIL B10: another tenant''s time leaked (% rows)', v_n;
    end if;

    -- B11. no acting user: refused
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', '', true);
    begin
      perform cma.team_status_time(v_d, v_d);
      raise exception 'FAIL B11: a read without an acting user was accepted';
    exception when sqlstate 'CMA01' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the roles that may read the Dashboard
select t.slug as tenant,
       coalesce(string_agg(ar.key, ', ' order by ar.key), '(none)') as roles_with_performance_team,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
left join cma.app_role ar on ar.tenant_id = t.id
  and exists (select 1 from cma.role_permission rp
              where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key = 'performance.team')
where t.status = 'active'
group by t.slug
order by t.slug;
