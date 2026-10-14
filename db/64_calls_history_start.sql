-- =============================================================================================
-- 64_calls_history_start.sql: addition 0008k, the start of a tenant's telephony history
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 62_calls_overview.sql (0008j). Rerunnable, forward-only, in one transaction. Run as your own IAM
-- login, dev first, then prod; then 65_verify_calls_history_start.sql (dev), then
-- 63_verify_calls_overview.sql (dev), 35_verify_telephony.sql, 41_verify_lead_metrics.sql,
-- 55_verify_uncounted_lines.sql and 61_verify_inbound_service.sql again.
--
-- Brief B16.1 (README Decision log, 14 October 2026): no change shown against a period before the
-- telephony history. Prod's calls start on 1 October 2026, so This month (1 to 14 October) compared
-- with 31 August to 13 September, a span without data, and read "↑ 358,900 %" and "from none". The
-- Calls report now asks where the tenant's history starts and shows no change when the previous span
-- starts before it. 0008j's functions stay as they are; this addition only adds.
--
-- What it adds
--   history start      cma.telephony_history_start(): the business date of the tenant's earliest
--                      stored call, or null without one (reports.view or performance.team)
--
-- Definition: a call as cma.calls_of defines it (0008j: a telephony call, not deleted, with a start, on
-- a counted line; a line not yet in the catalog counts), on any connection of the tenant, either
-- direction; its business date in its line's market zone, else the tenant's, as cma.calls_of gives it.
-- Tenant-wide: the market and line filters of the Calls report do not narrow it. A tenant without such
-- a call has no history start (null), and the report shows its changes as before.
--
-- How it is read (as 0008j): a function of an explicit tenant (cma.*_of) in the caller's rights, and
-- the application's function that checks the permission and calls it for the current tenant under
-- row-level security. Both SECURITY INVOKER and executable by the application only. It returns a date,
-- nothing personal: no call id, no hash, no number, no telephony user id.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0008j') then
    raise exception 'addition 0008j (62_calls_overview.sql) must run before 0008k';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The history start of a tenant
-- ---------------------------------------------------------------------------------------------
-- The earliest business date of the tenant's calls, as cma.calls_of gives them (no filter), or null.
-- cma.calls_of holds the definition of a call; it is read in windows of seven days from the earliest
-- stored row with a start, so the whole history is never scanned (fixed bounds let it use the index
-- on the tenant and the start; an unbounded read of cma.calls_of scans every call). A window without
-- a call (only deleted calls, or calls on a line that does not count) moves on to the next stored row
-- after it, so the first window with a call holds the earliest call by its start. The earliest
-- business date is then among the calls that start before two days after that one: zones differ by at
-- most 26 hours, so a call that starts two days later is at least 22 hours later on its own clock than
-- the earliest call on its own, and cannot fall on an earlier date.
create or replace function cma.telephony_history_start_of(p_tenant_id uuid)
returns date
language plpgsql stable
as $$
declare
  v_at    timestamptz;
  v_to    timestamptz;
  v_first timestamptz;
begin
  select min(tc.started_at) into v_at
  from cma.telephony_call tc
  where tc.tenant_id = p_tenant_id and tc.started_at is not null;
  while v_at is not null loop
    -- each bound a value of its own, so the read gets it as a constant and uses the index
    v_to := v_at + interval '7 days';
    select min(c.started_at) into v_first
    from cma.calls_of(p_tenant_id, v_at, v_to, null, null) c;
    if v_first is not null then
      v_to := v_first + interval '2 days';
      return (select min(c.business_date)
              from cma.calls_of(p_tenant_id, v_at, v_to, null, null) c);
    end if;
    select min(tc.started_at) into v_at
    from cma.telephony_call tc
    where tc.tenant_id = p_tenant_id and tc.started_at >= v_to;
  end loop;
  return null;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The application's read (permission checked, current tenant, row-level security)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.telephony_history_start()
returns date
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  return cma.telephony_history_start_of(v_tenant);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.telephony_history_start()',
    -- the read of an explicit tenant, which the function above calls in the caller's rights
    -- (row-level security keeps it to the current tenant whatever tenant it is given)
    'cma.telephony_history_start_of(uuid)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008k', 'Telephony history start: the business date of a tenant''s earliest stored call (as cma.calls_of defines a call, in its line''s zone, tenant-wide), so the Calls report shows no change against a period before it')
on conflict (version) do nothing;

commit;
reset role;
