-- =============================================================================================
-- 96_stage_times.sql: addition 0008za, stage times
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 94_attempts_for_sales.sql (0008z). Rerunnable, forward-only, in one transaction. Run as your own IAM login:
-- dev first, then 97_verify_stage_times.sql (dev), normal and provoked; then prod. The ingest service of main
-- reads nothing new and writes nothing new, so it runs on the migrated database unchanged; the ingest that reads
-- the stage times (brief N21) is deployed after this script (docs/funnel-2026-10/RUNBOOK.md).
--
-- Brief N21, part 1 (Martin, 20 October 2026; README Decision log; backlog CMA-043): how deals and tickets move
-- through their stages. The CRM computes, retroactively, when a record entered and left each stage of its
-- pipeline (HubSpot: the calculated properties hs_v2_date_entered_<stage id> and hs_v2_date_exited_<stage id>);
-- the CMA mirrors those times per record and stage instead of keeping an event log of its own, so a stage time
-- is the CRM's, before and after the CMA existed. Which stages are read is configuration per stage.
--
-- What it adds
--   read_times         connection_stage.read_times: whether the adapter reads the stage's times. Null is the
--                      default: on for the stages of a counted pipeline, off for the others (a pipeline not yet
--                      seen counts, as everywhere); true or false is a person's choice on Configuration, Sources
--                      (cma.set_stage_read_times, tenant.configure), kept by every later pipelines read.
--                      cma.read_times_of() gives the effective value, written once; cma.connection_config gives
--                      it per stage (readTimes, and readTimesSet when a person chose it)
--   the times          cma.crm_record_stage: one row per record and stage (tenant, connection, record type, the
--                      record's source id, its pipeline, the stage, entered_at, exited_at, synced_at), keyed on
--                      tenant, connection, record type, source id and stage; tenant-aware (cma.setup_tenant_table:
--                      row-level security, the tenant policy, the grants, audit), no delete for the application
--   the write          cma.ingest_record_stages(connection, record type, source id, stages): upserts what the
--                      source answered for one record ({updatedAt, stages: [{pipelineId, stageId, enteredAt?,
--                      exitedAt?}]}); a time the answer leaves out or holds empty leaves the stored one, so a read
--                      never clears a time; the record upsert's stale guard (a read older than the record's stored
--                      source time writes nothing); ingest.write
--   reporting view     cma_read.crm_record_stage (ids and times only); cma_read.connection_stage keeps its columns
--
-- Everything is SECURITY INVOKER and executable by the application only, and checks its permission inside. The
-- times are ids and instants: no customer data.
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
  if not exists (select 1 from cma.schema_migration where version = '0008z') then
    raise exception 'addition 0008z (94_attempts_for_sales.sql) must run before 0008za';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Which stages are read: connection_stage.read_times
-- ---------------------------------------------------------------------------------------------
alter table cma.connection_stage add column if not exists read_times boolean;
comment on column cma.connection_stage.read_times is
  'Whether the adapter reads the stage''s entered and exited times (0008za): null follows the pipeline (on for a counted pipeline, off otherwise); true or false is a person''s choice on Configuration, Sources, kept by every pipelines read';

-- The effective value, written once: a person's choice, else on for a counted pipeline (a pipeline not yet seen
-- counts)
create or replace function cma.read_times_of(p_read_times boolean, p_pipeline_counted boolean)
returns boolean
language sql immutable
as $$
  select coalesce(p_read_times, coalesce(p_pipeline_counted, true))
$$;

-- A person's choice for a stage: true, false, or null for the default again. CMA02 for a stage the connection has
-- not read; tenant.configure
create or replace function cma.set_stage_read_times(p_connection_id uuid, p_record_type text, p_pipeline_id text, p_stage_id text,
                                                    p_read_times boolean)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  update cma.connection_stage cs
     set read_times = p_read_times
   where cs.tenant_id = cma.current_tenant_id() and cs.connection_id = p_connection_id and cs.record_type = p_record_type
     and cs.source_pipeline_id = p_pipeline_id and cs.source_stage_id = p_stage_id;
  if not found then
    raise exception 'no stage % in % pipeline % of connection %', p_stage_id, p_record_type, p_pipeline_id, p_connection_id
      using errcode = 'CMA02';
  end if;
end
$$;

-- As 0008u, and each stage gives readTimes (the effective value: the adapter reads the stage's times) and
-- readTimesSet (a person chose it)
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
                                                                'isLead', p.is_lead, 'isOrder', p.is_order, 'workType', s.key, 'status', p.status,
                                                                'stages', coalesce((select jsonb_agg(jsonb_build_object(
                                                                    'stageId', st.source_stage_id, 'label', st.label, 'order', st.display_order,
                                                                    'isClosed', st.is_closed, 'outcome', st.outcome, 'outcomeSource', st.outcome_source,
                                                                    'status', st.status, 'readTimes', cma.read_times_of(st.read_times, p.is_counted),
                                                                    'readTimesSet', st.read_times is not null)
                                                                  order by st.display_order, st.label, st.source_stage_id)
                                                                  from cma.connection_stage st
                                                                  where st.tenant_id = p.tenant_id and st.connection_id = p.connection_id
                                                                    and st.record_type = p.record_type and st.source_pipeline_id = p.source_pipeline_id),
                                                                  '[]'::jsonb))
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
                           from cma.writeback_field w where w.tenant_id = v_tenant and w.connection_id = p_connection_id), '[]'::jsonb),
    'inboxes', coalesce((select jsonb_agg(jsonb_build_object('inboxId', b.source_inbox_id, 'name', b.name, 'isCounted', b.is_counted,
                                                              'market', b.market, 'workType', s.key, 'channel', ch.key, 'status', b.status)
                                          order by b.name, b.source_inbox_id)
                         from cma.connection_inbox b
                         left join cma.skill s on s.tenant_id = b.tenant_id and s.id = b.work_type_skill_id
                         left join cma.channel ch on ch.tenant_id = b.tenant_id and ch.id = b.channel_id
                         where b.tenant_id = v_tenant and b.connection_id = p_connection_id), '[]'::jsonb),
    'inboxChannels', coalesce((select jsonb_agg(jsonb_build_object('channelId', k.source_channel_id, 'name', k.name, 'kind', k.kind,
                                                                    'channel', ch.key, 'isCounted', k.is_counted, 'status', k.status)
                                                order by k.name, k.source_channel_id)
                               from cma.connection_inbox_channel k
                               left join cma.channel ch on ch.tenant_id = k.tenant_id and ch.id = k.channel_id
                               where k.tenant_id = v_tenant and k.connection_id = p_connection_id), '[]'::jsonb),
    'inboxAccounts', coalesce((select jsonb_agg(jsonb_build_object('accountId', a.source_account_id, 'name', a.name, 'label', a.label,
                                                                    'inboxId', a.inbox_source_id, 'channelId', a.channel_source_id,
                                                                    'isCounted', a.is_counted, 'market', a.market, 'status', a.status)
                                                order by coalesce(a.label, a.name), a.source_account_id)
                               from cma.connection_inbox_account a
                               where a.tenant_id = v_tenant and a.connection_id = p_connection_id), '[]'::jsonb),
    'emailRules', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'appliesTo', r.applies_to, 'words', to_jsonb(r.words),
                                                                 'excludeWords', to_jsonb(r.exclude_words), 'category', r.category,
                                                                 'order', r.sort_order, 'status', r.status)
                                             order by r.sort_order, r.created_at, r.id)
                            from cma.connection_email_rule r
                            where r.tenant_id = v_tenant and r.connection_id = p_connection_id), '[]'::jsonb));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The times: cma.crm_record_stage
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.crm_record_stage (
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id       uuid not null,
  record_type         text not null check (record_type ~ '^[a-z][a-z0-9_]*$' and record_type <> 'contact'),
  source_id           text not null check (length(source_id) between 1 and 100),
  source_pipeline_id  text not null check (length(source_pipeline_id) between 1 and 100),
  source_stage_id     text not null check (length(source_stage_id) between 1 and 100),
  entered_at          timestamptz,
  exited_at           timestamptz,
  synced_at           timestamptz not null default now(),
  primary key (tenant_id, connection_id, record_type, source_id, source_stage_id),
  foreign key (tenant_id, connection_id, record_type, source_id)
    references cma.crm_record (tenant_id, connection_id, record_type, source_id)
);
comment on table cma.crm_record_stage is
  'When a CRM record entered and last left each stage of its pipeline, as the CRM computes it (0008za; HubSpot''s hs_v2_date_entered_ and hs_v2_date_exited_ properties of the stages that read times). Ids and times only; a read never clears a time; never deleted by the application';
comment on column cma.crm_record_stage.entered_at is 'When the record entered the stage, as the source last answered it (its latest entry); null until the source gave one';
comment on column cma.crm_record_stage.exited_at is 'When the record left the stage, as the source last answered it; null while the source gave none (never left, or still there)';
comment on column cma.crm_record_stage.synced_at is 'When a read last changed the row';
create index if not exists crm_record_stage_entered_idx on cma.crm_record_stage (tenant_id, entered_at);
select cma.setup_tenant_table('cma.crm_record_stage');
revoke delete on cma.crm_record_stage from cma_app;

-- ---------------------------------------------------------------------------------------------
-- 3. The write: cma.ingest_record_stages
-- ---------------------------------------------------------------------------------------------
-- One record's stage times as the source answered them: {"updatedAt": <the record's source time>, "stages":
-- [{"pipelineId", "stageId", "enteredAt"?, "exitedAt"?}, ...]} (at most 500 stages). Per stage, a time the item
-- holds is stored; a time it leaves out or holds as null leaves the stored one, so a read never clears a time, and
-- an item with neither writes nothing. The record must be stored (outcome unknown otherwise); a read older than
-- the record's stored source time (the record upsert's stale guard, cma.ingest_upsert_records) writes nothing
-- (stale). Answers the outcome (written, unchanged, stale, unknown) and how many stage rows it inserted or changed;
-- a row the read would not change is left as it is (no audit row). ingest.write; CMA04 for a malformed answer
create or replace function cma.ingest_record_stages(p_connection_id uuid, p_record_type text, p_source_id text, p_stages jsonb)
returns table (outcome text, stages integer)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_updated  timestamptz;
  v_stored   timestamptz;
  v_found    boolean;
  s          jsonb;
  v_entered  timestamptz;
  v_exited   timestamptz;
  v_n        integer := 0;
  v_one      integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if coalesce(p_record_type, '') !~ '^[a-z][a-z0-9_]*$' or p_record_type = 'contact' or coalesce(p_source_id, '') = ''
     or length(p_source_id) > 100 then
    raise exception 'stage times need a record type and a source id' using errcode = 'CMA04';
  end if;
  if p_stages is null or jsonb_typeof(p_stages) <> 'object' or jsonb_typeof(p_stages -> 'stages') is distinct from 'array'
     or jsonb_array_length(p_stages -> 'stages') > 500 then
    raise exception 'stage times are an object with a stages array of at most 500' using errcode = 'CMA04';
  end if;
  v_updated := cma.json_time(p_stages -> 'updatedAt', 'updatedAt');
  -- the record's row is locked as the record upsert locks it, so two reads of one record write one after the other
  select r.source_updated_at, true into v_stored, v_found
  from cma.crm_record r
  where r.tenant_id = v_tenant and r.connection_id = p_connection_id and r.record_type = p_record_type and r.source_id = p_source_id
  for update;
  if v_found is null then
    return query select 'unknown'::text, 0;
    return;
  end if;
  if v_stored is not null and (v_updated is null or v_updated < v_stored) then
    return query select 'stale'::text, 0;
    return;
  end if;
  for s in select value from jsonb_array_elements(p_stages -> 'stages') loop
    if jsonb_typeof(s) is distinct from 'object' or coalesce(s ->> 'stageId', '') = '' or length(s ->> 'stageId') > 100
       or coalesce(s ->> 'pipelineId', '') = '' or length(s ->> 'pipelineId') > 100 then
      raise exception 'every stage needs a pipelineId and a stageId of 1 to 100 characters' using errcode = 'CMA04';
    end if;
    v_entered := cma.json_time(s -> 'enteredAt', 'enteredAt');
    v_exited := cma.json_time(s -> 'exitedAt', 'exitedAt');
    if v_entered is null and v_exited is null then
      continue;
    end if;
    insert into cma.crm_record_stage as rs (tenant_id, connection_id, record_type, source_id, source_pipeline_id, source_stage_id,
                                            entered_at, exited_at)
    values (v_tenant, p_connection_id, p_record_type, p_source_id, s ->> 'pipelineId', s ->> 'stageId', v_entered, v_exited)
    on conflict (tenant_id, connection_id, record_type, source_id, source_stage_id) do update
      set source_pipeline_id = excluded.source_pipeline_id,
          entered_at = coalesce(excluded.entered_at, rs.entered_at),
          exited_at = coalesce(excluded.exited_at, rs.exited_at),
          synced_at = now()
      where rs.source_pipeline_id is distinct from excluded.source_pipeline_id
         or rs.entered_at is distinct from coalesce(excluded.entered_at, rs.entered_at)
         or rs.exited_at is distinct from coalesce(excluded.exited_at, rs.exited_at);
    get diagnostics v_one = row_count;
    v_n := v_n + v_one;
  end loop;
  return query select case when v_n > 0 then 'written' else 'unchanged' end, v_n;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.read_times_of(boolean,boolean)',
    'cma.set_stage_read_times(uuid,text,text,text,boolean)',
    'cma.connection_config(uuid)',
    'cma.ingest_record_stages(uuid,text,text,jsonb)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Reporting views
-- ---------------------------------------------------------------------------------------------
-- The stage times, ids and instants only
create or replace view cma_read.crm_record_stage as
  select tenant_id, connection_id, record_type, source_id, source_pipeline_id, source_stage_id, entered_at, exited_at, synced_at
  from cma.crm_record_stage
  where cma_read.reader_sees(tenant_id);

-- cma_read.connection_stage keeps 0008u's columns (85 pins them): a stage's read_times is configuration, which
-- cma.connection_config gives as readTimes

-- ---------------------------------------------------------------------------------------------
-- 6. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008za', 'Stage times: connection_stage.read_times (null follows the pipeline: on for a counted pipeline), cma.read_times_of and cma.set_stage_read_times (tenant.configure), readTimes and readTimesSet per stage in cma.connection_config; cma.crm_record_stage, one row per record and stage with entered_at, exited_at and synced_at (row-level security, audit, no delete for the application); cma.ingest_record_stages with the record upsert''s stale guard, a read never clearing a time; cma_read.crm_record_stage')
on conflict (version) do nothing;

commit;
reset role;
