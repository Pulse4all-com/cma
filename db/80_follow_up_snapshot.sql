-- =============================================================================================
-- 80_follow_up_snapshot.sql: addition 0008s, the follow-up snapshot (Reports → Follow-up, the Live
-- board's card and Welcome's Waiting for you read figures computed once per minute per tenant)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 78_system_health.sql (0008r). Rerunnable, forward-only, in one transaction with a lock timeout. Run as
-- your own IAM login, dev first, then prod; then 81_verify_follow_up_snapshot.sql (dev), then
-- 73_verify_follow_up.sql (dev; since 0008s it refreshes the snapshot after the two changes it makes, its
-- checks are the same) and 79_verify_system_health.sql (dev, unchanged: the settings trigger and sync_run's
-- job list grew) again. The web on main runs unchanged on it (the same shapes; it ignores computed_at), but
-- reads the snapshot, which nothing refreshes until the job runs: the job's script ships in the web image,
-- so run this in prod just before the web merge, then deploy the refresh job with the merge's image
-- (docs/scheduler/deploy-follow-up.sh) in dev and prod and run it once (docs/RUNBOOK.md, 7a).
--
-- IT audit of 17 October 2026, 5.6 continued (README Decision log, 18 October 2026, Martin): measured in
-- prod on 1ead2c3, /reports/follow-up refreshed every 10 seconds at 5.2 to 6.6 s, 7.8 to 9.7 s of database
-- time over its parallel reads and an RSC payload of about 1,044 kB. The page read cma.open_leads(),
-- open_tickets() and open_tasks() in full plus cma.follow_up_by_owner(), which built the three sets again;
-- the Live board's card (follow_up_summary) and Welcome's Waiting for you (my_follow_up) built them too.
-- Now one refresh per minute per tenant evaluates each set once and keeps the result: the figures are at
-- most about a minute old and say when they were computed; the counts stay complete; the lists show the
-- first follow_up.list_rows rows after their filters. No lookback bound on overdue tasks (it would change
-- the KPI's meaning; an option for Kira).
--
-- What it adds
--   setting               follow_up.list_rows (100; 1 to 500): the rows each list shows after its
--                         filters; cma.check_tenant_setting() checks it (0008r's branches unchanged)
--   permission            follow_up.refresh: the scheduler's system user only (no default role), granted
--                         to every tenant's scheduler role here and by cma.ensure_scheduler_user() from now on
--   sync_run              the job refresh_follow_up joins the list, without a connection like
--                         close_forgotten_workdays; cma.job_run_start(job) and cma.job_run_finish(run,
--                         status, counts, error) write a scheduler job's row (each job's own permission)
--   cma.follow_up_snapshot  one row per tenant: computed_at, duration_ms, the summary (the eight counts)
--                         and the figures per person (ids and counts; names are joined when read)
--   cma.follow_up_item    one row per open lead, ticket and task of the latest refresh: the kind, the
--                         order of the live function (sort_key), the filter columns (market, 'unknown'
--                         when none; the owner as a person; the state) and the row type's fields as JSON
--   cma.refresh_follow_up_of(tenant, wait)   evaluates open_leads_of, open_tickets_of and open_tasks_of
--                         once each and replaces the tenant's items and snapshot in the caller's
--                         transaction; a transaction-level advisory lock per tenant, so a second refresh
--                         running at the same time skips (wait: it waits instead, for the fallback);
--                         the current tenant only
--   cma.refresh_follow_up()  the job's entry (follow_up.refresh): refreshes the current tenant
--   reads                 cma.follow_up_page(market, person, show, rows): the page in one call (the
--                         summary, the figures per person for performance.team only, the filter choices,
--                         per list the first rows after the filters with the filtered total, the two
--                         settings the hints name, computed_at); cma.follow_up_summary() and
--                         cma.my_follow_up() read the snapshot, the same shapes plus computed_at;
--                         cma.open_leads(), open_tickets(), open_tasks() and follow_up_by_owner() read it
--                         too, the same rows (every row, no cap); cma.follow_up_computed_at() for the API
--   fallback              a read that finds no snapshot for its tenant computes it once on demand (the
--                         same function, waiting for a refresh in flight), so a new tenant or a missed job
--                         never shows an empty page
-- 0008o's reads of an explicit tenant (cma.open_leads_of and the rest) stay as they are: the refresh and
-- the readers' views (cma_read.open_lead and the rest) use them, and so does the verify.
--
-- The two tables are derived and rewritten every minute: they get row-level security and the grants of
-- cma.setup_tenant_table() but no audit trigger (cma.audit_log would gain a row image per item per minute,
-- about 6,000 rows a minute for a tenant with 3,000 open items). Each refresh leaves its sync_run row
-- (audited) and the snapshot's computed_at and duration_ms; the facts it is computed from keep theirs.
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
set local lock_timeout = '5s';
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008r') then
    raise exception 'addition 0008r (78_system_health.sql) must run before 0008s';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The rows a list shows, as a tenant setting
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('follow_up.list_rows', 'integer', null, '100',
     'The rows each list on Reports → Follow-up shows after its filters, 1 to 500; the counts and each list''s total stay complete')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- 0008r's checks, and follow_up.list_rows
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
  -- the follow-up snapshot (0008s): the rows each list of Reports → Follow-up shows
  elsif new.key = 'follow_up.list_rows'
        and (case when length(new.value) > 3 then true else new.value::integer not between 1 and 500 end) then
    raise exception 'Setting % takes a whole number of rows from 1 to 500', new.key using errcode = 'CMA04';
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The refresh's permission: the scheduler's system user, in every tenant
-- ---------------------------------------------------------------------------------------------
insert into cma.permission (key, description) values
  ('follow_up.refresh', 'Recompute the follow-up snapshot once a minute (the scheduler''s system user only; no default role)')
on conflict (key) do update set description = excluded.description;

-- 0005a's scheduler user, now with both of its permissions
create or replace function cma.ensure_scheduler_user(p_tenant_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_role uuid;
  v_user uuid;
begin
  insert into cma.app_role (tenant_id, key, name, is_system, is_assignable)
  values (p_tenant_id, 'scheduler', 'Scheduler', true, false)
  on conflict (tenant_id, key) do update set is_assignable = false, is_system = true
  returning id into v_role;
  if v_role is null then
    select id into v_role from cma.app_role where tenant_id = p_tenant_id and key = 'scheduler';
  end if;
  insert into cma.role_permission (tenant_id, role_id, permission_key)
  values (p_tenant_id, v_role, 'workday.close_forgotten'), (p_tenant_id, v_role, 'follow_up.refresh')
  on conflict do nothing;

  insert into cma.app_user (tenant_id, email, display_name, status, kind)
  values (p_tenant_id, 'scheduler@system.invalid', 'Scheduler', 'active', 'system')
  on conflict (tenant_id, email) do update set kind = 'system', status = 'active'
  returning id into v_user;
  if v_user is null then
    select id into v_user from cma.app_user where tenant_id = p_tenant_id and email = 'scheduler@system.invalid';
  end if;
  insert into cma.user_role (tenant_id, user_id, role_id)
  values (p_tenant_id, v_user, v_role)
  on conflict do nothing;
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
  values (p_tenant_id, v_user, 'scheduler', 'scheduler')
  on conflict do nothing;
  return v_user;
end
$$;
revoke execute on function cma.ensure_scheduler_user(uuid) from public;

do $$
declare
  t record;
begin
  for t in select id from cma.tenant loop
    perform cma.ensure_scheduler_user(t.id);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. sync_run: the refresh joins the list, without a connection; a scheduler job's own row
-- ---------------------------------------------------------------------------------------------
-- Not valid first, then validated: the check scans the table under a lighter lock than adding it valid
alter table cma.sync_run drop constraint if exists sync_run_job_check;
alter table cma.sync_run add constraint sync_run_job_check
  check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls', 'email_poll', 'close_forgotten_workdays',
                 'refresh_follow_up')) not valid;
alter table cma.sync_run validate constraint sync_run_job_check;
alter table cma.sync_run drop constraint if exists sync_run_connection_check;
alter table cma.sync_run add constraint sync_run_connection_check
  check ((connection_id is null) = (job in ('close_forgotten_workdays', 'refresh_follow_up'))) not valid;
alter table cma.sync_run validate constraint sync_run_connection_check;

-- The permission each scheduler job's row needs: the job's own (0008r's scheduler_run_start and _finish stay
-- for the forgotten-day close, unchanged)
create or replace function cma.job_permission_of(p_job text)
returns text
language sql immutable
as $$
  select case p_job when 'close_forgotten_workdays' then 'workday.close_forgotten' when 'refresh_follow_up' then 'follow_up.refresh' end
$$;

-- One running row for a scheduler job (no connection), in a transaction of its own before the work, so work
-- that fails still leaves a failed row; returns its id. The wall clock, as 0008r's start
create or replace function cma.job_run_start(p_job text)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  if cma.job_permission_of(p_job) is null then
    raise exception 'job must be close_forgotten_workdays or refresh_follow_up' using errcode = 'CMA04';
  end if;
  perform cma.assert_permission(cma.job_permission_of(p_job));
  insert into cma.sync_run (tenant_id, connection_id, job, stream, from_at, to_at, started_at)
  values (cma.current_tenant_id(), null, p_job, null, clock_timestamp(), clock_timestamp(), clock_timestamp())
  returning id into v_id;
  return v_id;
end
$$;

-- Ends that row once: succeeded or failed, with counts (an object of whole numbers and true or false) and an
-- error code of at most 200 characters; CMA02 for an unknown row, CMA03 for a finished one, CMA04 for a bad value
create or replace function cma.job_run_finish(p_run_id uuid, p_status text, p_counts jsonb, p_error text default null)
returns void
language plpgsql
as $$
declare
  v_job    text;
  v_status text;
begin
  if p_status is null or p_status not in ('succeeded', 'failed') then
    raise exception 'status must be succeeded or failed' using errcode = 'CMA04';
  end if;
  if p_counts is null or jsonb_typeof(p_counts) <> 'object'
     or exists (select 1 from jsonb_each(p_counts) e where jsonb_typeof(e.value) not in ('number', 'boolean')) then
    raise exception 'counts is an object of numbers' using errcode = 'CMA04';
  end if;
  select r.job, r.status into v_job, v_status from cma.sync_run r
  where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id and r.connection_id is null for update;
  if v_job is null then
    raise exception 'no scheduler run % in the current tenant', p_run_id using errcode = 'CMA02';
  end if;
  perform cma.assert_permission(cma.job_permission_of(v_job));
  if v_status <> 'running' then
    raise exception 'scheduler run % is already finished', p_run_id using errcode = 'CMA03';
  end if;
  update cma.sync_run r
     set status = p_status, finished_at = clock_timestamp(), counts = p_counts, error = left(nullif(btrim(p_error), ''), 200)
   where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The snapshot and its items
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.follow_up_snapshot (
  tenant_id    uuid primary key default cma.current_tenant_id() references cma.tenant (id),
  computed_at  timestamptz not null,
  duration_ms  integer not null check (duration_ms >= 0),
  summary      jsonb not null check (jsonb_typeof(summary) = 'object'),
  by_owner     jsonb not null check (jsonb_typeof(by_owner) = 'array')
);
comment on table cma.follow_up_snapshot is 'The follow-up figures of one tenant as its latest refresh computed them (addition 0008s): the eight counts and per person (ids and counts). Derived: rewritten once a minute, not audited';

create table if not exists cma.follow_up_item (
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  kind           text not null check (kind in ('lead', 'ticket', 'task')),
  sort_key       integer not null check (sort_key >= 1),
  item_id        uuid not null,
  market         text not null check (length(market) between 1 and 40),
  owner_user_id  uuid,
  state          text not null check (state in ('past_target', 'within_target', 'no_hours', 'ok', 'at_risk', 'breached', 'overdue', 'today', 'later', 'none')),
  row            jsonb not null check (jsonb_typeof(row) = 'object'),
  primary key (tenant_id, kind, sort_key),
  unique (tenant_id, kind, item_id),
  foreign key (tenant_id, owner_user_id) references cma.app_user (tenant_id, id)
);
comment on table cma.follow_up_item is 'The open leads, tickets and tasks of one tenant as its latest refresh computed them (addition 0008s), in the live functions'' order, with the filter columns and the row as JSON (ids, codes, counts; never customer data). Derived: rewritten once a minute, not audited';
comment on column cma.follow_up_item.market is 'The row''s market code, unknown when it has none: the value the market filter compares';
comment on column cma.follow_up_item.state is 'A lead: past_target, within_target or no_hours; a ticket: its SLA state; a task: its due state';
create index if not exists follow_up_item_market_idx on cma.follow_up_item (tenant_id, kind, market, sort_key);
create index if not exists follow_up_item_owner_idx on cma.follow_up_item (tenant_id, kind, owner_user_id, sort_key);
create index if not exists follow_up_item_state_idx on cma.follow_up_item (tenant_id, kind, state, sort_key);

select cma.setup_tenant_table('cma.follow_up_snapshot');
select cma.setup_tenant_table('cma.follow_up_item');
-- Derived tables rewritten every minute: no audit trigger (see the header)
drop trigger if exists audit on cma.follow_up_snapshot;
drop trigger if exists audit on cma.follow_up_item;

-- ---------------------------------------------------------------------------------------------
-- 5. The refresh
-- ---------------------------------------------------------------------------------------------
-- The advisory lock key of a tenant's refresh
create or replace function cma.follow_up_lock_key(p_tenant_id uuid)
returns bigint
language sql immutable
as $$
  select hashtextextended(p_tenant_id::text || '/follow_up_snapshot', 0)
$$;

-- The attention states of the three kinds, as Reports → Follow-up's state filter means them
create or replace function cma.follow_up_attention(p_state text)
returns boolean
language sql immutable
as $$
  select p_state in ('past_target', 'at_risk', 'breached', 'overdue')
$$;

-- Evaluates each live set once (0008o's reads of an explicit tenant, in their own order) and replaces the
-- tenant's items and snapshot, in the caller's transaction. A second refresh of the same tenant while one
-- runs skips (answers refreshed false, reason running); with p_wait it waits for it instead and then skips
-- when a snapshot has appeared meanwhile (reason present), which is what a read that found none wants.
-- computed_at is the transaction's time, the instant the live functions measured ages and states against.
-- The current tenant only (CMA06): the reads and the writes are row-level security's.
create or replace function cma.refresh_follow_up_of(p_tenant_id uuid, p_wait boolean default false)
returns jsonb
language plpgsql
as $$
declare
  v_t0      timestamptz := clock_timestamp();
  v_leads   integer;
  v_tickets integer;
  v_tasks   integer;
  v_ms      integer;
  v_summary jsonb;
  v_owners  jsonb;
begin
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'the follow-up snapshot is refreshed for the current tenant only' using errcode = 'CMA06';
  end if;
  if coalesce(p_wait, false) then
    perform pg_advisory_xact_lock(cma.follow_up_lock_key(p_tenant_id));
    if exists (select 1 from cma.follow_up_snapshot s where s.tenant_id = p_tenant_id) then
      return jsonb_build_object('refreshed', false, 'reason', 'present');
    end if;
  elsif not pg_try_advisory_xact_lock(cma.follow_up_lock_key(p_tenant_id)) then
    return jsonb_build_object('refreshed', false, 'reason', 'running');
  end if;

  delete from cma.follow_up_item i where i.tenant_id = p_tenant_id;
  insert into cma.follow_up_item (tenant_id, kind, sort_key, item_id, market, owner_user_id, state, row)
  select p_tenant_id, 'lead', o.ordinality, o.deal_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id,
         case when o.past_target then 'past_target' when o.past_target is false then 'within_target' else 'no_hours' end,
         to_jsonb(o) - 'tenant_id' - 'ordinality'
  from cma.open_leads_of(p_tenant_id) with ordinality o;
  get diagnostics v_leads = row_count;
  insert into cma.follow_up_item (tenant_id, kind, sort_key, item_id, market, owner_user_id, state, row)
  select p_tenant_id, 'ticket', o.ordinality, o.ticket_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.sla_state,
         to_jsonb(o) - 'tenant_id' - 'ordinality'
  from cma.open_tickets_of(p_tenant_id) with ordinality o;
  get diagnostics v_tickets = row_count;
  insert into cma.follow_up_item (tenant_id, kind, sort_key, item_id, market, owner_user_id, state, row)
  select p_tenant_id, 'task', o.ordinality, o.task_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.due_state,
         to_jsonb(o) - 'tenant_id' - 'ordinality'
  from cma.open_tasks_of(p_tenant_id) with ordinality o;
  get diagnostics v_tasks = row_count;

  -- The counts and the figures per person from the items just written, as follow_up_summary_of and
  -- follow_up_by_owner_of compute them from the live sets (a person with only later tasks has a row of zeros)
  select jsonb_build_object(
           'leads_open_not_called', count(*) filter (where i.kind = 'lead'),
           'leads_past_target', count(*) filter (where i.kind = 'lead' and i.state = 'past_target'),
           'tickets_at_risk', count(*) filter (where i.kind = 'ticket' and i.state = 'at_risk'),
           'tickets_breached', count(*) filter (where i.kind = 'ticket' and i.state = 'breached'),
           'tickets_without_owner', count(*) filter (where i.kind = 'ticket' and i.row ->> 'owner_ref' is null),
           'tasks_overdue', count(*) filter (where i.kind = 'task' and i.state = 'overdue'),
           'tasks_due_today', count(*) filter (where i.kind = 'task' and i.state = 'today'),
           'tasks_unmapped_owner', count(*) filter (where i.kind = 'task' and i.row ->> 'owner_ref' is not null and i.owner_user_id is null))
    into v_summary
  from cma.follow_up_item i where i.tenant_id = p_tenant_id;
  select coalesce(jsonb_agg(jsonb_build_object(
           'owner_user_id', g.uid, 'open_leads', g.leads, 'leads_past_target', g.past, 'open_tickets', g.tickets,
           'tickets_at_risk_or_breached', g.risk, 'tasks_overdue', g.overdue, 'tasks_due_today', g.today) order by g.uid nulls last), '[]'::jsonb)
    into v_owners
  from (select i.owner_user_id as uid,
               count(*) filter (where i.kind = 'lead') as leads,
               count(*) filter (where i.kind = 'lead' and i.state = 'past_target') as past,
               count(*) filter (where i.kind = 'ticket') as tickets,
               count(*) filter (where i.kind = 'ticket' and i.state in ('at_risk', 'breached')) as risk,
               count(*) filter (where i.kind = 'task' and i.state = 'overdue') as overdue,
               count(*) filter (where i.kind = 'task' and i.state = 'today') as today
        from cma.follow_up_item i where i.tenant_id = p_tenant_id
        group by i.owner_user_id) g;

  v_ms := floor(extract(epoch from clock_timestamp() - v_t0) * 1000)::integer;
  insert into cma.follow_up_snapshot (tenant_id, computed_at, duration_ms, summary, by_owner)
  values (p_tenant_id, now(), v_ms, v_summary, v_owners)
  on conflict (tenant_id) do update
    set computed_at = excluded.computed_at, duration_ms = excluded.duration_ms, summary = excluded.summary, by_owner = excluded.by_owner;
  return jsonb_build_object('refreshed', true, 'leads', v_leads, 'tickets', v_tickets, 'tasks', v_tasks,
                            'rows', v_leads + v_tickets + v_tasks, 'duration_ms', v_ms, 'computed_at', now());
end
$$;

-- The job's entry: the current tenant, for the scheduler's system user
create or replace function cma.refresh_follow_up()
returns jsonb
language plpgsql
as $$
begin
  perform cma.assert_permission('follow_up.refresh');
  return cma.refresh_follow_up_of(cma.current_tenant_id());
end
$$;

-- The tenant's snapshot; computed once on demand when there is none yet (a new tenant, a missed job)
create or replace function cma.follow_up_snapshot_of(p_tenant_id uuid)
returns cma.follow_up_snapshot
language plpgsql
as $$
declare
  s cma.follow_up_snapshot;
begin
  select * into s from cma.follow_up_snapshot x where x.tenant_id = p_tenant_id;
  if not found then
    perform cma.refresh_follow_up_of(p_tenant_id, true);
    select * into s from cma.follow_up_snapshot x where x.tenant_id = p_tenant_id;
  end if;
  return s;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Reading the snapshot
-- ---------------------------------------------------------------------------------------------
-- One list of a tenant's items after the filters: its total and the first p_rows (every row when null) in
-- the live order, each with the owner's name (app_user, this tenant) and the record link
create or replace function cma.follow_up_list_of(p_tenant_id uuid, p_kind text, p_market text, p_owner uuid, p_unowned boolean,
                                                 p_attention boolean, p_rows integer)
returns jsonb
language sql stable
as $$
  with f as (
    select i.sort_key, i.owner_user_id, i.row
    from cma.follow_up_item i
    where i.tenant_id = p_tenant_id and i.kind = p_kind
      and (p_market is null or i.market = p_market)
      and (p_owner is null or i.owner_user_id = p_owner)
      and (not coalesce(p_unowned, false) or i.owner_user_id is null)
      and (not coalesce(p_attention, false) or cma.follow_up_attention(i.state))
  ),
  shown as (
    select f.sort_key, f.owner_user_id, f.row from f order by f.sort_key limit p_rows
  )
  select jsonb_build_object(
    'total', (select count(*) from f),
    'rows', coalesce((
      select jsonb_agg(s.row || jsonb_build_object(
               'owner_name', u.display_name,
               'record_url', cma.record_url((s.row ->> 'connection_id')::uuid,
                                            case p_kind when 'lead' then 'deal' else p_kind end,
                                            s.row ->> case p_kind when 'lead' then 'deal_source_id' when 'ticket' then 'ticket_source_id' else 'task_source_id' end))
             order by s.sort_key)
      from shown s
      left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = s.owner_user_id), '[]'::jsonb))
$$;

-- The figures per person of a snapshot with the names, by name, the not-linked row last (follow_up_by_owner_of's order)
create or replace function cma.follow_up_owners_of(p_tenant_id uuid, p_by_owner jsonb)
returns setof cma.follow_up_owner_row
language sql stable
as $$
  select p_tenant_id, (o ->> 'owner_user_id')::uuid, u.display_name,
         (o ->> 'open_leads')::integer, (o ->> 'leads_past_target')::integer, (o ->> 'open_tickets')::integer,
         (o ->> 'tickets_at_risk_or_breached')::integer, (o ->> 'tasks_overdue')::integer, (o ->> 'tasks_due_today')::integer
  from jsonb_array_elements(p_by_owner) o
  left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = (o ->> 'owner_user_id')::uuid
  order by case when o ->> 'owner_user_id' is null then 1 else 0 end, u.display_name, (o ->> 'owner_user_id')::uuid
$$;

-- Reports → Follow-up in one call (reports.view, performance.team or monitoring.live): the summary (every
-- item), the figures per person for performance.team only, the filter choices (from every item, so a choice
-- never disappears while it is made), every row per list before the filters (counts), the three lists after
-- the filters (market: a code or unknown; person: a person's id or none; show: attention) with their totals
-- and their first p_rows rows (the tenant's follow_up.list_rows when null; 1 to 500), the two settings the
-- hints name, and when it was computed
create or replace function cma.follow_up_page(p_market text default null, p_person text default null, p_show text default null,
                                              p_rows integer default null)
returns jsonb
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_user    uuid;
  v_owner   uuid;
  v_unowned boolean := false;
  v_rows    integer;
  s         cma.follow_up_snapshot;
begin
  v_user := cma.assert_any_permission(array['reports.view', 'performance.team', 'monitoring.live']);
  if p_market is not null and p_market !~ '^[A-Za-z0-9_-]{1,20}$' then
    raise exception 'market is a market code or unknown' using errcode = 'CMA04';
  end if;
  if p_person = 'none' then
    v_unowned := true;
  elsif p_person ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_owner := p_person::uuid;
  elsif p_person is not null then
    raise exception 'person is a person''s id or none' using errcode = 'CMA04';
  end if;
  if p_show is not null and p_show <> 'attention' then
    raise exception 'show is attention or nothing' using errcode = 'CMA04';
  end if;
  v_rows := least(500, greatest(1, coalesce(p_rows, cma.setting_of(v_tenant, 'follow_up.list_rows')::integer)));
  s := cma.follow_up_snapshot_of(v_tenant);
  return jsonb_build_object(
    'computed_at', s.computed_at,
    'duration_ms', s.duration_ms,
    'rows', v_rows,
    'summary', s.summary,
    'by_owner', case when cma.has_permission(v_user, 'performance.team')
                     then coalesce((select jsonb_agg(jsonb_build_object(
                              'owner_user_id', o.owner_user_id, 'display_name', o.display_name, 'open_leads', o.open_leads,
                              'leads_past_target', o.leads_past_target, 'open_tickets', o.open_tickets,
                              'tickets_at_risk_or_breached', o.tickets_at_risk_or_breached, 'tasks_overdue', o.tasks_overdue,
                              'tasks_due_today', o.tasks_due_today))
                            from cma.follow_up_owners_of(v_tenant, s.by_owner) o), '[]'::jsonb) end,
    'options', jsonb_build_object(
      'markets', coalesce((select jsonb_agg(m.market order by m.market = 'unknown', m.market)
                           from (select distinct i.market from cma.follow_up_item i where i.tenant_id = v_tenant) m), '[]'::jsonb),
      'owners', coalesce((select jsonb_agg(jsonb_build_object('id', p.owner_user_id, 'name', p.display_name)
                                           order by coalesce(p.display_name, ''), p.owner_user_id)
                          from (select distinct i.owner_user_id, u.display_name
                                from cma.follow_up_item i
                                left join cma.app_user u on u.tenant_id = v_tenant and u.id = i.owner_user_id
                                where i.tenant_id = v_tenant and i.owner_user_id is not null) p), '[]'::jsonb),
      'has_unowned', exists (select 1 from cma.follow_up_item i where i.tenant_id = v_tenant and i.owner_user_id is null)),
    'counts', coalesce((select jsonb_object_agg(k.kind, k.n)
                        from (select i.kind, count(*) as n from cma.follow_up_item i where i.tenant_id = v_tenant group by i.kind) k), '{}'::jsonb),
    'settings', jsonb_build_object(
      'target_minutes', cma.setting_of(v_tenant, 'speed_to_lead.target_minutes'),
      'warning_pct', cma.setting_of(v_tenant, 'tickets.sla_warning_pct'),
      'list_rows', cma.setting_of(v_tenant, 'follow_up.list_rows')),
    'leads', cma.follow_up_list_of(v_tenant, 'lead', p_market, v_owner, v_unowned, p_show = 'attention', v_rows),
    'tickets', cma.follow_up_list_of(v_tenant, 'ticket', p_market, v_owner, v_unowned, p_show = 'attention', v_rows),
    'tasks', cma.follow_up_list_of(v_tenant, 'task', p_market, v_owner, v_unowned, p_show = 'attention', v_rows));
end
$$;

-- When the figures were computed (any follow-up read's permission; computed on demand when there are none yet)
create or replace function cma.follow_up_computed_at()
returns timestamptz
language plpgsql
as $$
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team', 'monitoring.live', 'workday.team', 'leads.accept', 'workday.own']);
  return (cma.follow_up_snapshot_of(cma.current_tenant_id())).computed_at;
end
$$;

-- 0008o's application reads, now from the snapshot: the same permissions, the same rows in the same order
create or replace function cma.open_leads()
returns setof cma.open_lead_row
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team', 'monitoring.live']);
  perform cma.follow_up_snapshot_of(v_tenant);
  return query select (jsonb_populate_record(null::cma.open_lead_row, i.row || jsonb_build_object('tenant_id', i.tenant_id))).*
               from cma.follow_up_item i where i.tenant_id = v_tenant and i.kind = 'lead' order by i.sort_key;
end
$$;

create or replace function cma.open_tickets()
returns setof cma.open_ticket_row
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team', 'monitoring.live']);
  perform cma.follow_up_snapshot_of(v_tenant);
  return query select (jsonb_populate_record(null::cma.open_ticket_row, i.row || jsonb_build_object('tenant_id', i.tenant_id))).*
               from cma.follow_up_item i where i.tenant_id = v_tenant and i.kind = 'ticket' order by i.sort_key;
end
$$;

create or replace function cma.open_tasks()
returns setof cma.open_task_row
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team', 'monitoring.live']);
  perform cma.follow_up_snapshot_of(v_tenant);
  return query select (jsonb_populate_record(null::cma.open_task_row, i.row || jsonb_build_object('tenant_id', i.tenant_id))).*
               from cma.follow_up_item i where i.tenant_id = v_tenant and i.kind = 'task' order by i.sort_key;
end
$$;

-- The counts, plus when they were computed (a new column at the end: the function is dropped and created again)
drop function if exists cma.follow_up_summary();
create function cma.follow_up_summary()
returns table(tenant_id uuid, leads_open_not_called integer, leads_past_target integer, tickets_at_risk integer, tickets_breached integer,
              tickets_without_owner integer, tasks_overdue integer, tasks_due_today integer, tasks_unmapped_owner integer, computed_at timestamptz)
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  s        cma.follow_up_snapshot;
begin
  perform cma.assert_any_permission(array['monitoring.live', 'performance.team', 'workday.team']);
  s := cma.follow_up_snapshot_of(v_tenant);
  return query select v_tenant, (s.summary ->> 'leads_open_not_called')::integer, (s.summary ->> 'leads_past_target')::integer,
                      (s.summary ->> 'tickets_at_risk')::integer, (s.summary ->> 'tickets_breached')::integer,
                      (s.summary ->> 'tickets_without_owner')::integer, (s.summary ->> 'tasks_overdue')::integer,
                      (s.summary ->> 'tasks_due_today')::integer, (s.summary ->> 'tasks_unmapped_owner')::integer, s.computed_at;
end
$$;

-- Per-person figures sit under the employee-monitoring point with Yordi, like Calls per agent: performance.team only
create or replace function cma.follow_up_by_owner()
returns setof cma.follow_up_owner_row
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('performance.team');
  return query select * from cma.follow_up_owners_of(v_tenant, (cma.follow_up_snapshot_of(v_tenant)).by_owner);
end
$$;

-- The caller's own rows (owner mapped to the caller), every row with its record link, plus when they were computed
create or replace function cma.my_follow_up()
returns jsonb
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid := cma.current_user_id();
  s        cma.follow_up_snapshot;
begin
  perform cma.assert_any_permission(array['leads.accept', 'workday.own']);
  if v_user is null then
    raise exception 'no acting user' using errcode = 'CMA01';
  end if;
  s := cma.follow_up_snapshot_of(v_tenant);
  return jsonb_build_object(
    'leads', cma.follow_up_list_of(v_tenant, 'lead', null, v_user, false, false, null) -> 'rows',
    'tickets', cma.follow_up_list_of(v_tenant, 'ticket', null, v_user, false, false, null) -> 'rows',
    'tasks', cma.follow_up_list_of(v_tenant, 'task', null, v_user, false, false, null) -> 'rows',
    'computed_at', s.computed_at);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.job_permission_of(text)', 'cma.job_run_start(text)', 'cma.job_run_finish(uuid,text,jsonb,text)',
    'cma.follow_up_lock_key(uuid)', 'cma.follow_up_attention(text)',
    'cma.refresh_follow_up_of(uuid,boolean)', 'cma.refresh_follow_up()', 'cma.follow_up_snapshot_of(uuid)',
    'cma.follow_up_list_of(uuid,text,text,uuid,boolean,boolean,integer)', 'cma.follow_up_owners_of(uuid,jsonb)',
    'cma.follow_up_page(text,text,text,integer)', 'cma.follow_up_computed_at()',
    'cma.open_leads()', 'cma.open_tickets()', 'cma.open_tasks()',
    'cma.follow_up_summary()', 'cma.follow_up_by_owner()', 'cma.my_follow_up()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008s', 'The follow-up snapshot: follow_up_snapshot and follow_up_item per tenant, refreshed once a minute by the scheduler''s refresh job (follow_up.refresh, its sync_run row through job_run_start and job_run_finish) or once on demand when a tenant has none, an advisory lock per tenant; Reports → Follow-up in one read with the lists capped at follow_up.list_rows; the summary, the person''s own rows and 0008o''s list reads from the snapshot with computed_at')
on conflict (version) do nothing;

commit;
reset role;
