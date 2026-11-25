-- =============================================================================================
-- 240_audit_and_retention.sql: addition 0009zt, the ingest's source writes out of the audit log (D12) and the run rows'
-- retention (D13) (brief N07, WP10; PR N07f)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics; the retention is two settings. Runs unchanged in every database,
-- after 238_email_not_responding_speed.sql (0009zs). Rerunnable, forward-only, in one transaction with a lock timeout.
-- D12 agreed by Yordi on 25 November 2026 (Martin); this has not run in prod yet, and runs in prod after
-- 244 (0009zv). Run as your own IAM login: dev first, then 241_verify_audit_and_retention.sql there (normal and provoked),
-- then the verifies that read what this re-creates, each still PASS and none edited: 77, 107, 113, 169 and 195 (they read
-- cma.audit_row: the audit trigger and its bookkeeping), 197 (cma.sync_run_hour_count and the hourly counts). Then the ingest's image with the reconcile's purge (ingest/src/jobs/reconcile.mjs) and the first purge
-- (the morning runbook: a Terminal step outside office hours).
--
-- Why (Martin, 24 November 2026; brief N07, decisions D12 and D13, verbatim): "D12 Writes of the ingest to the mirrored
-- source tables (the crm_, commerce_, subscription and telephony mirrors and their kind, listed in the PR) are no longer
-- audited in audit_log: cma.ingest_event already records every source change. Writes by a person, and every configuration
-- table, stay audited. The prod run waits for Yordi's agreement (a heads-up line in docs/open-decisions.md; the morning
-- runbook says so); existing audit rows stay." "D13 sync_run retention: an ops setting sync_run.retention_days (90 by
-- default) for succeeded runs, failed runs kept 365 days, applied by the nightly reconcile in small batches with lock and
-- statement timeouts; cma.sync_run_hour keeps its counts (deleting a run must not change the hourly bookkeeping); the
-- first purge is a Terminal step outside office hours in the morning runbook." Yordi agreed to D12 as narrowed here on
-- 25 November 2026 (Martin), so the prod run no longer waits. Prod: audit_log 11.1 GB, about 100,000 rows
-- a day (crm_contact alone 210,341 updates); sync_run 487 MB.
--
-- What it changes
--   cma.audit_source_mirror_tables()  the mirrored source tables of D12 whose ingest writes leave no audit row:
--                crm_record_stage, commerce_order_line, subscription, subscription_event, subscription_line, billing_event,
--                email_thread, email_message, email_thread_event. Night default N07-6 (to confirm): D12's other mirrors
--                (crm_record, crm_contact, crm_contact_ref, crm_association, crm_call, crm_task, commerce_customer,
--                commerce_order, telephony_call, telephony_call_tag) are the follow-up's inputs (cma.follow_up_input_tables()),
--                whose change check reads their audit rows, and the email poll writes crm_contact and crm_association with
--                no ingest event; they stay audited until the follow-up reads write-time markers (NIGHT_NOTES, remainder 1).
--                Not in it either: every configuration table, the CMA's own derived rows (call_link, subscription_change),
--                the asset register
--   cma.audit_row (based on 168) returns before writing when the table is one of them and the writer is the ingest (its
--                actor label ingest:<adapter> and a system user); everything else as before
--   settings     sync_run.retention_days (integer, 90; 7 to 3650): how long a succeeded run row is kept;
--                sync_run.failed_retention_days (integer, 365; 30 to 3650): a failed one (D13), checked by
--                cma.check_sync_run_setting()
--   cma.sync_run_hour_count (based on 196) leaves the hourly counts as they are for a delete made by the purge
--   cma.sync_run_purge(integer, text, uuid) SECURITY DEFINER, owned by cma_owner, search path pinned: for the current
--                tenant and a system user only (the ingest's reconcile), deletes at most the given number of finished run
--                rows past their retention, oldest first, pair by pair (job and connection, read from cma.sync_run_hour;
--                or the one pair the two optional arguments name, as 241 does), never a
--                pair's 20 latest runs and never the latest succeeded run of a job, connection and stream (Sources' last
--                read and the latest run's figures read them). Answers {deleted, more}. The caller sets its lock and
--                statement timeouts per batch
-- =============================================================================================

begin;
set local lock_timeout = '5s';
set role cma_owner;


-- ---------------------------------------------------------------------------------------------
-- 1. D12: the mirrored source tables, and the audit trigger that leaves the ingest's writes to them out
-- ---------------------------------------------------------------------------------------------
create or replace function cma.audit_source_mirror_tables()
returns text[]
language sql immutable
as $$
  -- the mirrors D12 names, less the follow-up's inputs (cma.follow_up_input_tables()): its change check reads their
  -- audit rows, and the email poll writes crm_contact and crm_association without an ingest event (night default N07-6)
  select array['crm_record_stage', 'commerce_order_line',
               'subscription', 'subscription_event', 'subscription_line', 'billing_event',
               'email_thread', 'email_message', 'email_thread_event']
$$;

-- based on: 168_pledge_lists.sql
create or replace function cma.audit_row()
returns trigger
language plpgsql
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
begin
  -- 0009zt (D12): the ingest's writes to the mirrored source tables are not audited: cma.ingest_event records every source
  -- change already. A person's write, a job's, and every write to a configuration table stay audited
  if tg_table_schema = 'cma' and tg_table_name = any (cma.audit_source_mirror_tables())
     and coalesce(cma.current_actor_label(), '') like 'ingest:%'
     and (select u.kind from cma.app_user u where u.tenant_id = cma.current_tenant_id() and u.id = cma.current_user_id()) = 'system' then
    return null;
  end if;
  if tg_op = 'DELETE' and tg_table_schema = 'cma'
     and tg_table_name in ('telephony_call', 'telephony_call_tag', 'call_link')
     and coalesce(current_setting('cma.audit_keys_only', true), '') = 'uncounted_line' then
    v_old := jsonb_strip_nulls(jsonb_build_object(
      'id', v_old -> 'id', 'tenant_id', v_old -> 'tenant_id', 'connection_id', v_old -> 'connection_id',
      'source_id', v_old -> 'source_id', 'call_source_id', v_old -> 'call_source_id', 'tag_ref', v_old -> 'tag_ref',
      'telephony_call_id', v_old -> 'telephony_call_id', 'crm_call_id', v_old -> 'crm_call_id',
      'reason', 'uncounted_line'));
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'invitation' then
    v_old := v_old - 'token_hash';
    v_new := v_new - 'token_hash';
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'ingest_event' then
    v_old := v_old - 'raw';
    v_new := v_new - 'raw';
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'review' then
    v_old := cma.review_image_without_at_reference(v_old);
    v_new := cma.review_image_without_at_reference(v_new);
  end if;
  -- 0009j: a loan's lender label is an investor's name (D8): never in the log. Both images leave it out; a change of it
  -- is recorded as changed, never as its value
  if tg_table_schema = 'cma' and tg_table_name = 'pledge_loan' then
    if v_old is not null and v_new is not null then
      v_new := v_new || jsonb_build_object('lender_label_changed', (v_old ->> 'lender_label') is distinct from (v_new ->> 'lender_label'));
    end if;
    v_old := v_old - 'lender_label';
    v_new := v_new - 'lender_label';
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'device_import_row' then
    v_old := case when v_old is not null then jsonb_build_object('id', v_old -> 'id', 'tenant_id', v_old -> 'tenant_id',
                                                                 'batch_key', v_old -> 'batch_key', 'source_row', v_old -> 'source_row') end;
    v_new := case when v_new is not null then jsonb_build_object('id', v_new -> 'id', 'tenant_id', v_new -> 'tenant_id',
                                                                 'batch_key', v_new -> 'batch_key', 'source_row', v_new -> 'source_row') end;
  end if;
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  values (
    (coalesce(v_new, v_old) ->> 'tenant_id')::uuid,
    tg_table_name,
    lower(tg_op),
    v_old,
    v_new,
    cma.current_user_id(),
    cma.current_actor_label()
  );
  return null;   -- after trigger, return value is ignored
end
$$;


-- based on: 196_sync_run_reads.sql
create or replace function cma.sync_run_hour_count()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, cma, pg_temp
as $$
declare
  v_same boolean := tg_op = 'UPDATE' and old.tenant_id = new.tenant_id and old.job = new.job
                    and old.connection_id is not distinct from new.connection_id
                    and date_trunc('hour', old.started_at, 'UTC') = date_trunc('hour', new.started_at, 'UTC');
begin
  if v_same then
    -- the same hour: only a move into or out of failed counts
    if (old.status = 'failed') is distinct from (new.status = 'failed') then
      if new.connection_id is null then
        update cma.sync_run_hour h set failed = h.failed + case when new.status = 'failed' then 1 else -1 end
        where h.tenant_id = new.tenant_id and h.job = new.job and h.connection_id is null and h.hour = date_trunc('hour', new.started_at, 'UTC');
      else
        update cma.sync_run_hour h set failed = h.failed + case when new.status = 'failed' then 1 else -1 end
        where h.tenant_id = new.tenant_id and h.job = new.job and h.connection_id = new.connection_id
          and h.hour = date_trunc('hour', new.started_at, 'UTC');
      end if;
    end if;
    return null;
  end if;
  -- 0009zt (D13): a run the retention purges leaves the hourly counts as they are (cma.sync_run_purge sets the flag for
  -- its own transaction only)
  if tg_op = 'DELETE' and coalesce(current_setting('cma.sync_run_purge', true), '') = 'on' then
    return null;
  end if;
  if tg_op in ('UPDATE', 'DELETE') then
    if old.connection_id is null then
      update cma.sync_run_hour h set runs = h.runs - 1, failed = h.failed - case when old.status = 'failed' then 1 else 0 end
      where h.tenant_id = old.tenant_id and h.job = old.job and h.connection_id is null and h.hour = date_trunc('hour', old.started_at, 'UTC');
    else
      update cma.sync_run_hour h set runs = h.runs - 1, failed = h.failed - case when old.status = 'failed' then 1 else 0 end
      where h.tenant_id = old.tenant_id and h.job = old.job and h.connection_id = old.connection_id
        and h.hour = date_trunc('hour', old.started_at, 'UTC');
    end if;
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    insert into cma.sync_run_hour as h (tenant_id, job, connection_id, hour, runs, failed)
    values (new.tenant_id, new.job, new.connection_id, date_trunc('hour', new.started_at, 'UTC'), 1,
            case when new.status = 'failed' then 1 else 0 end)
    on conflict (tenant_id, job, connection_id, hour) do update
      set runs = h.runs + 1, failed = h.failed + excluded.failed;
  end if;
  return null;
end
$$;



-- ---------------------------------------------------------------------------------------------
-- 2. D13: the retention's settings, their ranges, and the purge
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('sync_run.retention_days', 'integer', null, '90',
     'How many days a succeeded run row of the jobs and polls is kept (7 to 3650); the nightly reconcile deletes older ones in small batches, never a job''s latest succeeded run or a pair''s 20 latest'),
  ('sync_run.failed_retention_days', 'integer', null, '365',
     'How many days a failed run row is kept (30 to 3650)')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

create or replace function cma.check_sync_run_setting()
returns trigger
language plpgsql
as $$
begin
  if new.key = 'sync_run.retention_days'
     and (case when new.value !~ '^[0-9]{1,4}$' then true else new.value::integer not between 7 and 3650 end) then
    raise exception 'Setting % takes a whole number of days from 7 to 3650', new.key using errcode = 'CMA04';
  end if;
  if new.key = 'sync_run.failed_retention_days'
     and (case when new.value !~ '^[0-9]{1,4}$' then true else new.value::integer not between 30 and 3650 end) then
    raise exception 'Setting % takes a whole number of days from 30 to 3650', new.key using errcode = 'CMA04';
  end if;
  return new;
end
$$;

drop function if exists cma.sync_run_purge(integer);
create or replace function cma.sync_run_purge(p_batch integer default 2000, p_job text default null, p_connection uuid default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_user    uuid := cma.current_user_id();
  v_days    integer;
  v_fdays   integer;
  v_left    integer := greatest(1, least(coalesce(p_batch, 2000), 20000));
  v_deleted integer := 0;
  n         integer;
  p         record;
  v_from    timestamptz;
begin
  if v_tenant is null or v_user is null then
    raise exception 'the purge needs the tenant and the acting user' using errcode = 'CMA01';
  end if;
  if (select u.kind from cma.app_user u where u.tenant_id = v_tenant and u.id = v_user and u.status = 'active') is distinct from 'system' then
    raise exception 'only a system user (the ingest''s reconcile) purges run rows' using errcode = 'CMA06';
  end if;
  v_days := cma.setting_of(v_tenant, 'sync_run.retention_days')::integer;
  v_fdays := cma.setting_of(v_tenant, 'sync_run.failed_retention_days')::integer;
  -- the hourly counts stay as they are for these deletes (cma.sync_run_hour_count); the flag is set back before the
  -- function returns, so no later delete of the caller's transaction is left out of the counts
  perform set_config('cma.sync_run_purge', 'on', true);
  -- pair by pair (job and connection, from the hourly counts), or the one pair asked for (the verify's)
  for p in
    select distinct h.job, h.connection_id from cma.sync_run_hour h
    where h.tenant_id = v_tenant and h.hour < now() - make_interval(days => least(v_days, v_fdays))
      and (p_job is null or h.job = p_job) and (p_connection is null or h.connection_id = p_connection)
    order by h.job, h.connection_id
  loop
    exit when v_left <= 0;
    if p.connection_id is null then
      -- the scheduler's jobs: no connection (sync_run_job_started_idx's connection_id is null range)
      select x.started_at into v_from from cma.sync_run x
      where x.tenant_id = v_tenant and x.job = p.job and x.connection_id is null
      order by x.started_at desc, x.id desc offset 19 limit 1;
      continue when v_from is null;
      with doomed as (
        select r.id from cma.sync_run r
        where r.tenant_id = v_tenant and r.job = p.job and r.connection_id is null and r.started_at < v_from
          and ((r.status = 'succeeded' and r.finished_at < now() - make_interval(days => v_days))
               or (r.status = 'failed' and r.finished_at < now() - make_interval(days => v_fdays)))
          and exists (select 1 from cma.sync_run s
                      where s.tenant_id = v_tenant and s.job = r.job and s.connection_id is null
                        and s.stream is not distinct from r.stream and s.status = 'succeeded' and s.started_at > r.started_at)
        order by r.started_at, r.id
        limit v_left
      )
      delete from cma.sync_run r using doomed d where r.id = d.id and r.tenant_id = v_tenant;
    else
      -- a connection's job: the pair's 20th latest run, then what lies before it (sync_run_job_started_idx)
      select x.started_at into v_from from cma.sync_run x
      where x.tenant_id = v_tenant and x.job = p.job and x.connection_id = p.connection_id
      order by x.started_at desc, x.id desc offset 19 limit 1;
      continue when v_from is null;
      with doomed as (
        select r.id from cma.sync_run r
        where r.tenant_id = v_tenant and r.job = p.job and r.connection_id = p.connection_id and r.started_at < v_from
          and ((r.status = 'succeeded' and r.finished_at < now() - make_interval(days => v_days))
               or (r.status = 'failed' and r.finished_at < now() - make_interval(days => v_fdays)))
          -- a newer succeeded run of the same job, connection and stream: this one is not the latest succeeded
          and exists (select 1 from cma.sync_run s
                      where s.tenant_id = v_tenant and s.job = r.job and s.connection_id = p.connection_id
                        and s.stream is not distinct from r.stream and s.status = 'succeeded' and s.started_at > r.started_at)
        order by r.started_at, r.id
        limit v_left
      )
      delete from cma.sync_run r using doomed d where r.id = d.id and r.tenant_id = v_tenant;
    end if;
    get diagnostics n = row_count;
    v_deleted := v_deleted + n;
    v_left := v_left - n;
  end loop;
  perform set_config('cma.sync_run_purge', '', true);
  return jsonb_build_object('deleted', v_deleted, 'more', v_left <= 0);
end
$$;
alter function cma.sync_run_purge(integer, text, uuid) owner to cma_owner;

-- ---------------------------------------------------------------------------------------------
-- 3. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array['cma.audit_source_mirror_tables()', 'cma.check_sync_run_setting()', 'cma.sync_run_purge(integer,text,uuid)'] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;
revoke execute on function cma.sync_run_hour_count() from public;

-- ---------------------------------------------------------------------------------------------
-- 4. Last, before the addition's row and the commit (CLAUDE.md, Performance): the trigger on cma.tenant_setting takes an
--    ACCESS EXCLUSIVE lock held to the commit; every settings read waits on it for this moment only
-- ---------------------------------------------------------------------------------------------
drop trigger if exists check_sync_run_setting on cma.tenant_setting;
create trigger check_sync_run_setting before insert or update on cma.tenant_setting
  for each row execute function cma.check_sync_run_setting();

-- ---------------------------------------------------------------------------------------------
-- 5. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zt', 'The ingest''s source writes out of the audit log and the run rows'' retention (Martin, 24 Nov 2026; brief N07, D12, D13): cma.audit_source_mirror_tables(); cma.audit_row skips the ingest''s writes (actor ingest:<adapter>, a system user) to those tables (the mirrors that are not the follow-up''s inputs); settings sync_run.retention_days (90) and sync_run.failed_retention_days (365), checked by cma.check_sync_run_setting(); cma.sync_run_purge(integer, text, uuid) (SECURITY DEFINER, a system user, batches, never a pair''s 20 latest or a stream''s latest succeeded run) and cma.sync_run_hour_count keeping the hourly counts for its deletes')
on conflict (version) do nothing;

commit;
reset role;
