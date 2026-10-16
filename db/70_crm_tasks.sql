-- =============================================================================================
-- 70_crm_tasks.sql: addition 0008n, CRM tasks (ids, status, type, owner, due; never body or subject)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 68_email_activity.sql (0008m). Rerunnable, forward-only, in one transaction. Run as your own IAM
-- login, dev first, then prod; then 71_verify_crm_tasks.sql (dev), then 33_verify_intake_core.sql,
-- 53_verify_sources_configuration.sql and 69_verify_email_activity.sql (dev) again (unchanged).
--
-- Night run N16-B (README Decision log, 16 October 2026; backlog CMA-007, CMA-052): the CRM's tasks
-- reach the CMA by webhook and the nightly reconcile, as deals and tickets do, so the follow-up layer
-- of 0008o can say which tasks are open, overdue or due today, whose they are and what they belong to.
-- Never the task's body or subject: the upsert strips hs_task_body and hs_task_subject, every key the
-- connection names as body or subject (settings task_body_property, task_subject_property) and any
-- key whose name contains body, subject, note or description from the raw payload, even when the
-- adapter sends them, and the table's check refuses such a key on any path.
--
-- What it adds
--   cma.crm_task                 one row per task: connection, source id, owner_ref, status_ref,
--                                type_ref, priority_ref, due_at, completed_at, the associated contact,
--                                deal and ticket by source id, the source's times, raw (filtered). The
--                                market is derived at read time (0008o): the deal's or ticket's market,
--                                else the contact's country through 0008m's fallback
--   cma.connection_task_status   per connection the task statuses seen, with is_done (configuration,
--                                default false): which statuses mean done is never a name in code
--   cma.connection_task_type     per connection the task types seen, with is_callback (default false)
--                                and is_counted (default true) as configuration
--   cma.ingest_upsert_tasks()    the ingest write (ingest.write, at most 500): upsert by source id
--                                with the stale guard, a deletion as source_deleted_at, the catalogs
--                                extended on new refs, the raw payload filtered
--   cma.set_task_status(), cma.set_task_type()   configuration (tenant.configure)
--   cma.connection_task_catalogs()               the Sources page's read: both sections with how
--                                                often each ref was seen (tenant.configure)
--   cma.task_raw(), cma.task_raw_ok()            the filter and the table's check
--   held contacts                a contact is also taken in while a task of the connection points to
--                                it (cma.ingest_upsert_contacts replaced, 0008m's otherwise); the
--                                contact's privacy deletion clears the task's contact ref
--                                (cma.ingest_contact_forget replaced); task rows make a connection's
--                                kind crm (cma.connection_held_kinds_of replaced)
--   reporting views              cma_read.crm_task (every column but raw), connection_task_status,
--                                connection_task_type
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted. No message carries a task's text.
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
  if not exists (select 1 from cma.schema_migration where version = '0008m') then
    raise exception 'addition 0008m (68_email_activity.sql) must run before 0008n';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The raw payload's filter
-- ---------------------------------------------------------------------------------------------
-- True when a payload holds no key named like a task's text (body, subject, note, description), so
-- the table refuses one on any path, not only through the upsert
create or replace function cma.task_raw_ok(p_raw jsonb)
returns boolean
language sql immutable
as $$
  select p_raw is not null and jsonb_typeof(p_raw) = 'object'
     and not exists (select 1 from jsonb_object_keys(p_raw) k where k ~* '(body|subject|note|description)')
$$;

-- The raw payload kept: flat, non-personal keys only. Dropped: every key whose name contains body,
-- subject, note or description (case-insensitive), the keys the connection names as body or subject
-- (its settings task_body_property and task_subject_property, comma-separated), every nested value,
-- and every string holding an @ or longer than 200 characters
create or replace function cma.task_raw(p_connection_id uuid, p_raw jsonb)
returns jsonb
language sql stable
as $$
  with c as (
    select coalesce(ic.settings, '{}'::jsonb) as s
    from cma.integration_connection ic
    where ic.tenant_id = cma.current_tenant_id() and ic.id = p_connection_id
  ),
  named as (
    select lower(btrim(x)) as k
    from c, unnest(string_to_array(coalesce(c.s ->> 'task_body_property', '') || ',' || coalesce(c.s ->> 'task_subject_property', ''), ',')) x
    where btrim(x) <> ''
  )
  select coalesce((
    select jsonb_object_agg(e.key, e.value)
    from jsonb_each(case when jsonb_typeof(p_raw) = 'object' then p_raw else '{}'::jsonb end) e
    where e.key !~* '(body|subject|note|description)'
      and lower(e.key) not in (select k from named)
      and jsonb_typeof(e.value) in ('string', 'number', 'boolean', 'null')
      and (jsonb_typeof(e.value) <> 'string' or ((e.value #>> '{}') !~ '@' and length(e.value #>> '{}') <= 200))), '{}'::jsonb)
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------------------------
-- Thin mirror of the CRM's tasks: ids, refs and times, never the text. The CRM owns them.
create table if not exists cma.crm_task (
  id                 uuid primary key default uuidv7(),
  tenant_id          uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id      uuid not null,
  source_system      text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_id          text not null check (source_id ~ '^[^@[:space:]]{1,100}$'),
  owner_ref          text check (owner_ref ~ '^[^@[:space:]]{1,100}$'),
  status_ref         text check (status_ref ~ '^[^@[:space:]]{1,100}$'),
  type_ref           text check (type_ref ~ '^[^@[:space:]]{1,100}$'),
  priority_ref       text check (priority_ref ~ '^[^@[:space:]]{1,100}$'),
  due_at             timestamptz,
  completed_at       timestamptz,
  contact_source_id  text check (contact_source_id ~ '^[^@[:space:]]{1,100}$'),
  deal_source_id     text check (deal_source_id ~ '^[^@[:space:]]{1,100}$'),
  ticket_source_id   text check (ticket_source_id ~ '^[^@[:space:]]{1,100}$'),
  source_created_at  timestamptz not null,
  source_updated_at  timestamptz,
  source_deleted_at  timestamptz,
  synced_at          timestamptz not null default now(),
  raw                jsonb not null default '{}'::jsonb check (cma.task_raw_ok(raw)),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.crm_task is 'Thin mirror of CRM tasks: ids, owner, status, type, priority, due and completed times, the contact, deal and ticket by source id; never body or subject (the check on raw refuses such a key). Owned by the CRM';
create index if not exists crm_task_due_idx on cma.crm_task (tenant_id, due_at);
create index if not exists crm_task_contact_idx on cma.crm_task (tenant_id, connection_id, contact_source_id);
create index if not exists crm_task_owner_idx on cma.crm_task (tenant_id, connection_id, owner_ref);

-- The statuses a connection's tasks carry, seeded by the first read of each ref (label = the ref
-- until a person names it); is_done is configuration and survives every read
create table if not exists cma.connection_task_status (
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id  uuid not null,
  status_ref     text not null check (status_ref ~ '^[^@[:space:]]{1,100}$'),
  label          text not null check (length(btrim(label)) between 1 and 100),
  is_done        boolean not null default false,
  first_seen_at  timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  primary key (tenant_id, connection_id, status_ref),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.connection_task_status is 'Task statuses of a connection as seen on its tasks; is_done (configuration) says which mean the task is done';
create or replace trigger set_updated_at before update on cma.connection_task_status
  for each row execute function cma.set_updated_at();

-- The task types a connection's tasks carry, seeded alike; is_callback (a callback promised to a
-- customer, KPI 5) and is_counted are configuration
create table if not exists cma.connection_task_type (
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id  uuid not null,
  type_ref       text not null check (type_ref ~ '^[^@[:space:]]{1,100}$'),
  label          text not null check (length(btrim(label)) between 1 and 100),
  is_callback    boolean not null default false,
  is_counted     boolean not null default true,
  first_seen_at  timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  primary key (tenant_id, connection_id, type_ref),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.connection_task_type is 'Task types of a connection as seen on its tasks; is_callback and is_counted are configuration';
create or replace trigger set_updated_at before update on cma.connection_task_type
  for each row execute function cma.set_updated_at();

select cma.setup_tenant_table('cma.crm_task');
select cma.setup_tenant_table('cma.connection_task_status');
select cma.setup_tenant_table('cma.connection_task_type');
revoke delete on cma.crm_task, cma.connection_task_status, cma.connection_task_type from cma_app;

-- ---------------------------------------------------------------------------------------------
-- 3. The ingest write path (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- Upserts tasks, at most 500: [{sourceId, ownerRef, statusRef, statusLabel?, typeRef, typeLabel?,
-- priorityRef, dueAt, completedAt, contactId, dealId, ticketId, createdAt, updatedAt, deletedAt?,
-- raw?}]. updatedAt is the stale guard (0006): an older read changes nothing. The associations are
-- taken as the read gives them (the adapter reads them with every task), so a removed one clears.
-- A deletion keeps the row and sets source_deleted_at; a newer read brings the task back. A status or
-- type ref not in the catalog is added with the given label or the ref as label and the defaults
-- (is_done false, is_callback false, is_counted true); configuration and a label a person set stay.
-- Outcomes: inserted, updated, stale, deleted, unknown (a deletion of a task never stored).
create or replace function cma.ingest_upsert_tasks(p_connection_id uuid, p_tasks jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  t          jsonb;
  v_src      text;
  v_updated  timestamptz;
  v_deleted  timestamptz;
  v_created  timestamptz;
  v_status   text;
  v_type     text;
  v_old      cma.crm_task;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if p_tasks is null or jsonb_typeof(p_tasks) <> 'array' or jsonb_array_length(p_tasks) > 500 then
    raise exception 'tasks must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for t in select value from jsonb_array_elements(p_tasks) loop
    v_src := nullif(btrim(t ->> 'sourceId'), '');
    if v_src is null then
      raise exception 'every task needs a sourceId' using errcode = 'CMA04';
    end if;
    v_updated := cma.json_time(t -> 'updatedAt', 'updatedAt');
    v_deleted := cma.json_time(t -> 'deletedAt', 'deletedAt');
    v_created := cma.json_time(t -> 'createdAt', 'createdAt');
    select * into v_old from cma.crm_task x
    where x.tenant_id = v_tenant and x.connection_id = p_connection_id and x.source_id = v_src
    for update;

    if v_deleted is not null then
      if v_old.id is null then
        return query select v_src, 'unknown'::text;
      else
        update cma.crm_task x set source_deleted_at = v_deleted, synced_at = now()
        where x.tenant_id = v_tenant and x.id = v_old.id and x.source_deleted_at is distinct from v_deleted;
        return query select v_src, 'deleted'::text;
      end if;
      continue;
    end if;
    if v_old.id is not null and v_old.source_updated_at is not null
       and (v_updated is null or v_updated < v_old.source_updated_at) then
      return query select v_src, 'stale'::text;
      continue;
    end if;

    v_status := nullif(btrim(t ->> 'statusRef'), '');
    v_type := nullif(btrim(t ->> 'typeRef'), '');
    if v_status is not null then
      insert into cma.connection_task_status (tenant_id, connection_id, status_ref, label)
      values (v_tenant, p_connection_id, v_status, left(coalesce(nullif(btrim(t ->> 'statusLabel'), ''), v_status), 100))
      on conflict (tenant_id, connection_id, status_ref) do nothing;
    end if;
    if v_type is not null then
      insert into cma.connection_task_type (tenant_id, connection_id, type_ref, label)
      values (v_tenant, p_connection_id, v_type, left(coalesce(nullif(btrim(t ->> 'typeLabel'), ''), v_type), 100))
      on conflict (tenant_id, connection_id, type_ref) do nothing;
    end if;

    if v_old.id is null then
      if v_created is null then
        raise exception 'a new task needs createdAt' using errcode = 'CMA04';
      end if;
      insert into cma.crm_task (tenant_id, connection_id, source_system, source_id, owner_ref, status_ref, type_ref, priority_ref,
                                due_at, completed_at, contact_source_id, deal_source_id, ticket_source_id,
                                source_created_at, source_updated_at, raw)
      values (v_tenant, p_connection_id, v_system, v_src, nullif(btrim(t ->> 'ownerRef'), ''), v_status, v_type,
              nullif(btrim(t ->> 'priorityRef'), ''), cma.json_time(t -> 'dueAt', 'dueAt'), cma.json_time(t -> 'completedAt', 'completedAt'),
              nullif(btrim(t ->> 'contactId'), ''), nullif(btrim(t ->> 'dealId'), ''), nullif(btrim(t ->> 'ticketId'), ''),
              v_created, v_updated, cma.task_raw(p_connection_id, t -> 'raw'));
      return query select v_src, 'inserted'::text;
    else
      update cma.crm_task x
         set owner_ref = nullif(btrim(t ->> 'ownerRef'), ''),
             status_ref = v_status,
             type_ref = v_type,
             priority_ref = nullif(btrim(t ->> 'priorityRef'), ''),
             due_at = cma.json_time(t -> 'dueAt', 'dueAt'),
             completed_at = cma.json_time(t -> 'completedAt', 'completedAt'),
             contact_source_id = nullif(btrim(t ->> 'contactId'), ''),
             deal_source_id = nullif(btrim(t ->> 'dealId'), ''),
             ticket_source_id = nullif(btrim(t ->> 'ticketId'), ''),
             source_created_at = coalesce(v_created, x.source_created_at),
             source_updated_at = v_updated,
             source_deleted_at = null,
             synced_at = now(),
             raw = cma.task_raw(p_connection_id, t -> 'raw')
       where x.tenant_id = v_tenant and x.id = v_old.id;
      return query select v_src, 'updated'::text;
    end if;
  end loop;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid task: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Configuration (tenant.configure): the Sources page of a CRM connection
-- ---------------------------------------------------------------------------------------------
-- The connection must be a CRM connection, by its kind or, while that is unset, by the rows it holds
-- (0008e; a connection without either is accepted)
create or replace function cma.assert_task_connection(p_connection_id uuid)
returns void
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_kinds  text[];
begin
  perform cma.assert_connection(p_connection_id);
  select case when c.kind is not null then array[c.kind] else cma.connection_held_kinds_of(v_tenant, c.id) end into v_kinds
  from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id;
  if cardinality(v_kinds) > 0 and not ('crm' = any (v_kinds)) then
    raise exception 'tasks belong to a CRM connection; this one is %', array_to_string(v_kinds, ' and ') using errcode = 'CMA04';
  end if;
end
$$;

-- One status of the connection: its label and whether it means done. The ref as the CRM writes it
-- (1 to 100 characters, no @ or space), the label 1 to 100 (CMA04)
create or replace function cma.set_task_status(p_connection_id uuid, p_status_ref text, p_label text, p_is_done boolean)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_task_connection(p_connection_id);
  if coalesce(btrim(p_status_ref), '') !~ '^[^@[:space:]]{1,100}$' then
    raise exception 'a task status ref has 1 to 100 characters without spaces' using errcode = 'CMA04';
  end if;
  if coalesce(length(btrim(p_label)), 0) not between 1 and 100 then
    raise exception 'a task status label has 1 to 100 characters' using errcode = 'CMA04';
  end if;
  if p_is_done is null then
    raise exception 'is_done must be true or false' using errcode = 'CMA04';
  end if;
  insert into cma.connection_task_status (tenant_id, connection_id, status_ref, label, is_done)
  values (cma.current_tenant_id(), p_connection_id, btrim(p_status_ref), btrim(p_label), p_is_done)
  on conflict (tenant_id, connection_id, status_ref) do update
    set label = excluded.label, is_done = excluded.is_done
    where (cma.connection_task_status.label, cma.connection_task_status.is_done) is distinct from (excluded.label, excluded.is_done);
exception when check_violation or not_null_violation then
  raise exception 'invalid task status: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- One type of the connection: its label, whether it is a callback and whether it counts
create or replace function cma.set_task_type(p_connection_id uuid, p_type_ref text, p_label text, p_is_callback boolean, p_is_counted boolean)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_task_connection(p_connection_id);
  if coalesce(btrim(p_type_ref), '') !~ '^[^@[:space:]]{1,100}$' then
    raise exception 'a task type ref has 1 to 100 characters without spaces' using errcode = 'CMA04';
  end if;
  if coalesce(length(btrim(p_label)), 0) not between 1 and 100 then
    raise exception 'a task type label has 1 to 100 characters' using errcode = 'CMA04';
  end if;
  if p_is_callback is null or p_is_counted is null then
    raise exception 'both switches must be true or false' using errcode = 'CMA04';
  end if;
  insert into cma.connection_task_type (tenant_id, connection_id, type_ref, label, is_callback, is_counted)
  values (cma.current_tenant_id(), p_connection_id, btrim(p_type_ref), btrim(p_label), p_is_callback, p_is_counted)
  on conflict (tenant_id, connection_id, type_ref) do update
    set label = excluded.label, is_callback = excluded.is_callback, is_counted = excluded.is_counted
    where (cma.connection_task_type.label, cma.connection_task_type.is_callback, cma.connection_task_type.is_counted)
          is distinct from (excluded.label, excluded.is_callback, excluded.is_counted);
exception when check_violation or not_null_violation then
  raise exception 'invalid task type: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Both catalogs of a connection with how many tasks (not deleted) carry each ref, how many of those are
-- open (not done, by the catalog) and the newest task's time; and the newest task id for the record
-- link preview (ids only)
create or replace function cma.connection_task_catalogs(p_connection_id uuid)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  return jsonb_build_object(
    'statuses', coalesce((
      select jsonb_agg(jsonb_build_object('statusRef', s.status_ref, 'label', s.label, 'isDone', s.is_done,
                                          'seenTasks', coalesce(n.seen, 0), 'lastSeenAt', n.last_at)
                       order by s.status_ref)
      from cma.connection_task_status s
      left join lateral (
        select count(*)::integer as seen, max(coalesce(k.source_updated_at, k.source_created_at)) as last_at
        from cma.crm_task k
        where k.tenant_id = v_tenant and k.connection_id = p_connection_id and k.source_deleted_at is null and k.status_ref = s.status_ref) n on true
      where s.tenant_id = v_tenant and s.connection_id = p_connection_id), '[]'::jsonb),
    'types', coalesce((
      select jsonb_agg(jsonb_build_object('typeRef', y.type_ref, 'label', y.label, 'isCallback', y.is_callback, 'isCounted', y.is_counted,
                                          'seenTasks', coalesce(n.seen, 0), 'openTasks', coalesce(n.open, 0), 'lastSeenAt', n.last_at)
                       order by y.type_ref)
      from cma.connection_task_type y
      left join lateral (
        select count(*)::integer as seen,
               (count(*) filter (where not coalesce(s.is_done, false)))::integer as open,
               max(coalesce(k.source_updated_at, k.source_created_at)) as last_at
        from cma.crm_task k
        left join cma.connection_task_status s
          on s.tenant_id = k.tenant_id and s.connection_id = k.connection_id and s.status_ref = k.status_ref
        where k.tenant_id = v_tenant and k.connection_id = p_connection_id and k.source_deleted_at is null and k.type_ref = y.type_ref) n on true
      where y.tenant_id = v_tenant and y.connection_id = p_connection_id), '[]'::jsonb),
    'sampleTaskId', (select k.source_id from cma.crm_task k
                     where k.tenant_id = v_tenant and k.connection_id = p_connection_id and k.source_deleted_at is null
                     order by k.source_created_at desc, k.source_id desc limit 1));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Held contacts, the connection's kind and the privacy deletion (0008m's, plus tasks)
-- ---------------------------------------------------------------------------------------------
-- As 0008m, and a connection's tasks and task catalogs imply the kind crm
create or replace function cma.connection_held_kinds_of(p_tenant_id uuid, p_connection_id uuid)
returns text[]
language sql stable
as $$
  select array_remove(array[
    case when exists (select 1 from cma.crm_record x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_contact x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_pipeline x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_form x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_call_outcome x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.writeback_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox_channel x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_email_rule x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.email_message x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.email_thread x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_task x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_task_status x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_task_type x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'crm' end,
    case when exists (select 1 from cma.telephony_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_tag x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_number x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'telephony' end,
    case when exists (select 1 from cma.commerce_store x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.commerce_customer x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.commerce_order x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'commerce' end], null)
$$;

-- As 0008m (country or countries per slot, refs per slot, the stale guard, a deletion keeping the id),
-- and a contact is also taken in while a task of the same connection points to it
create or replace function cma.ingest_upsert_contacts(p_connection_id uuid, p_contacts jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  c          jsonb;
  v_src      text;
  v_updated  timestamptz;
  v_deleted  timestamptz;
  v_old      cma.crm_contact;
  v_id       uuid;
  k          text;
  v          jsonb;
  v_list     jsonb;
  v_slot     integer;
  v_store    text;
  v_values   text[];
  v_country  text;
  v_csource  smallint;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if p_contacts is null or jsonb_typeof(p_contacts) <> 'array' or jsonb_array_length(p_contacts) > 500 then
    raise exception 'contacts must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for c in select value from jsonb_array_elements(p_contacts) loop
    v_src := c ->> 'sourceId';
    if coalesce(v_src, '') = '' then
      raise exception 'every contact needs a sourceId' using errcode = 'CMA04';
    end if;
    if c ? 'refs' and jsonb_typeof(c -> 'refs') <> 'object' then
      raise exception 'refs must be an object of system to id' using errcode = 'CMA04';
    end if;
    if c ? 'countries' then
      if c ? 'country' then
        raise exception 'a contact gives country or countries, not both' using errcode = 'CMA04';
      end if;
      if jsonb_typeof(c -> 'countries') <> 'array' or jsonb_array_length(c -> 'countries') > 9
         or exists (select 1 from jsonb_array_elements(c -> 'countries') x where jsonb_typeof(x) not in ('string', 'null')) then
        raise exception 'countries must be a list of at most 9 values, each a string or null' using errcode = 'CMA04';
      end if;
      select coalesce(array_agg(x #>> '{}' order by ord), '{}') into v_values
      from jsonb_array_elements(c -> 'countries') with ordinality as e(x, ord);
    else
      v_values := array[c ->> 'country'];
    end if;
    v_updated := cma.json_time(c -> 'updatedAt', 'updatedAt');
    v_deleted := cma.json_time(c -> 'deletedAt', 'deletedAt');
    select * into v_old from cma.crm_contact cc
    where cc.tenant_id = v_tenant and cc.connection_id = p_connection_id and cc.source_id = v_src
    for update;

    if v_old.id is null
       and not exists (select 1 from cma.crm_record cr
                       where cr.tenant_id = v_tenant and cr.connection_id = p_connection_id and cr.contact_source_id = v_src)
       and not exists (select 1 from cma.email_message em
                       where em.tenant_id = v_tenant and em.connection_id = p_connection_id and em.contact_source_id = v_src)
       and not exists (select 1 from cma.email_thread et
                       where et.tenant_id = v_tenant and et.connection_id = p_connection_id and et.contact_source_id = v_src)
       and not exists (select 1 from cma.crm_task tk
                       where tk.tenant_id = v_tenant and tk.connection_id = p_connection_id and tk.contact_source_id = v_src) then
      return query select v_src, 'not_held'::text;
      continue;
    end if;

    if v_deleted is not null then
      if v_old.id is null then
        return query select v_src, 'not_held'::text;
      else
        update cma.crm_contact cc
           set country = null, country_source = null, language = null, currency = null, store = null, raw = '{}'::jsonb,
               source_deleted_at = v_deleted, synced_at = now()
         where cc.tenant_id = v_tenant and cc.id = v_old.id;
        delete from cma.crm_contact_ref cr where cr.tenant_id = v_tenant and cr.contact_id = v_old.id;
        return query select v_src, 'deleted'::text;
      end if;
      continue;
    end if;

    if v_old.id is not null and v_old.source_updated_at is not null
       and (v_updated is null or v_updated < v_old.source_updated_at) then
      return query select v_src, 'stale'::text;
      continue;
    end if;

    select p.country, p.source into v_country, v_csource from cma.contact_country_pick(v_values) p;
    v_store := lower(nullif(btrim(c ->> 'store'), ''));
    if v_store !~ '^[a-z0-9-]{1,60}$' then
      v_store := null;
    end if;
    if v_old.id is null then
      insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, country_source, language, currency,
                                   store, source_updated_at, raw)
      values (v_tenant, p_connection_id, v_system, v_src, v_country, v_csource, nullif(btrim(c ->> 'language'), ''),
              cma.json_currency(c ->> 'currency'), v_store, v_updated, coalesce(c -> 'raw', '{}'::jsonb))
      returning id into v_id;
    else
      v_id := v_old.id;
      update cma.crm_contact cc
         set country = v_country, country_source = v_csource, language = nullif(btrim(c ->> 'language'), ''),
             currency = cma.json_currency(c ->> 'currency'), store = v_store,
             source_updated_at = v_updated, source_deleted_at = null, synced_at = now(),
             raw = coalesce(c -> 'raw', '{}'::jsonb)
       where cc.tenant_id = v_tenant and cc.id = v_id;
    end if;

    for k, v in select key, value from jsonb_each(coalesce(c -> 'refs', '{}'::jsonb)) loop
      if k !~ '^[a-z0-9_]+$' then
        raise exception 'ref system % must be lowercase letters, digits or underscores', k using errcode = 'CMA04';
      end if;
      v_list := case when jsonb_typeof(v) = 'array' then v else jsonb_build_array(v) end;
      if jsonb_array_length(v_list) > 9 then
        raise exception 'at most 9 refs per system' using errcode = 'CMA04';
      end if;
      delete from cma.crm_contact_ref cr
      where cr.tenant_id = v_tenant and cr.contact_id = v_id and cr.system = k and cr.slot > jsonb_array_length(v_list);
      for v_slot in 1 .. jsonb_array_length(v_list) loop
        v := v_list -> (v_slot - 1);
        if jsonb_typeof(v) = 'null' or btrim(v #>> '{}') = '' then
          delete from cma.crm_contact_ref cr
          where cr.tenant_id = v_tenant and cr.contact_id = v_id and cr.system = k and cr.slot = v_slot;
        else
          insert into cma.crm_contact_ref (tenant_id, contact_id, system, slot, external_id)
          values (v_tenant, v_id, k, v_slot, btrim(v #>> '{}'))
          on conflict (tenant_id, contact_id, system, slot)
            do update set external_id = excluded.external_id, synced_at = now()
            where cma.crm_contact_ref.external_id is distinct from excluded.external_id;
        end if;
      end loop;
    end loop;
    return query select v_src, case when v_old.id is null then 'inserted' else 'updated' end;
  end loop;
exception
  when check_violation or invalid_text_representation then
    raise exception 'invalid contact: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- As 0008m (the contact's attributes and refs, the hashes on its calls, the kept values of its
-- submissions, the contact on its emails and threads), and the contact is cleared on the connection's
-- tasks (ids, times and refs stay for the counts). The answer gains tasks when one was cleared and keeps
-- its earlier shape otherwise.
create or replace function cma.ingest_contact_forget(p_connection_id uuid, p_contact_source_id text)
returns jsonb
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_contact uuid;
  v_c       integer := 0;
  v_r       integer := 0;
  v_k       integer := 0;
  v_s       integer := 0;
  v_t       integer := 0;
  v_e       integer := 0;
  v_h       integer := 0;
  v_tk      integer := 0;
  v_res     jsonb;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if coalesce(p_contact_source_id, '') = '' then
    raise exception 'a contact id is needed' using errcode = 'CMA04';
  end if;
  update cma.crm_contact cc
     set country = null, country_source = null, language = null, currency = null, store = null, raw = '{}'::jsonb,
         source_deleted_at = coalesce(cc.source_deleted_at, now()), synced_at = now()
   where cc.tenant_id = v_tenant and cc.connection_id = p_connection_id and cc.source_id = p_contact_source_id
  returning cc.id into v_contact;
  get diagnostics v_c = row_count;
  if v_contact is not null then
    delete from cma.crm_contact_ref r where r.tenant_id = v_tenant and r.contact_id = v_contact;
    get diagnostics v_r = row_count;
  end if;
  -- telephony calls linked to the contact's CRM calls (whether or not those still hold a hash)
  update cma.telephony_call t set counterpart_hash = null, synced_at = now()
  where t.tenant_id = v_tenant and t.counterpart_hash is not null
    and exists (select 1 from cma.call_link l
                join cma.crm_call k on k.tenant_id = l.tenant_id and k.id = l.crm_call_id
                join cma.crm_association a
                  on a.tenant_id = k.tenant_id and a.connection_id = k.connection_id
                 and a.from_type = 'crm_call' and a.from_id = k.source_id
                 and a.to_type = 'contact' and a.to_id = p_contact_source_id
                where l.tenant_id = t.tenant_id and l.telephony_call_id = t.id
                  and k.connection_id = p_connection_id);
  get diagnostics v_t = row_count;
  update cma.crm_call k set counterpart_hash = null, synced_at = now()
  where k.tenant_id = v_tenant and k.connection_id = p_connection_id and k.counterpart_hash is not null
    and exists (select 1 from cma.crm_association a
                where a.tenant_id = k.tenant_id and a.connection_id = k.connection_id
                  and a.from_type = 'crm_call' and a.from_id = k.source_id
                  and a.to_type = 'contact' and a.to_id = p_contact_source_id);
  get diagnostics v_k = row_count;
  update cma.form_submission s set kept_values = '{}'::jsonb, synced_at = now()
  where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.contact_source_id = p_contact_source_id
    and s.kept_values <> '{}'::jsonb;
  get diagnostics v_s = row_count;
  update cma.email_message em set contact_source_id = null, synced_at = now()
  where em.tenant_id = v_tenant and em.connection_id = p_connection_id and em.contact_source_id = p_contact_source_id;
  get diagnostics v_e = row_count;
  update cma.email_thread et set contact_source_id = null, synced_at = now()
  where et.tenant_id = v_tenant and et.connection_id = p_connection_id and et.contact_source_id = p_contact_source_id;
  get diagnostics v_h = row_count;
  update cma.crm_task tk set contact_source_id = null, synced_at = now()
  where tk.tenant_id = v_tenant and tk.connection_id = p_connection_id and tk.contact_source_id = p_contact_source_id;
  get diagnostics v_tk = row_count;
  v_res := jsonb_build_object('contacts', v_c, 'refs', v_r, 'calls', v_k, 'submissions', v_s);
  if v_t > 0 then
    v_res := v_res || jsonb_build_object('telephony_calls', v_t);
  end if;
  if v_e > 0 then
    v_res := v_res || jsonb_build_object('emails', v_e);
  end if;
  if v_h > 0 then
    v_res := v_res || jsonb_build_object('threads', v_h);
  end if;
  if v_tk > 0 then
    v_res := v_res || jsonb_build_object('tasks', v_tk);
  end if;
  return v_res;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.ingest_upsert_tasks(uuid,jsonb)',
    'cma.set_task_status(uuid,text,text,boolean)',
    'cma.set_task_type(uuid,text,text,boolean,boolean)',
    'cma.connection_task_catalogs(uuid)',
    'cma.assert_task_connection(uuid)',
    'cma.task_raw(uuid,jsonb)',
    'cma.task_raw_ok(jsonb)',
    'cma.connection_held_kinds_of(uuid,uuid)',
    'cma.ingest_upsert_contacts(uuid,jsonb)',
    'cma.ingest_contact_forget(uuid,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Reporting views: every column but the raw payload (ids and refs only)
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.crm_task as
  select id, tenant_id, connection_id, source_system, source_id, owner_ref, status_ref, type_ref, priority_ref, due_at, completed_at,
         contact_source_id, deal_source_id, ticket_source_id, source_created_at, source_updated_at, source_deleted_at, synced_at
  from cma.crm_task
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.connection_task_status as
  select tenant_id, connection_id, status_ref, label, is_done, first_seen_at, updated_at
  from cma.connection_task_status
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.connection_task_type as
  select tenant_id, connection_id, type_ref, label, is_callback, is_counted, first_seen_at, updated_at
  from cma.connection_task_type
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 8. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008n', 'CRM tasks: the thin task mirror (ids, owner, status, type, priority, due and completed, the contact, deal and ticket by source id; never body or subject), the status and type catalogs per connection with is_done, is_callback and is_counted as configuration, the ingest upsert with the raw filter, the Sources read, contacts held for tasks and cleared by the privacy deletion, the reporting views')
on conflict (version) do nothing;

commit;
reset role;
