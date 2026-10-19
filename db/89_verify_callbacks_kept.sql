-- =============================================================================================
-- 89_verify_callbacks_kept.sql: verifies addition 0008w, callbacks kept (KPI 5)
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; adapters, task types, tasks, contacts,
-- calls and owners are invented data values, and no row carries a name, an address or a phone number.
-- Every check writes one row, PASS or FAIL, and the last result lists them with the verdict, because
-- Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after 88_callbacks_kept.sql; then
-- 73 and 81 again.
--   A  structure and privileges: the addition row after 0008v; every function the application's only and
--      in the caller's rights, the readers' function definer, the owner's, pinned and the readers' only;
--      the reader view's exact columns, with no name, address, email or phone
--   B  behaviour. Tenant one (Europe/Amsterdam; intake from 1 September 2026; the callback window set to 60
--      minutes) holds a CRM connection with a counted callback type, an uncounted one and a plain call type,
--      owners 101 Anna and 103 Bram linked, 102 not, and the callbacks of the week of 5 to 11 October 2026
--      and the week before: kept by a call 30 minutes after, exactly 60 after (a logged call without a
--      direction), exactly 60 before (the earliest of two) and an inbound call 20 minutes after; not kept by
--      a call 61 minutes after; without a contact; without a due time; a deleted one; one whose call's
--      association was removed; one still within its window. Tenant two has no callback type. Checked: the states with the
--      call's minutes from the due time; the window's edges and the earliest call; the setting moving the
--      window; pending while the window is open; the tasks apart and absent; the figures per ISO week and
--      in total; the previous period like for like and while the period runs; per person by name with the
--      not-linked row; a callback type counted or none; the range and the permissions; tenant isolation; a
--      reader scoped to one tenant
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 89 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008w;
create temp table verify_0008w (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008w_code(p_sql text)
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

-- One task as the ingest write takes it: a type, a due time (or none), a contact (or none), an owner
create or replace function pg_temp.v0008w_task(p_src text, p_type text, p_due timestamptz, p_contact text, p_owner text,
                                               p_created timestamptz default '2026-09-20 09:00:00+00')
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object('sourceId', p_src, 'statusRef', 'OPEN', 'typeRef', p_type, 'dueAt', p_due,
    'contactId', p_contact, 'ownerRef', p_owner, 'createdAt', p_created, 'updatedAt', '2026-10-01T00:00:00Z'))
$$;

-- One CRM call to a contact's number as the ingest write takes it
create or replace function pg_temp.v0008w_call(p_src text, p_at timestamptz, p_direction text)
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object('sourceId', p_src, 'occurredAt', p_at, 'direction', p_direction, 'ownerRef', '101',
    'updatedAt', p_at))
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008v
  insert into verify_0008w values (1, 'A1 addition 0008w recorded, after 0008v',
    case when exists (select 1 from cma.schema_migration where version = '0008w')
              and exists (select 1 from cma.schema_migration where version = '0008v') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. every function of the addition the application's only and in the caller's rights; the readers'
  --     function SECURITY DEFINER, owned by cma_owner, search path pinned, the readers' only
  v_bad := '';
  foreach v_fn in array array[
    'cma.callbacks_kept_of(uuid,timestamptz,timestamptz,timestamptz)', 'cma.callbacks_kept_connected_of(uuid)',
    'cma.callbacks_kept_figures_of(uuid,date,date,timestamptz,timestamptz)', 'cma.callbacks_kept_report_of(uuid,date,date,timestamptz)',
    'cma.callbacks_kept_per_owner_of(uuid,date,date,timestamptz)', 'cma.callbacks_kept_report(date,date)',
    'cma.callbacks_kept_per_owner(date,date)', 'cma.callbacks_kept_connected()'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or has_function_privilege('public', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' not the application''s only or not in the caller''s rights; ';
    end if;
  end loop;
  v_fn := 'cma_read.callbacks_kept_rows()';
  if to_regprocedure(v_fn) is null then
    v_bad := v_bad || v_fn || ' missing; ';
  elsif not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
        or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
        or not coalesce((select array_to_string(proconfig, ',') from pg_proc where oid = to_regprocedure(v_fn)) like 'search_path=%pg_temp', false)
        or not has_function_privilege('cma_readonly', v_fn, 'execute') or has_function_privilege('cma_app', v_fn, 'execute')
        or has_function_privilege('public', v_fn, 'execute') then
    v_bad := v_bad || v_fn || ' not the readers'' pinned definer function; ';
  end if;
  insert into verify_0008w values (2, 'A2 every function the application''s only and invoker; the readers'' function definer, pinned, theirs only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the reader view's exact columns, readable by the readers, none named like a name, an address, an
  --     email or a phone
  v_bad := '';
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'callbacks_kept')
     is distinct from 'tenant_id,connection_id,task_source_id,owner_user_id,due_at,business_date,week_start,state,call_at,minutes_from_due'
     or not has_table_privilege('cma_readonly', 'cma_read.callbacks_kept', 'select') then
    v_bad := 'cma_read.callbacks_kept';
  end if;
  select v_bad || coalesce(string_agg(column_name, ', '), '') into v_bad
  from information_schema.columns
  where table_schema = 'cma_read' and table_name = 'callbacks_kept'
    and column_name ~* '(name|address|email|phone|number|_hash$)';
  insert into verify_0008w values (3, 'A3 the reader view with its exact columns; no name, address, email or phone',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_reader1 uuid; v_super1 uuid; v_agent1 uuid; v_anna uuid; v_bram uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid;
  v_crm uuid; v_crm2 uuid;
  v_role uuid;
  v_txt text; v_detail text;
  v_from timestamptz := '2026-10-04 22:00:00+00';    -- Monday 5 October 2026, 00:00 in Amsterdam
  v_to   timestamptz := '2026-10-11 22:00:00+00';    -- Monday 12 October, 00:00
  v_after   timestamptz := '2026-10-20 09:00:00+00';  -- every window has closed
  v_running timestamptz := '2026-10-09 07:30:00+00';  -- Friday 9 October, 09:30 in Amsterdam
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people and roles (as the owner, as 0008u's verify)
    v_t1 := cma.create_tenant('verify-0008w-one', 'Verify 0008w one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008w-two', 'Verify 0008w two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader1@example.invalid', 'reader1') returning id into v_reader1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-super1@example.invalid', 'super1') returning id into v_super1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-anna@example.invalid', 'Anna Verify') returning id into v_anna;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-bram@example.invalid', 'Bram Verify') returning id into v_bram;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_reader1, 'verify_reader'), (v_t1, v_super1, 'supervisor'),
                 (v_t1, v_agent1, 'agent'), (v_t1, v_anna, 'agent'), (v_t1, v_bram, 'agent'),
                 (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): the intake start, the callback window of 60 minutes, the owners
    -- (101 Anna, 103 Bram; 102 nobody), the CRM connection and its task types
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform cma.set_tenant_setting('tasks.callback_window_minutes', '60');
    perform cma.set_user_external_id(v_anna, 'verifycrm_owner', '101');
    perform cma.set_user_external_id(v_bram, 'verifycrm_owner', '103');
    select c.connection_id into v_crm from cma.upsert_connection('verifycrm', 'Verify callbacks one', 'portal-1', null, null) c;
    perform cma.set_connection_kind(v_crm, 'crm');
    perform cma.set_task_type(v_crm, 'CB', 'Callback', true, true);
    perform cma.set_task_type(v_crm, 'CBX', 'Callback, not counted', true, false);
    perform cma.set_task_type(v_crm, 'CALL', 'Call', false, true);

    -- the tasks (the Ingest user): the week of 5 October and the one before; k9 deleted by a later read
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_tasks(v_crm, jsonb_build_array(
      pg_temp.v0008w_task('k1', 'CB', '2026-10-06 10:00:00+00', 'c1', '101'),
      pg_temp.v0008w_task('k2', 'CB', '2026-10-06 12:00:00+00', 'c2', '101'),
      pg_temp.v0008w_task('k3', 'CB', '2026-10-07 09:00:00+00', 'c3', '103'),
      pg_temp.v0008w_task('k4', 'CB', '2026-10-07 12:00:00+00', 'c4', '102'),
      pg_temp.v0008w_task('k5', 'CB', '2026-10-08 09:00:00+00', null, '101'),
      pg_temp.v0008w_task('k6', 'CB', null, 'c6', '101', '2026-10-08 10:00:00+00'),
      pg_temp.v0008w_task('k7', 'CBX', '2026-10-08 10:00:00+00', 'c1', '101'),
      pg_temp.v0008w_task('k8', 'CALL', '2026-10-08 10:00:00+00', 'c1', '101'),
      pg_temp.v0008w_task('k9', 'CB', '2026-10-08 11:00:00+00', 'c1', '101'),
      pg_temp.v0008w_task('k10', 'CB', '2026-10-11 21:30:00+00', 'c10', '103'),
      pg_temp.v0008w_task('k11', 'CB', '2026-09-30 10:00:00+00', 'c11', '101'),
      pg_temp.v0008w_task('k12', 'CB', '2026-10-01 10:00:00+00', 'c12', '101'),
      pg_temp.v0008w_task('k13', 'CB', '2026-10-02 08:00:00+00', 'c13', '101'),
      pg_temp.v0008w_task('k14', 'CB', '2026-10-09 07:00:00+00', 'c14', '103'),
      pg_temp.v0008w_task('k15', 'CB', '2026-10-08 13:00:00+00', 'c15', '101')));
    perform cma.ingest_upsert_tasks(v_crm, '[{"sourceId": "k9", "statusRef": "OPEN", "typeRef": "CB", "deletedAt": "2026-10-05T00:00:00Z",
                                             "createdAt": "2026-09-20T09:00:00Z", "updatedAt": "2026-10-05T00:00:00Z"}]');
    -- the calls: k1 30 minutes after; k2 exactly 60 after, without a direction; k3 61 after; k4 exactly 60
    -- before and 30 before; k15 an inbound call 20 minutes after (either direction keeps); k9's within (a
    -- deleted task); k10's within, its association removed; k11 at the due time; k12 two hours after; k13 ten
    -- minutes after (10:10 in Amsterdam on Friday 2 October)
    perform cma.ingest_upsert_calls(v_crm, jsonb_build_array(
      pg_temp.v0008w_call('l1', '2026-10-06 10:30:00+00', 'outbound'),
      pg_temp.v0008w_call('l2', '2026-10-06 13:00:00+00', null),
      pg_temp.v0008w_call('l3', '2026-10-07 10:01:00+00', 'outbound'),
      pg_temp.v0008w_call('l15', '2026-10-08 13:20:00+00', 'inbound'),
      pg_temp.v0008w_call('l4', '2026-10-07 11:00:00+00', 'outbound'),
      pg_temp.v0008w_call('l4b', '2026-10-07 11:30:00+00', 'outbound'),
      pg_temp.v0008w_call('l9', '2026-10-08 11:00:00+00', 'outbound'),
      pg_temp.v0008w_call('l10', '2026-10-11 21:00:00+00', 'outbound'),
      pg_temp.v0008w_call('l11', '2026-09-30 10:00:00+00', 'outbound'),
      pg_temp.v0008w_call('l12', '2026-10-01 12:00:00+00', 'outbound'),
      pg_temp.v0008w_call('l13', '2026-10-02 08:10:00+00', 'outbound')));
    perform cma.ingest_upsert_associations(v_crm, (
      select jsonb_agg(jsonb_build_object('fromType', 'crm_call', 'fromId', x.call, 'toType', 'contact', 'toId', x.contact, 'removed', x.removed,
                                          'changedAt', '2026-10-01T00:00:00Z'))
      from (values ('l1', 'c1', false), ('l2', 'c2', false), ('l3', 'c3', false), ('l15', 'c15', false), ('l4', 'c4', false), ('l4b', 'c4', false),
                   ('l9', 'c1', false), ('l10', 'c10', false), ('l11', 'c11', false), ('l12', 'c12', false), ('l13', 'c13', false)) as x(call, contact, removed)));
    perform cma.ingest_upsert_associations(v_crm, '[{"fromType": "crm_call", "fromId": "l10", "toType": "contact", "toId": "c10", "removed": true,
                                                    "changedAt": "2026-10-12T00:00:00Z"}]');

    perform set_config('app.user_id', v_analyst1::text, true);

    -- B1. the week's states with the call's minutes from the due time (after every window closed)
    select string_agg(format('%s:%s:%s', x.task_source_id, x.state, coalesce(x.minutes_from_due::text, '-')), ' ' order by x.placed_at, x.task_source_id) into v_txt
    from cma.callbacks_kept_of(v_t1, v_from, v_to, v_after) x;
    v_rows := v_rows || array['11', 'B1 the week''s callbacks with their states and the call''s minutes from the due time',
      case when v_txt = 'k1:kept:30 k2:kept:60 k3:not_kept:- k4:kept:-60 k5:no_contact:- k6:no_due:- k15:kept:20 k14:not_kept:- k10:not_kept:-'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. the window's edges: exactly 60 after (a call without a direction) and 60 before kept, the earliest of
    --     two; 61 after not; an inbound call keeps; a removed association no call
    select string_agg(format('%s:%s', x.task_source_id, coalesce(to_char(x.call_at at time zone 'UTC', 'HH24:MI'), '-')), ' ' order by x.task_source_id) into v_txt
    from cma.callbacks_kept_of(v_t1, v_from, v_to, v_after) x where x.task_source_id in ('k2', 'k3', 'k4', 'k10', 'k15');
    v_rows := v_rows || array['12', 'B2 the window''s edges, the earliest call, an inbound call, no removed association',
      case when v_txt = 'k10:- k15:13:20 k2:13:00 k3:- k4:11:00' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. the setting moves the window: at 240 minutes k3's call 61 after keeps it; back to 60 it does not
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('tasks.callback_window_minutes', '240');
    select x.state into v_txt from cma.callbacks_kept_of(v_t1, v_from, v_to, v_after) x where x.task_source_id = 'k3';
    perform cma.set_tenant_setting('tasks.callback_window_minutes', '60');
    select v_txt || ' ' || x.state into v_txt from cma.callbacks_kept_of(v_t1, v_from, v_to, v_after) x where x.task_source_id = 'k3';
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['13', 'B3 the setting tasks.callback_window_minutes moves the window',
      case when v_txt = 'kept not_kept' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. pending while the window is open: k14, due at 09:00 on Friday, at 09:30 pending; at 10:01 not kept
    select string_agg(x.state, ' ' order by x.state) into v_txt
    from (select x.state from cma.callbacks_kept_of(v_t1, v_from, v_to, v_running) x where x.task_source_id = 'k14'
          union all
          select x.state from cma.callbacks_kept_of(v_t1, v_from, v_to, timestamptz '2026-10-09 08:01:00+00') x where x.task_source_id = 'k14') x;
    v_rows := v_rows || array['14', 'B4 pending while the window is open, not kept once it closed',
      case when v_txt = 'not_kept pending' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. absent: a type not counted (k7), not a callback (k8), a deleted task (k9); a task without a due time
    --     placed by its creation (k6 on 8 October)
    select format('%s/%s', count(*) filter (where x.task_source_id in ('k7', 'k8', 'k9')),
                  max(x.business_date) filter (where x.task_source_id = 'k6')) into v_txt
    from cma.callbacks_kept_of(v_t1, v_from, v_to, v_after) x;
    v_rows := v_rows || array['15', 'B5 a type not counted, not a callback and a deleted task absent; no due time placed by its creation',
      case when v_txt = '0/2026-10-08' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. the figures per ISO week and in total (7 with a contact and a due time: 4 kept, 3 not; 1 without a
    --     contact, 1 without a due time); the week of Sunday 11 October 23:30 in Amsterdam is still 5 October's
    select string_agg(format('%s:%s:%s/%s/%s/%s/%s/%s', f.dimension, coalesce(f.week_start::text, '-'), f.callbacks, f.kept, f.not_kept, f.pending,
                             f.no_contact, f.no_due), ' ') into v_txt
    from cma.callbacks_kept_figures_of(v_t1, date '2026-10-05', date '2026-10-11', v_after) f;
    v_rows := v_rows || array['16', 'B6 the figures per ISO week and in total',
      case when v_txt = 'week:2026-10-05:7/4/3/0/1/1 total:-:7/4/3/0/1/1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. the report: the previous week in full after the period (k11 and k13 kept, k12 not); while the period
    --     runs (Friday 09:30) the callbacks due later in the week are pending (k14 and k10), and the week before
    --     counts up to Friday 2 October 09:30: k13 at 10:00 left out
    select string_agg(format('%s:%s:%s/%s/%s', r.period, r.dimension, r.callbacks, r.kept, r.not_kept), ' ') into v_txt
    from cma.callbacks_kept_report_of(v_t1, date '2026-10-05', date '2026-10-11', v_after) r where r.dimension = 'total';
    select v_txt || ' | ' || string_agg(format('%s:%s/%s/%s/%s', r.period, r.callbacks, r.kept, r.not_kept, r.pending), ' ') into v_txt
    from cma.callbacks_kept_report_of(v_t1, date '2026-10-05', date '2026-10-11', v_running) r where r.dimension = 'total';
    v_rows := v_rows || array['17', 'B7 the previous period like for like: in full after the period, up to the time of day while it runs',
      case when v_txt = 'current:total:7/4/3 previous:total:3/2/1 | current:7/4/1/2 previous:2/1/1/0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. per person by name, never ranked: Anna (k1, k2, k15 kept; k5 without a contact), Bram (k3, k14 and k10 not
    --     kept), one owner id without a person (k4 kept), the total; refused for the reader (reports.view)
    perform set_config('app.user_id', v_super1::text, true);
    select string_agg(format('%s:%s/%s/%s/%s', coalesce(p.display_name, p.row_kind || coalesce('(' || p.unlinked_owners || ')', '')),
                             p.callbacks, p.kept, p.not_kept, p.no_contact), ' ') into v_txt
    from cma.callbacks_kept_per_owner_of(v_t1, date '2026-10-05', date '2026-10-11', v_after) p;
    perform set_config('app.user_id', v_reader1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008w_code('select * from cma.callbacks_kept_per_owner(date ''2026-10-05'', date ''2026-10-11'')');
    v_rows := v_rows || array['18', 'B8 per person by name with the not-linked row and the total; not for reports.view alone',
      case when v_txt = 'Anna Verify:3/3/0/1 Bram Verify:3/0/3/0 not_linked(1):1/1/0/0 total:7/4/3/1 CMA06' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. the range and the permissions: more than 92 days refused; the report for reports.view (the reader) and
    --     performance.team (the supervisor), per person for the supervisor and the analyst; the agent and the
    --     Ingest user refused; no acting user CMA01
    v_txt := pg_temp.v0008w_code('select * from cma.callbacks_kept_report(date ''2026-01-01'', date ''2026-10-11'')') || ' ';
    foreach v_detail in array array[v_reader1::text, v_super1::text, v_analyst1::text, v_agent1::text, v_ing1::text] loop
      perform set_config('app.user_id', v_detail, true);
      v_txt := v_txt || pg_temp.v0008w_code('select * from cma.callbacks_kept_report(date ''2026-10-05'', date ''2026-10-11'')')
        || '/' || pg_temp.v0008w_code('select * from cma.callbacks_kept_per_owner(date ''2026-10-05'', date ''2026-10-11'')')
        || '/' || pg_temp.v0008w_code('select cma.callbacks_kept_connected()') || ' ';
    end loop;
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || pg_temp.v0008w_code('select * from cma.callbacks_kept_report(date ''2026-10-05'', date ''2026-10-11'')');
    v_rows := v_rows || array['19', 'B9 the range and the permissions: the report for reports.view or performance.team, per person for performance.team',
      case when v_txt = 'CMA04 ok/CMA06/ok ok/ok/ok ok/ok/ok CMA06/CMA06/CMA06 CMA06/CMA06/CMA06 CMA01' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. a counted callback type or none: tenant one has one; with the type no longer counted none, and the
    --      report answers zeros; tenant two has none
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := cma.callbacks_kept_connected()::text;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_task_type(v_crm, 'CB', 'Callback', true, false);
    perform set_config('app.user_id', v_analyst1::text, true);
    select v_txt || ' ' || cma.callbacks_kept_connected()::text || ' ' || r.callbacks || '/' || r.no_contact into v_txt
    from cma.callbacks_kept_report(date '2026-10-05', date '2026-10-11') r where r.period = 'current' and r.dimension = 'total';
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_task_type(v_crm, 'CB', 'Callback', true, true);
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    v_txt := v_txt || ' ' || cma.callbacks_kept_connected()::text;
    v_rows := v_rows || array['20', 'B10 a counted callback type or none; the report''s zeros without one',
      case when v_txt = 'true false 0/0 false' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B11. tenant isolation: tenant two (a connection of the same adapter, a callback type of the same ref) sees
    --      none of tenant one's callbacks and cannot change its type
    perform set_config('app.user_id', v_admin2::text, true);
    select c.connection_id into v_crm2 from cma.upsert_connection('verifycrm', 'Verify callbacks two', 'portal-2', null, null) c;
    perform cma.set_connection_kind(v_crm2, 'crm');
    perform cma.set_task_type(v_crm2, 'CB', 'Callback', true, true);
    v_txt := pg_temp.v0008w_code(format('select cma.set_task_type(%L, ''CB'', ''Callback'', false, false)', v_crm));
    perform set_config('app.user_id', v_analyst2::text, true);
    select v_txt || ' ' || string_agg(format('%s:%s/%s', r.dimension, r.callbacks, r.no_due), ' ') into v_txt
    from cma.callbacks_kept_report(date '2026-10-05', date '2026-10-11') r where r.period = 'current';
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    select v_txt || ' ' || y.is_callback into v_txt from cma.connection_task_type y where y.connection_id = v_crm and y.type_ref = 'CB';
    v_rows := v_rows || array['21', 'B11 tenant isolation for the reads and the configuration',
      case when v_txt = 'CMA02 total:0/0 true' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B12. a reader scoped to tenant one sees its callbacks since the intake start (the week's nine and the
    --      three of the week before; six kept) with their states; scoped to tenant two, none of tenant one's
    perform set_config('role', 'cma_readonly', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    select format('%s/%s', (select count(*) from cma_read.callbacks_kept where tenant_id = v_t1),
                  (select count(*) from cma_read.callbacks_kept where tenant_id = v_t1 and state = 'kept')) into v_txt;
    perform set_config('app.tenant_id', v_t2::text, true);
    select v_txt || format(' %s', (select count(*) from cma_read.callbacks_kept where tenant_id = v_t1)) into v_txt;
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['22', 'B12 a reader scoped to one tenant sees its own callbacks only',
      case when v_txt = '12/6 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008w (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008w values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008w
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008w where result = 'PASS') = 15
                       and not exists (select 1 from verify_0008w where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008w where result = 'PASS'),
                                        (select count(*) from verify_0008w where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008w_code(text);
drop function if exists pg_temp.v0008w_task(text, text, timestamptz, text, text, timestamptz);
drop function if exists pg_temp.v0008w_call(text, timestamptz, text);
