-- =============================================================================================
-- 78_system_health.sql: addition 0008r, what Configuration → System health reads and what the
-- scheduler leaves behind
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 74_forms_reporting.sql (0008p). Rerunnable, forward-only, in one transaction. Run as your own IAM
-- login, dev first, then prod; then 79_verify_system_health.sql (dev), then 33_verify_intake_core.sql
-- and 73_verify_follow_up.sql (dev) again (unchanged: the settings trigger and sync_run's job list
-- grew, nothing else of theirs changed).
--
-- Full IT audit of 17 October 2026 (README Decision log; docs/audits/2026-10-17-full-audit): one page
-- where an admin sees whether every source, job and the ingest heartbeat is alive. The Workspace reads
-- Postgres only, so the page shows what the jobs leave behind in cma.sync_run (0007), next to
-- cma.sources() (0008e) and cma.outbox_status() (0007c), which already give the sources' event counts
-- and the outbox per state. Two things were missing and come here: one read that sums sync_run per job
-- and connection, and a run row for the scheduler's forgotten-day close, so every scheduled job is on
-- one list. The heartbeat is the sweep's link_calls row per tenant per minute (ingest/src/jobs/sweep.mjs);
-- the page derives fresh, late and silent from its age against two tenant settings, never from code.
--
-- What it adds
--   settings              health.heartbeat_fresh_seconds (120) and health.heartbeat_late_seconds (900):
--                         the heartbeat is fresh below the first, silent from the second, late in between;
--                         health.link_gemini_doc and health.link_datamap (empty): the two addresses the
--                         page links to, set by the tenant (https or empty); cma.check_tenant_setting()
--                         checks the four (whole seconds within bounds, fresh below late; an https
--                         address of at most 500 characters), 0008o's branches unchanged
--   sync_run              the job close_forgotten_workdays joins the list (check constraint replaced, as
--                         0008m did for email_poll); connection_id nullable, for that job alone (a check);
--                         an index on (tenant_id, started_at desc) so the page's window over the last 30
--                         days is a range scan, not a scan of the tenant's history
--   cma.scheduler_run_start()        one running row for the scheduler's close (job
--                                    close_forgotten_workdays, no connection), for workday.close_forgotten
--                                    holders (the tenant's Scheduler user, 0005a); returns its id
--   cma.scheduler_run_finish()       ends that row once, succeeded with the count of days closed or failed
--                                    with a code (200 characters at most, as the ingest's); CMA02 for an
--                                    unknown row, CMA03 for a finished one, CMA04 for a bad status
--   cma.system_health_runs()         per job and connection over the last 30 days: the last run (started,
--                                    finished, status, error, counts), the last success, the last failure
--                                    with its error, the runs and failures of the last 24 hours
--                                    (tenant.configure; stable; counts, codes and times only)
--
-- Nothing personal in any of it: a sync_run row holds a job, a connection id, a stream, a range, counts
-- and an error code. No reporting view is added: readers already have cma_read.sync_run (0007).
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0008p') then
    raise exception 'addition 0008p (74_forms_reporting.sql) must run before 0008r';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The heartbeat's thresholds as tenant settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('health.heartbeat_fresh_seconds', 'integer', null, '120',
     'The ingest heartbeat (the sweep''s link_calls run, every minute) counts as fresh while its latest run is younger than this many seconds'),
  ('health.heartbeat_late_seconds',  'integer', null, '900',
     'The ingest heartbeat counts as silent once its latest run is older than this many seconds; between the two it is late'),
  ('health.link_gemini_doc', 'text', null, '',
     'The address of the Google Doc with the Gemini audit findings, linked from System health (https, or empty for no link)'),
  ('health.link_datamap', 'text', null, '',
     'The address of the published data map, linked from System health (https, or empty for no link)')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- The settings trigger as 0008o left it, with the two heartbeat branches added before the actor is set
create or replace function cma.check_tenant_setting()
returns trigger
language plpgsql
as $$
declare
  s       cma.setting;
  v_other time;
begin
  select * into s from cma.setting where key = new.key;
  if not found then
    raise exception 'Unknown setting %', new.key using errcode = 'CMA02';
  end if;
  if new.key = 'auth.invitation_email_domains' then
    new.value := lower(regexp_replace(new.value, '[[:space:]]+', '', 'g'));
  end if;
  if new.key = 'email.start_date' then
    new.value := btrim(new.value);
  end if;
  if new.key = 'leads.age_buckets_business_days' then
    new.value := regexp_replace(new.value, '[[:space:]]+', '', 'g');
  end if;
  if s.value_type = 'boolean' and new.value not in ('true', 'false') then
    raise exception 'Setting % takes true or false', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'integer' and new.value !~ '^-?[0-9]+$' then
    raise exception 'Setting % takes a whole number', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'date' or (new.key = 'email.start_date' and new.value <> '') then
    if new.value !~ '^\d{4}-\d{2}-\d{2}$' then
      raise exception 'Setting % takes a date as YYYY-MM-DD', new.key using errcode = 'CMA04';
    end if;
    begin
      perform new.value::date;
    exception when others then
      raise exception 'Setting % takes a date as YYYY-MM-DD', new.key using errcode = 'CMA04';
    end;
  end if;
  if s.value_type = 'time' and new.value !~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$' then
    raise exception 'Setting % takes a time as HH:MI, 00:00 to 24:00', new.key using errcode = 'CMA04';
  end if;
  if s.allowed_values is not null and not (new.value = any (s.allowed_values)) then
    raise exception 'Setting % takes one of: %', new.key, array_to_string(s.allowed_values, ', ')
      using errcode = 'CMA04';
  end if;
  -- the window starts before it ends, against the other bound's effective value
  if new.key = 'workday.window_start' then
    v_other := cma.setting_of(new.tenant_id, 'workday.window_end')::time;
    if new.value::time >= v_other then
      raise exception 'The workday window must start before it ends (%)', to_char(v_other, 'HH24:MI') using errcode = 'CMA04';
    end if;
  elsif new.key = 'workday.window_end' then
    v_other := cma.setting_of(new.tenant_id, 'workday.window_start')::time;
    if new.value::time <= v_other then
      raise exception 'The workday window must end after it starts (%)', to_char(v_other, 'HH24:MI') using errcode = 'CMA04';
    end if;
  elsif new.key = 'workday.auto_close_notify_permission' and not exists (select 1 from cma.permission p where p.key = new.value) then
    raise exception 'Setting % takes a permission key', new.key using errcode = 'CMA04';
  elsif new.key = 'auth.invitation_valid_days'
        and (case when length(new.value) > 3 then true else new.value::integer not between 1 and 30 end) then
    raise exception 'Setting % takes a whole number of days from 1 to 30', new.key using errcode = 'CMA04';
  elsif new.key = 'auth.invitation_email_domains' and not cma.is_domain_list(new.value) then
    raise exception 'Setting % takes domain names separated by commas, such as example.com,example.org', new.key using errcode = 'CMA04';
  elsif new.key = 'email.reply_target_minutes'
        and (case when length(new.value) > 5 then true else new.value::integer not between 1 and 10080 end) then
    raise exception 'Setting % takes a whole number of minutes from 1 to 10080', new.key using errcode = 'CMA04';
  elsif new.key = 'email.no_response_days'
        and (case when length(new.value) > 2 then true else new.value::integer not between 1 and 90 end) then
    raise exception 'Setting % takes a whole number of days from 1 to 90', new.key using errcode = 'CMA04';
  elsif new.key = 'email.market_order' and not cma.is_email_market_order(new.value) then
    raise exception 'Setting % takes contact, form, record and inbox in the order wanted, lower case, comma-separated without spaces, each at most once, such as contact,form,record,inbox', new.key
      using errcode = 'CMA04';
  -- the follow-up layer (0008o)
  elsif new.key = 'tickets.sla_minutes'
        and (case when length(new.value) > 6 then true else new.value::integer not between 1 and 100000 end) then
    raise exception 'Setting % takes a whole number of business minutes from 1 to 100000', new.key using errcode = 'CMA04';
  elsif new.key = 'tickets.sla_warning_pct'
        and (case when length(new.value) > 3 then true else new.value::integer not between 1 and 100 end) then
    raise exception 'Setting % takes a share from 1 to 100', new.key using errcode = 'CMA04';
  elsif new.key = 'leads.age_buckets_business_days' and not cma.is_bucket_list(new.value) then
    raise exception 'Setting % takes one to five increasing whole numbers of business days, comma-separated, such as 1,2,5', new.key using errcode = 'CMA04';
  elsif new.key = 'tasks.callback_window_minutes'
        and (case when length(new.value) > 5 then true else new.value::integer not between 0 and 10080 end) then
    raise exception 'Setting % takes a whole number of minutes from 0 to 10080', new.key using errcode = 'CMA04';
  -- the System health page (0008r): the ingest heartbeat's thresholds, fresh below the first, silent
  -- from the second, late in between
  elsif new.key = 'health.heartbeat_fresh_seconds' then
    if (case when length(new.value) > 4 then true else new.value::integer not between 10 and 3600 end) then
      raise exception 'Setting % takes a whole number of seconds from 10 to 3600', new.key using errcode = 'CMA04';
    end if;
    if new.value::integer >= cma.setting_of(new.tenant_id, 'health.heartbeat_late_seconds')::integer then
      raise exception 'The heartbeat counts as fresh for fewer seconds than it takes to count as silent (%)',
        cma.setting_of(new.tenant_id, 'health.heartbeat_late_seconds') using errcode = 'CMA04';
    end if;
  elsif new.key = 'health.heartbeat_late_seconds' then
    if (case when length(new.value) > 5 then true else new.value::integer not between 60 and 86400 end) then
      raise exception 'Setting % takes a whole number of seconds from 60 to 86400', new.key using errcode = 'CMA04';
    end if;
    if new.value::integer <= cma.setting_of(new.tenant_id, 'health.heartbeat_fresh_seconds')::integer then
      raise exception 'The heartbeat counts as silent after more seconds than it counts as fresh (%)',
        cma.setting_of(new.tenant_id, 'health.heartbeat_fresh_seconds') using errcode = 'CMA04';
    end if;
  -- the two links System health shows: an https address of at most 500 characters without spaces, or empty
  elsif new.key in ('health.link_gemini_doc', 'health.link_datamap') then
    new.value := btrim(new.value);
    if new.value <> '' and (length(new.value) > 500 or new.value !~ '^https://[^[:space:]"''<>]+$') then
      raise exception 'Setting % takes an https address, or nothing', new.key using errcode = 'CMA04';
    end if;
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. sync_run: the scheduler's job joins the list; an index for the page's window
-- ---------------------------------------------------------------------------------------------
alter table cma.sync_run drop constraint if exists sync_run_job_check;
alter table cma.sync_run add constraint sync_run_job_check
  check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls', 'email_poll', 'close_forgotten_workdays'));
-- A run of the scheduler belongs to no connection: the column becomes nullable for that job alone (the
-- composite foreign key already allows a null; the ingest's start keeps requiring an active connection)
alter table cma.sync_run alter column connection_id drop not null;
alter table cma.sync_run drop constraint if exists sync_run_connection_check;
alter table cma.sync_run add constraint sync_run_connection_check
  check ((connection_id is null) = (job = 'close_forgotten_workdays'));

create index if not exists sync_run_tenant_started_idx on cma.sync_run (tenant_id, started_at desc);

-- ---------------------------------------------------------------------------------------------
-- 3. The scheduler's run row (workday.close_forgotten: the tenant's Scheduler user)
-- ---------------------------------------------------------------------------------------------
-- The ingest's start needs an active connection (0007); the scheduler has none, so its row has its own
-- start and finish with the same shape. The job script writes the start in its own transaction before
-- the close, and the finish in another after it, so a close that fails still leaves a failed row.
create or replace function cma.scheduler_run_start()
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  perform cma.assert_permission('workday.close_forgotten');
  -- the wall clock, not the transaction's start: the job writes this row in a transaction of its own
  -- before the close, and two runs in one session must never share a start
  insert into cma.sync_run (tenant_id, connection_id, job, stream, from_at, to_at, started_at)
  values (cma.current_tenant_id(), null, 'close_forgotten_workdays', null, clock_timestamp(), clock_timestamp(), clock_timestamp())
  returning id into v_id;
  return v_id;
end
$$;

create or replace function cma.scheduler_run_finish(p_run_id uuid, p_status text, p_closed integer, p_error text default null)
returns void
language plpgsql
as $$
declare
  v_status text;
begin
  perform cma.assert_permission('workday.close_forgotten');
  if p_status not in ('succeeded', 'failed') then
    raise exception 'status must be succeeded or failed' using errcode = 'CMA04';
  end if;
  if p_closed is null or p_closed < 0 then
    raise exception 'closed is a whole number of days' using errcode = 'CMA04';
  end if;
  select r.status into v_status from cma.sync_run r
  where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id and r.job = 'close_forgotten_workdays' for update;
  if v_status is null then
    raise exception 'no scheduler run % in the current tenant', p_run_id using errcode = 'CMA02';
  end if;
  if v_status <> 'running' then
    raise exception 'scheduler run % is already finished', p_run_id using errcode = 'CMA03';
  end if;
  update cma.sync_run r
     set status = p_status, finished_at = clock_timestamp(), counts = jsonb_build_object('closed', p_closed),
         error = left(nullif(btrim(p_error), ''), 200)
   where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The page's read: sync_run summed per job and connection over the last 30 days
-- ---------------------------------------------------------------------------------------------
-- One row per job and connection (null for the tenant-wide jobs) that ran in the last 30 days: the
-- last run as it stands, the last success, the last failure with its error, and the last 24 hours'
-- counts. The window keeps the read a range scan on (tenant_id, started_at); a job that did not run in
-- 30 days has no row, which the page shows as such. Null connections compare with is not distinct from.
create or replace function cma.system_health_runs()
returns table(
  job text, connection_id uuid,
  last_started_at timestamptz, last_finished_at timestamptz, last_status text, last_error text, last_counts jsonb,
  last_succeeded_at timestamptz, last_failed_at timestamptz, last_failed_error text,
  runs_24h integer, failed_24h integer)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    with runs as (
      select r.id, r.job, r.connection_id, r.started_at, r.finished_at, r.status, r.error, r.counts
      from cma.sync_run r
      where r.tenant_id = cma.current_tenant_id() and r.started_at > now() - interval '30 days'),
    last as (
      select distinct on (r.job, r.connection_id) r.job, r.connection_id, r.started_at, r.finished_at, r.status, r.error, r.counts
      from runs r order by r.job, r.connection_id, r.started_at desc, r.id desc),
    ok as (
      select r.job, r.connection_id, max(r.finished_at) as at from runs r where r.status = 'succeeded' group by 1, 2),
    bad as (
      select distinct on (r.job, r.connection_id) r.job, r.connection_id, r.finished_at, r.error
      from runs r where r.status = 'failed' order by r.job, r.connection_id, r.finished_at desc, r.id desc),
    day as (
      select r.job, r.connection_id, count(*)::integer as runs, (count(*) filter (where r.status = 'failed'))::integer as failed
      from runs r where r.started_at > now() - interval '24 hours' group by 1, 2)
    select l.job, l.connection_id, l.started_at, l.finished_at, l.status, l.error, l.counts,
           ok.at, bad.finished_at, bad.error, coalesce(day.runs, 0), coalesce(day.failed, 0)
    from last l
    left join ok  on ok.job = l.job  and ok.connection_id  is not distinct from l.connection_id
    left join bad on bad.job = l.job and bad.connection_id is not distinct from l.connection_id
    left join day on day.job = l.job and day.connection_id is not distinct from l.connection_id
    order by l.job, l.connection_id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.scheduler_run_start()',
    'cma.scheduler_run_finish(uuid, text, integer, text)',
    'cma.system_health_runs()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008r', 'System health: the heartbeat thresholds and the two document links as tenant settings, the scheduler''s close on the sync_run list with its own start and finish, sync_run summed per job and connection for Configuration → System health, an index on the tenant''s runs by time')
on conflict (version) do nothing;

commit;
reset role;
