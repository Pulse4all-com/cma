-- =============================================================================================
-- 38_outbox.sql: migration 0007c, outbox and CRM contact write-back (intake track I4)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 36_commerce.sql (0007b); it does not need 0007a or 0008. Rerunnable, forward-only. Run as your
-- own IAM login, dev first, then prod; then 39_verify_outbox.sql, then 37_verify_commerce.sql,
-- 33_verify_intake_core.sql and 31_verify_ingest_crm_records.sql again (unchanged).
--
-- Specification: docs/night-2026-10-10/DESIGN.md §4.3a (README Architecture, Outbox worker;
-- Decision log 10 October 2026).
--
-- What it adds
--   the setting        outbox.max_attempts (default 8): delivery attempts before an action is
--                      parked for a person
--   write-back fields  cma.writeback_field: per CRM connection, which canonical value goes to which
--                      contact property and how (always, if_empty, slot), enabled or not; the
--                      target property is unique per connection
--   the outbox         cma.outbox_action: one row per action towards another system (today
--                      crm.contact.set_properties), with its payload of canonical field -> value, a
--                      state (pending, in_flight, sent, failed, needs_review, superseded, dropped),
--                      attempts with backoff, the system's answer, the acting user, and the person
--                      who resolved a parked action. States only move forward (a trigger): a sent,
--                      superseded or dropped action never changes again
--   functions          set_writeback_field (tenant.configure), enqueue_contact_writeback,
--                      outbox_claim, outbox_finish (ingest.write), outbox_resolve (tenant.configure),
--                      outbox_status (tenant.configure or reports.view); connection_config also
--                      answers the connection's write-back fields
--
-- How an action moves
--   enqueue      only enabled fields are kept, an unknown field is refused, null when nothing is
--                left. The same payload as the contact's latest action gives that action back (the
--                dedupe). Otherwise the new action supersedes the contact's older pending and failed
--                actions, so an older value is never written after a newer one.
--   claim        due actions (pending, failed after its backoff, or in flight with an expired claim:
--                a dead worker) of one connection, FOR UPDATE SKIP LOCKED, never two of one contact
--                at a time; a claim counts an attempt and sets the next one 1, 2, 4 ... 60 minutes
--                ahead (as ingest_claim_events). A due action a newer one has overtaken is superseded
--                instead; an expired claim at the maximum is parked.
--   finish       sent, or failed with a short error code; a failure at outbox.max_attempts parks the
--                action as needs_review. Only actions in flight change.
--   resolve      a person (tenant.configure) retries a parked action (attempts start again) or drops
--                it; either records the person. A retry is refused when a newer action for the same
--                contact exists: that one carries the current values.
--
-- Nothing personal is stored (DESIGN §2.1): the payload holds ids, a store handle, counts, an
-- amount and country, currency and language codes; the ingest service drops the email it matched
-- the contact with before it enqueues.
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0007b') then
    raise exception 'migration 0007b (36_commerce.sql) must run before 0007c';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The setting
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('outbox.max_attempts', 'integer', null, '8',
     'Delivery attempts for an outbox action before it is parked for a person to retry or drop')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 2. Write-back fields
-- ---------------------------------------------------------------------------------------------
-- Per CRM connection: the contact property each canonical value goes to, and how. always writes
-- when different; if_empty only into an empty property; slot (the commerce customer id only) fills
-- slot 1, else slot 2, and never replaces another id. commerce_store, commerce_orders and
-- commerce_spent describe the customer in slot 1; the worker writes them only with that customer.
create table if not exists cma.writeback_field (
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id    uuid not null,
  field            text not null check (field in ('commerce_ref', 'commerce_store', 'commerce_orders', 'commerce_spent',
                                                  'country', 'currency', 'language')),
  slot             smallint not null default 1 check (slot between 1 and 9),
  target_property  text not null check (length(target_property) between 1 and 100 and target_property = btrim(target_property)),
  mode             text not null check (mode in ('always', 'if_empty', 'slot')),
  enabled          boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  primary key (tenant_id, connection_id, field, slot),
  unique (tenant_id, connection_id, target_property),
  check (slot = 1 or field = 'commerce_ref'),
  check (mode <> 'slot' or field = 'commerce_ref'),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.writeback_field is 'Per CRM connection: which canonical value the CMA writes to which contact property, with its mode (always, if_empty, slot). Tenant configuration; the worker writes no other property';
create or replace trigger set_updated_at before update on cma.writeback_field
  for each row execute function cma.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- 3. The outbox
-- ---------------------------------------------------------------------------------------------
-- One row per action towards another system. The payload is canonical field -> value (ids, counts,
-- amounts, codes; never personal data); the worker maps it to the target's properties. dedupe_key is
-- a hash of connection, action, target and payload; a key is retired (its own id appended) when the
-- same payload is enqueued again after a different one.
create table if not exists cma.outbox_action (
  id               uuid primary key default uuidv7(),
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id    uuid not null,
  action           text not null check (action in ('crm.contact.set_properties')),
  target_type      text not null check (target_type ~ '^[a-z][a-z0-9_]{0,39}$'),
  target_id        text not null check (length(target_id) between 1 and 100),
  payload          jsonb not null check (jsonb_typeof(payload) = 'object' and length(payload::text) <= 4096),
  dedupe_key       text not null check (length(dedupe_key) between 1 and 200),
  reason           text check (length(reason) <= 100),
  status           text not null default 'pending'
                     check (status in ('pending', 'in_flight', 'sent', 'failed', 'needs_review', 'superseded', 'dropped')),
  attempts         integer not null default 0 check (attempts >= 0),
  next_attempt_at  timestamptz not null default now(),
  claimed_at       timestamptz,
  sent_at          timestamptz,
  result           jsonb check (jsonb_typeof(result) = 'object' and length(result::text) <= 4096),
  error            text check (length(error) <= 200),
  created_by       uuid default cma.current_user_id(),
  created_at       timestamptz not null default now(),
  resolved_by      uuid,
  resolved_at      timestamptz,
  unique (tenant_id, id),
  unique (tenant_id, dedupe_key),
  check ((resolved_by is null) = (resolved_at is null)),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id),
  foreign key (tenant_id, created_by) references cma.app_user (tenant_id, id),
  foreign key (tenant_id, resolved_by) references cma.app_user (tenant_id, id)
);
comment on table cma.outbox_action is 'Every action towards another system, delivered by the outbox worker: pending, in_flight, sent, failed, needs_review (parked for a person), superseded (a newer action for the same target), dropped (by a person). Never deleted';
comment on column cma.outbox_action.payload is 'Canonical field -> value (ids, counts, amounts, codes); no personal data';
comment on column cma.outbox_action.result is 'What the worker wrote and skipped, and the target system''s response id';
create index if not exists outbox_action_due_idx on cma.outbox_action (tenant_id, connection_id, next_attempt_at)
  where status in ('pending', 'failed', 'in_flight');
create index if not exists outbox_action_target_idx on cma.outbox_action (tenant_id, connection_id, action, target_type, target_id, id);

-- States only move forward, and what was asked never changes. Allowed moves: pending and failed
-- to in_flight or superseded; in_flight to in_flight (a dead worker's claim taken again), sent,
-- failed, needs_review or superseded; needs_review to pending (retry) or dropped. sent, superseded
-- and dropped are final. The one other change is retiring the dedupe key (its own id appended).
create or replace function cma.check_outbox_action()
returns trigger
language plpgsql
as $$
begin
  if (new.id, new.tenant_id, new.connection_id, new.action, new.target_type, new.target_id, new.payload, new.reason,
      new.created_by, new.created_at)
     is distinct from
     (old.id, old.tenant_id, old.connection_id, old.action, old.target_type, old.target_id, old.payload, old.reason,
      old.created_by, old.created_at) then
    raise exception 'an outbox action''s target, payload and origin never change (%)', old.id using errcode = 'CMA03';
  end if;
  if new.dedupe_key <> old.dedupe_key and new.dedupe_key <> old.dedupe_key || ':' || old.id::text then
    raise exception 'an outbox action''s dedupe key can only be retired (%)', old.id using errcode = 'CMA03';
  end if;
  if old.status in ('sent', 'superseded', 'dropped')
     and (new.status, new.attempts, new.next_attempt_at, new.claimed_at, new.sent_at, new.result, new.error,
          new.resolved_by, new.resolved_at)
         is distinct from
         (old.status, old.attempts, old.next_attempt_at, old.claimed_at, old.sent_at, old.result, old.error,
          old.resolved_by, old.resolved_at) then
    raise exception 'outbox action % is %, which is final', old.id, old.status using errcode = 'CMA03';
  end if;
  if new.status <> old.status and not (
       (old.status in ('pending', 'failed') and new.status in ('in_flight', 'superseded'))
    or (old.status = 'in_flight' and new.status in ('sent', 'failed', 'needs_review', 'superseded'))
    or (old.status = 'needs_review' and new.status in ('pending', 'dropped'))) then
    raise exception 'outbox action % cannot move from % to %', old.id, old.status, new.status using errcode = 'CMA03';
  end if;
  return new;
end
$$;
revoke execute on function cma.check_outbox_action() from public;
create or replace trigger check_state before update on cma.outbox_action
  for each row execute function cma.check_outbox_action();

-- ---------------------------------------------------------------------------------------------
-- 4. Row-level security, audit and privileges
-- ---------------------------------------------------------------------------------------------
select cma.setup_tenant_table('cma.writeback_field');
select cma.setup_tenant_table('cma.outbox_action');

-- The application never deletes either (a field is disabled, an action superseded or dropped). An
-- action changes only in its state; what it asks for is fixed when it is written.
revoke delete on cma.writeback_field, cma.outbox_action from cma_app;
revoke update on cma.outbox_action from cma_app;
grant update (dedupe_key, status, attempts, next_attempt_at, claimed_at, sent_at, result, error, resolved_by, resolved_at)
  on cma.outbox_action to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 5. Configuration (tenant.configure)
-- ---------------------------------------------------------------------------------------------
-- Creates or updates one write-back field of a connection. slot is for the commerce customer id
-- (1 and 2: a contact can hold the ids of two stores); the slot mode is for that field only. A
-- property another field of the connection writes is a conflict. Disable a field with p_enabled
-- false; rows are never removed.
create or replace function cma.set_writeback_field(p_connection_id uuid, p_field text, p_target_property text, p_mode text,
                                                   p_enabled boolean, p_slot smallint default 1)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_field is null or p_field not in ('commerce_ref', 'commerce_store', 'commerce_orders', 'commerce_spent',
                                        'country', 'currency', 'language') then
    raise exception 'unknown write-back field %', p_field using errcode = 'CMA04';
  end if;
  if p_mode is null or p_mode not in ('always', 'if_empty', 'slot') then
    raise exception 'mode must be always, if_empty or slot, got %', p_mode using errcode = 'CMA04';
  end if;
  if p_mode = 'slot' and p_field <> 'commerce_ref' then
    raise exception 'the slot mode is for commerce_ref only, not %', p_field using errcode = 'CMA04';
  end if;
  if p_slot is null or p_slot not between 1 and 9 or (p_slot > 1 and p_field <> 'commerce_ref') then
    raise exception 'slot % is not allowed for %: only commerce_ref takes a slot (1 to 9)', p_slot, p_field using errcode = 'CMA04';
  end if;
  if p_enabled is null then
    raise exception 'enabled must be true or false' using errcode = 'CMA04';
  end if;
  if coalesce(btrim(p_target_property), '') = '' or length(btrim(p_target_property)) > 100 then
    raise exception 'a target property is 1 to 100 characters' using errcode = 'CMA04';
  end if;
  if exists (select 1 from cma.writeback_field w
             where w.tenant_id = v_tenant and w.connection_id = p_connection_id
               and w.target_property = btrim(p_target_property) and (w.field, w.slot) <> (p_field, p_slot)) then
    raise exception 'property % is already written by another field of this connection', btrim(p_target_property) using errcode = 'CMA03';
  end if;
  insert into cma.writeback_field as w (tenant_id, connection_id, field, slot, target_property, mode, enabled)
  values (v_tenant, p_connection_id, p_field, p_slot, btrim(p_target_property), p_mode, p_enabled)
  on conflict (tenant_id, connection_id, field, slot) do update
    set target_property = excluded.target_property, mode = excluded.mode, enabled = excluded.enabled
    where (w.target_property, w.mode, w.enabled) is distinct from (excluded.target_property, excluded.mode, excluded.enabled);
end
$$;

-- Decides on a parked action: retry (pending again, attempts start over) or drop (final). Records
-- the person. A retry is refused when a newer action for the same target exists. Answers the new
-- state.
create or replace function cma.outbox_resolve(p_id uuid, p_decision text)
returns text
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid;
  v_row    cma.outbox_action;
begin
  v_user := cma.assert_permission('tenant.configure');
  if p_decision is null or p_decision not in ('retry', 'drop') then
    raise exception 'decision must be retry or drop' using errcode = 'CMA04';
  end if;
  select * into v_row from cma.outbox_action o where o.tenant_id = v_tenant and o.id = p_id for update;
  if v_row.id is null then
    raise exception 'no outbox action % in the current tenant', p_id using errcode = 'CMA02';
  end if;
  if v_row.status <> 'needs_review' then
    raise exception 'outbox action % is %, not parked for review', p_id, v_row.status using errcode = 'CMA03';
  end if;
  if p_decision = 'retry' then
    if exists (select 1 from cma.outbox_action n
               where n.tenant_id = v_tenant and n.connection_id = v_row.connection_id and n.action = v_row.action
                 and n.target_type = v_row.target_type and n.target_id = v_row.target_id and n.id > v_row.id) then
      raise exception 'a newer action for the same target exists; drop outbox action % instead', p_id using errcode = 'CMA03';
    end if;
    update cma.outbox_action o
       set status = 'pending', attempts = 0, next_attempt_at = now(), resolved_by = v_user, resolved_at = now()
     where o.tenant_id = v_tenant and o.id = p_id;
    return 'pending';
  end if;
  update cma.outbox_action o
     set status = 'dropped', resolved_by = v_user, resolved_at = now()
   where o.tenant_id = v_tenant and o.id = p_id;
  return 'dropped';
end
$$;

-- Per connection and state: how many actions, the oldest and newest, and the next attempt due. For
-- the configuration screen and the morning check (parked actions need a person).
create or replace function cma.outbox_status()
returns table (
  connection_id    uuid,
  connection_name  text,
  status           text,
  actions          integer,
  oldest_at        timestamptz,
  newest_at        timestamptz,
  next_attempt_at  timestamptz
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_any_permission(array['tenant.configure', 'reports.view']);
  return query
    select o.connection_id, c.name, o.status, count(*)::integer, min(o.created_at), max(o.created_at),
           min(o.next_attempt_at) filter (where o.status in ('pending', 'failed', 'in_flight'))
    from cma.outbox_action o
    join cma.integration_connection c on c.tenant_id = o.tenant_id and c.id = o.connection_id
    where o.tenant_id = cma.current_tenant_id()
    group by o.connection_id, c.name, o.status
    order by c.name, o.connection_id,
             array_position(array['pending', 'in_flight', 'failed', 'needs_review', 'sent', 'superseded', 'dropped'], o.status);
end
$$;

-- 0007b's connection_config, plus the connection's write-back fields:
-- {..., writeback: [{field, slot, property, mode, enabled}]}
create or replace function cma.connection_config(p_connection_id uuid)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['ingest.write', 'tenant.configure']);
  if not exists (select 1 from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id) then
    raise exception 'no connection % in the current tenant', p_connection_id using errcode = 'CMA02';
  end if;
  return jsonb_build_object(
    'fields', coalesce((select jsonb_agg(jsonb_build_object('entity', f.entity, 'field', f.field,
                                                             'refSystem', nullif(f.ref_system, ''), 'slot', f.slot,
                                                             'property', f.source_property)
                                         order by f.entity, f.field, f.ref_system, f.slot)
                        from cma.connection_field f where f.tenant_id = v_tenant and f.connection_id = p_connection_id), '[]'::jsonb),
    'pipelines', coalesce((select jsonb_agg(jsonb_build_object('recordType', p.record_type, 'pipelineId', p.source_pipeline_id,
                                                                'label', p.label, 'isCounted', p.is_counted, 'isRouted', p.is_routed,
                                                                'isLead', p.is_lead, 'workType', s.key, 'status', p.status)
                                            order by p.record_type, p.label, p.source_pipeline_id)
                           from cma.connection_pipeline p
                           left join cma.skill s on s.tenant_id = p.tenant_id and s.id = p.work_type_skill_id
                           where p.tenant_id = v_tenant and p.connection_id = p_connection_id), '[]'::jsonb),
    'settings', (select c.settings from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id),
    'store', (select jsonb_build_object('handle', s.handle, 'name', s.name, 'market', s.market, 'currency', s.currency,
                                        'timeZone', s.time_zone)
              from cma.commerce_store s where s.tenant_id = v_tenant and s.connection_id = p_connection_id),
    'writeback', coalesce((select jsonb_agg(jsonb_build_object('field', w.field, 'slot', w.slot, 'property', w.target_property,
                                                                'mode', w.mode, 'enabled', w.enabled)
                                            order by w.field, w.slot)
                           from cma.writeback_field w where w.tenant_id = v_tenant and w.connection_id = p_connection_id), '[]'::jsonb));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The ingest side (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- Asks for a contact write-back on a CRM connection: p_values is {field: value} over the canonical
-- fields (commerce_ref, commerce_store, commerce_orders, commerce_spent, country, currency,
-- language). An unknown field or a malformed value is refused (CMA04); null or empty values are
-- left out; only fields with an enabled write-back row are kept, and commerce_store,
-- commerce_orders and commerce_spent only with the customer id they describe. Answers the action's
-- id: the contact's latest action when it asks for exactly this payload, else a new pending action
-- that supersedes the contact's older pending and failed ones. Null when nothing is left to write.
create or replace function cma.enqueue_contact_writeback(p_connection_id uuid, p_contact_source_id text, p_values jsonb,
                                                         p_reason text)
returns uuid
language plpgsql
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_action   constant text := 'crm.contact.set_properties';
  v_target   text := btrim(p_contact_source_id);
  v_payload  jsonb := '{}'::jsonb;
  v_latest   cma.outbox_action;
  v_key      text;
  v_id       uuid;
  e          record;
  v_text     text;
  v_value    jsonb;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if coalesce(v_target, '') = '' or length(v_target) > 100 then
    raise exception 'a contact id is 1 to 100 characters' using errcode = 'CMA04';
  end if;
  if p_values is null or jsonb_typeof(p_values) <> 'object' then
    raise exception 'values must be an object of field -> value' using errcode = 'CMA04';
  end if;
  if length(p_reason) > 100 then
    raise exception 'a reason is at most 100 characters' using errcode = 'CMA04';
  end if;

  for e in select j.key, j.value from jsonb_each(p_values) j order by j.key loop
    if e.key not in ('commerce_ref', 'commerce_store', 'commerce_orders', 'commerce_spent', 'country', 'currency', 'language') then
      raise exception 'unknown write-back field %', e.key using errcode = 'CMA04';
    end if;
    if jsonb_typeof(e.value) = 'null' then
      continue;
    end if;
    if jsonb_typeof(e.value) not in ('string', 'number') then
      raise exception 'write-back field % must be a text or a number', e.key using errcode = 'CMA04';
    end if;
    v_text := btrim(e.value #>> '{}');
    if v_text = '' then
      continue;
    end if;
    v_value := case e.key
                 when 'commerce_orders' then case when v_text ~ '^\d{1,9}$' then to_jsonb(v_text::integer) end
                 when 'commerce_spent'  then to_jsonb(cma.json_amount(e.value))
                 when 'currency'        then to_jsonb(cma.json_currency(v_text))
                 else case when length(v_text) <= 100 then to_jsonb(v_text) end
               end;
    if v_value is null then
      raise exception 'write-back field % has an invalid value', e.key using errcode = 'CMA04';
    end if;
    if exists (select 1 from cma.writeback_field w
               where w.tenant_id = v_tenant and w.connection_id = p_connection_id and w.field = e.key and w.enabled) then
      v_payload := v_payload || jsonb_build_object(e.key, v_value);
    end if;
  end loop;
  -- the store and the totals describe one customer: never written without its id
  if not v_payload ? 'commerce_ref' then
    v_payload := v_payload - 'commerce_store' - 'commerce_orders' - 'commerce_spent';
  end if;
  if v_payload = '{}'::jsonb then
    return null;
  end if;

  -- one enqueue per contact at a time, so the latest action is well defined
  perform pg_advisory_xact_lock(hashtextextended(v_tenant::text || '/outbox/' || p_connection_id::text || '/' || v_target, 0));
  select * into v_latest from cma.outbox_action o
  where o.tenant_id = v_tenant and o.connection_id = p_connection_id and o.action = v_action
    and o.target_type = 'contact' and o.target_id = v_target
  order by o.id desc
  limit 1;
  if v_latest.id is not null and v_latest.payload = v_payload then
    return v_latest.id;
  end if;

  v_key := encode(sha256(convert_to(p_connection_id::text || '|' || v_action || '|contact|' || v_target || '|' || v_payload::text, 'UTF8')), 'hex');
  -- the same payload asked for before a different one: that older action keeps its history under a
  -- retired key
  update cma.outbox_action o
     set dedupe_key = o.dedupe_key || ':' || o.id::text
   where o.tenant_id = v_tenant and o.dedupe_key = v_key;
  update cma.outbox_action o
     set status = 'superseded'
   where o.tenant_id = v_tenant and o.connection_id = p_connection_id and o.action = v_action
     and o.target_type = 'contact' and o.target_id = v_target and o.status in ('pending', 'failed');
  insert into cma.outbox_action (tenant_id, connection_id, action, target_type, target_id, payload, dedupe_key, reason)
  values (v_tenant, p_connection_id, v_action, 'contact', v_target, v_payload, v_key, nullif(btrim(p_reason), ''))
  returning id into v_id;
  return v_id;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid write-back: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Claims due actions of one connection, at most p_limit: pending, failed with the backoff passed,
-- or in flight with an expired claim (a dead worker). FOR UPDATE SKIP LOCKED: two workers never
-- claim the same action; and no action is claimed while another for the same target is in flight.
-- A claim counts an attempt and moves next_attempt_at forward (1, 2, 4, ... minutes, at most 60),
-- which is also how long the claim holds. First, due actions a newer action for the same target has
-- overtaken are superseded, and expired claims already at outbox.max_attempts are parked.
create or replace function cma.outbox_claim(p_connection_id uuid, p_limit integer default 50)
returns table (action_id uuid, action text, target_type text, target_id text, payload jsonb, reason text, attempts integer)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_max    integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_limit is null or p_limit < 1 or p_limit > 500 then
    raise exception 'limit must be between 1 and 500' using errcode = 'CMA04';
  end if;
  select s.value::integer into v_max from cma.tenant_settings() s where s.key = 'outbox.max_attempts';

  with overtaken as (
    select o.id
    from cma.outbox_action o
    where o.tenant_id = v_tenant and o.connection_id = p_connection_id
      and (o.status in ('pending', 'failed') or (o.status = 'in_flight' and o.next_attempt_at <= now()))
      and exists (select 1 from cma.outbox_action n
                  where n.tenant_id = o.tenant_id and n.connection_id = o.connection_id and n.action = o.action
                    and n.target_type = o.target_type and n.target_id = o.target_id and n.id > o.id)
    for update skip locked
  )
  update cma.outbox_action o set status = 'superseded'
    from overtaken where o.tenant_id = v_tenant and o.id = overtaken.id;

  with expired as (
    select o.id
    from cma.outbox_action o
    where o.tenant_id = v_tenant and o.connection_id = p_connection_id
      and o.status = 'in_flight' and o.next_attempt_at <= now() and o.attempts >= v_max
    for update skip locked
  )
  update cma.outbox_action o set status = 'needs_review', error = 'claim_expired'
    from expired where o.tenant_id = v_tenant and o.id = expired.id;

  return query
    with due as (
      select o.id
      from cma.outbox_action o
      where o.tenant_id = v_tenant
        and o.connection_id = p_connection_id
        and o.status in ('pending', 'failed', 'in_flight')
        and o.next_attempt_at <= now()
        and not exists (select 1 from cma.outbox_action f
                        where f.tenant_id = o.tenant_id and f.connection_id = o.connection_id and f.action = o.action
                          and f.target_type = o.target_type and f.target_id = o.target_id and f.id <> o.id
                          and f.status = 'in_flight' and f.next_attempt_at > now())
      order by o.next_attempt_at, o.id
      limit p_limit
      for update skip locked
    )
    update cma.outbox_action o
       set status = 'in_flight',
           attempts = o.attempts + 1,
           claimed_at = now(),
           next_attempt_at = now() + make_interval(mins => least(power(2, o.attempts)::integer, 60))
      from due
     where o.tenant_id = v_tenant and o.id = due.id
    returning o.id, o.action, o.target_type, o.target_id, o.payload, o.reason, o.attempts;
end
$$;

-- Finishes claimed actions: sent (with what was written and the system's response id in p_result),
-- or failed with a short error code; a failure at outbox.max_attempts parks the action as
-- needs_review. The next attempt after a failure is the one the claim set. Only actions in flight
-- change; answers how many did.
create or replace function cma.outbox_finish(p_ids uuid[], p_outcome text, p_result jsonb default null, p_error text default null)
returns integer
language plpgsql
as $$
declare
  v_max integer;
  v_n   integer;
begin
  perform cma.assert_permission('ingest.write');
  if p_outcome is null or p_outcome not in ('sent', 'failed') then
    raise exception 'outcome must be sent or failed' using errcode = 'CMA04';
  end if;
  if p_outcome = 'failed' and coalesce(btrim(p_error), '') = '' then
    raise exception 'a failure needs an error code' using errcode = 'CMA04';
  end if;
  if p_result is not null and (jsonb_typeof(p_result) <> 'object' or length(p_result::text) > 4096) then
    raise exception 'a result is an object of at most 4 kB' using errcode = 'CMA04';
  end if;
  select s.value::integer into v_max from cma.tenant_settings() s where s.key = 'outbox.max_attempts';
  update cma.outbox_action o
     set status = case when p_outcome = 'sent' then 'sent'
                       when o.attempts >= v_max then 'needs_review'
                       else 'failed' end,
         sent_at = case when p_outcome = 'sent' then now() end,
         result = coalesce(p_result, o.result),
         error = case when p_outcome = 'failed' then left(btrim(p_error), 200) end
   where o.tenant_id = cma.current_tenant_id()
     and o.id = any (coalesce(p_ids, '{}'))
     and o.status = 'in_flight';
  get diagnostics v_n = row_count;
  return v_n;
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
    'cma.set_writeback_field(uuid,text,text,text,boolean,smallint)',
    'cma.outbox_resolve(uuid,text)',
    'cma.outbox_status()',
    'cma.connection_config(uuid)',
    'cma.enqueue_contact_writeback(uuid,text,jsonb,text)',
    'cma.outbox_claim(uuid,integer)',
    'cma.outbox_finish(uuid[],text,jsonb,text)',
    -- the state trigger runs in the caller's rights
    'cma.check_outbox_action()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Reporting views (no dedupe hash)
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.writeback_field as
  select tenant_id, connection_id, field, slot, target_property, mode, enabled, created_at, updated_at
  from cma.writeback_field
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.outbox_action as
  select id, tenant_id, connection_id, action, target_type, target_id, payload, reason, status, attempts, next_attempt_at,
         claimed_at, sent_at, result, error, created_by, created_at, resolved_by, resolved_at
  from cma.outbox_action
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 9. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0007c', 'Outbox and CRM contact write-back: write-back fields per CRM connection (always, if_empty, slot), the outbox with forward-only states, dedupe and supersede per contact, claim with SKIP LOCKED and backoff, parking after outbox.max_attempts and resolve by a person, outbox_status, the write-back fields in connection_config')
on conflict (version) do nothing;

reset role;
