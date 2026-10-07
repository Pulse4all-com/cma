-- =============================================================================================
-- 14_verify_tenant_settings.sql: verifies migration 0003b
-- =============================================================================================
-- Blocks A and B are universal (B works on throwaway tenants and users inside a subtransaction
-- that is always rolled back); block C checks the Pulse4all seed and runs after 02 is rerun.
-- Cloud SQL Studio shows no notices: a check that fails raises "FAIL …" and stops the script.
-- The last result is the verdict. Run as your own IAM login, dev and prod.
-- Provoke: set provoke below to true; every block must then stop with FAIL.
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

-- A. Structure (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     int;
begin
  if not exists (select 1 from cma.schema_migration where version = '0003b') then
    raise exception 'FAIL A1: migration 0003b not recorded';
  end if;
  if (select count(*) from cma.setting where key like 'export.csv.%') <> 5 + v_provoke::int then
    raise exception 'FAIL A2: expected the five export.csv settings in the catalog';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'cma.tenant_setting'::regclass) then
    raise exception 'FAIL A3: row-level security is off on cma.tenant_setting';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'cma.tenant_setting'::regclass and tgname = 'audit')
     or not exists (select 1 from pg_trigger where tgrelid = 'cma.tenant_setting'::regclass and tgname = 'check_value') then
    raise exception 'FAIL A4: audit or validation trigger missing on cma.tenant_setting';
  end if;
  if has_table_privilege('cma_app', 'cma.setting', 'insert') or not has_table_privilege('cma_app', 'cma.setting', 'select') then
    raise exception 'FAIL A5: cma_app must read the catalog and never write it';
  end if;
  if has_function_privilege('cma_readonly', 'cma.set_tenant_setting(text, text)', 'execute') then
    raise exception 'FAIL A6: readers may not call set_tenant_setting';
  end if;

  -- workday.export: on every default manager role (and admin since 0004), on no other default role
  select count(*) into v_bad
  from cma.app_role ar
  where ar.is_system
    -- the manager, and since migration 0004 the admin (a superset of the manager), hold it; nobody else
    and (ar.key in ('manager', 'admin')) <> exists (select 1 from cma.role_permission rp
                                         where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id
                                           and rp.permission_key = 'workday.export');
  if v_bad + v_provoke::int > 0 then
    raise exception 'FAIL A7: % default roles hold workday.export wrongly or lack it', v_bad;
  end if;
end
$$;

-- B. Behaviour on throwaway tenants (universal, always rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_manager  uuid;
  v_agent    uuid;
  v_n        int;
  v_value    text;
  v_default  boolean;
  v_audit    int;
  v_super    uuid;
  v_today    date := (now() at time zone 'UTC')::date;

begin
  begin
    -- Setup as owner: two tenants from the default ladder, a manager and an agent in the first
    v_t1 := cma.create_tenant('verify-0003b-one', 'Verify 0003b one', 'UTC');
    v_t2 := cma.create_tenant('verify-0003b-two', 'Verify 0003b two', 'UTC');
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-manager@example.invalid', 'Verify manager') returning id into v_manager;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    -- the configuring role of the ladder: the manager until migration 0004, the admin (a superset
    -- of the manager, with workday.export) since; picked by permission, not by key
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, v_manager, ar.id from cma.app_role ar
    where ar.tenant_id = v_t1 and ar.is_system
      and exists (select 1 from cma.role_permission rp where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key = 'tenant.configure')
      and exists (select 1 from cma.role_permission rp where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key = 'workday.export')
    order by ar.key limit 1;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, v_agent, id from cma.app_role where tenant_id = v_t1 and key = 'agent';
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-supervisor@example.invalid', 'Verify supervisor') returning id into v_super;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, v_super, id from cma.app_role where tenant_id = v_t1 and key = 'supervisor';

    -- B1. a new tenant's manager gets workday.export from the ladder
    if not exists (select 1 from cma.role_permission rp join cma.app_role ar on ar.id = rp.role_id
                   where ar.tenant_id = v_t1 and ar.key = 'manager' and rp.permission_key = 'workday.export') then
      raise exception 'FAIL B1: a new tenant''s manager lacks workday.export';
    end if;

    -- From here on as the application
    perform set_config('role', 'cma_app', true);

    -- B2. no tenant set: nothing
    perform set_config('app.tenant_id', '', true);
    select count(*) into v_n from cma.tenant_settings();
    if v_n <> 0 then
      raise exception 'FAIL B2: tenant_settings() answers without a tenant';
    end if;

    -- B3. a tenant without own values gets every catalog default
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_agent::text, true);
    select count(*) into v_n from cma.tenant_settings() where is_default;
    if v_n <> (select count(*) from cma.setting) then
      raise exception 'FAIL B3: expected only defaults, got % of %', v_n, (select count(*) from cma.setting);
    end if;

    -- B4. an agent cannot change a setting
    begin
      perform cma.set_tenant_setting('export.csv.separator', 'semicolon');
      raise exception 'FAIL B4: an agent changed a setting';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B5. the manager can; the value is the tenant's own
    perform set_config('app.user_id', v_manager::text, true);
    select value, is_default into v_value, v_default
    from cma.set_tenant_setting('export.csv.separator', 'semicolon');
    if v_value <> 'semicolon' or v_default or v_provoke then
      raise exception 'FAIL B5: the manager''s value was not stored';
    end if;

    -- B6. refusals: a value outside the list, a non-boolean, an unknown key
    begin
      perform cma.set_tenant_setting('export.csv.separator', ';');
      raise exception 'FAIL B6a: a value outside the allowed list was stored';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.set_tenant_setting('export.csv.utf8_bom', 'yes');
      raise exception 'FAIL B6b: a non-boolean was stored';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.set_tenant_setting('export.csv.colour', 'red');
      raise exception 'FAIL B6c: an unknown key was accepted';
    exception when sqlstate 'CMA02' then null;
    end;

    -- B7. a direct insert by the application is validated too
    begin
      insert into cma.tenant_setting (key, value) values ('export.csv.decimal_mark', 'dot');
      raise exception 'FAIL B7: a direct insert bypassed validation';
    exception when sqlstate 'CMA04' then null;
    end;

    -- B8. the other tenant does not see the first tenant's value
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', '', true);
    select value into v_value from cma.tenant_settings() where key = 'export.csv.separator';
    if v_value <> 'comma' then
      raise exception 'FAIL B8: another tenant''s value leaked';
    end if;

    -- B9. null resets to the default
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_manager::text, true);
    select value, is_default into v_value, v_default
    from cma.set_tenant_setting('export.csv.separator', null);
    if v_value <> 'comma' or not v_default then
      raise exception 'FAIL B9: reset did not return to the default';
    end if;

    -- B11 to B15: the export reads. The agent clocks in today, so there is one day to export.
    perform set_config('app.user_id', v_agent::text, true);
    perform cma.open_workday();

    begin
      perform cma.export_hours(v_today, v_today);
      raise exception 'FAIL B11: an agent exported hours';
    exception when sqlstate 'CMA06' then null;
    end;

    -- workday.team is not enough: the files leave the system
    perform set_config('app.user_id', v_super::text, true);
    begin
      perform cma.export_status_changes(v_today, v_today);
      raise exception 'FAIL B12: a supervisor without workday.export exported status changes';
    exception when sqlstate 'CMA06' then null;
    end;

    perform set_config('app.user_id', v_manager::text, true);
    select count(*) into v_n from cma.export_hours(v_today, v_today, v_agent) where status = 'open';
    if v_n <> 1 or v_provoke then
      raise exception 'FAIL B13: the manager''s hours export lacks the agent''s open day (% rows)', v_n;
    end if;

    select count(*) into v_n
    from cma.export_status_changes(v_today, v_today, v_agent) x
    join cma.work_status ws on ws.tenant_id = v_t1 and ws.key = x.status_key and ws.is_default
    where x.is_open and x.to_at is null and x.source = 'user';
    if v_n <> 1 then
      raise exception 'FAIL B14: the status export lacks the open stretch in the default status (% rows)', v_n;
    end if;

    begin
      perform cma.export_hours(v_today - 92, v_today);
      raise exception 'FAIL B15: an export of 93 days was accepted';
    exception when sqlstate 'CMA04' then null;
    end;

    -- B10. every change is in the audit log with its actor
    perform set_config('role', 'cma_owner', true);
    select count(*) into v_audit from cma.audit_log
    where tenant_id = v_t1 and table_name = 'tenant_setting' and actor_user_id = v_manager;
    if v_audit <> 2 then
      raise exception 'FAIL B10: expected 2 audit rows (set, reset), got %', v_audit;
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- C. Pulse4all seed (after 02_seed_pulse4all.sql is rerun): Dutch Excel conventions on both
--    Pulse4all tenants. Another customer's verify checks its own seed here.
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_wrong   int;
begin
  select count(*) into v_wrong
  from cma.tenant t
  cross join (values ('export.csv.separator', 'semicolon'),
                     ('export.csv.decimal_mark', 'comma'),
                     ('export.csv.date_format', 'dd-mm-yyyy')) as want(key, value)
  left join cma.tenant_setting ts on ts.tenant_id = t.id and ts.key = want.key
  where t.slug in ('pulse4all-subscriptions', 'pulse4all-invest')
    and ts.value is distinct from want.value;
  if v_wrong + v_provoke::int > 0
     or (select count(*) from cma.tenant where slug in ('pulse4all-subscriptions', 'pulse4all-invest')) <> 2 then
    raise exception 'FAIL C1: % Pulse4all export settings differ from the seed; rerun 02_seed_pulse4all.sql', v_wrong;
  end if;
end
$$;

-- Verdict: the effective export settings per tenant
select t.slug as tenant,
       string_agg(s.key || ' = ' || coalesce(ts.value, s.default_value || ' (default)'), ', ' order by s.key) as settings,
       'PASS' as verdict
from cma.tenant t
cross join cma.setting s
left join cma.tenant_setting ts on ts.tenant_id = t.id and ts.key = s.key
where t.status = 'active'
group by t.slug
order by t.slug;
