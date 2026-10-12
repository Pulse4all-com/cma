-- =============================================================================================
-- 44_assignment_alerts.sql: addition 0008a, assignment alerts and messages from automations
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 42_messaging.sql (0008). Rerunnable, forward-only. Run as your own IAM login, dev first, then
-- prod; then 45_verify_assignment_alerts.sql, then 43_verify_messaging.sql again (unchanged).
--
-- What it adds (README Features 4 and 7; the go-live of 12 October 2026)
--   assignment rules   message_rule.trigger gains 'record_assigned': a record whose owner maps to a
--                      person (app_user_external_id, system '<adapter>_owner') raises one message for
--                      that person, once per record and owner, so a reassignment alerts the new owner
--                      and a retry writes nothing. cma.upsert_assignment_rule() configures one
--   uniqueness         the one-alert-per-record index of 0008 now covers created alerts only; a second
--                      index covers assignment alerts per record and assignee (target ->> 'assignee');
--                      cma.ingest_record_alerts() is redefined with the matching conflict target
--   assignment alerts  cma.ingest_assignment_alerts(connection, record type, source ids): the ingest
--                      service's call after every read-back of records (created or changed)
--   automations        cma.ingest_send_message(connection, title, body, urgency, target, ref system,
--                      ref type, ref id): a message sent by an automation through the ingest service
--                      (Make, n8n, a CRM workflow) to everyone, teams, a language, named people, the
--                      people behind CRM owner ids ({"owners": {"system", "ids"}}) or work emails
--                      ({"emails": [...]}), optionally only those clocked in; the link from the
--                      connection's record_url_<type> template. Sender: the tenant's Ingest user
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted.

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
  if not exists (select 1 from cma.schema_migration where version = '0008') then
    raise exception 'migration 0008 (42_messaging.sql) must run before 0008a';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The trigger: created or assigned
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_name text;
begin
  for v_name in
    select c.conname from pg_constraint c
    where c.conrelid = 'cma.message_rule'::regclass and c.contype = 'c'
      and pg_get_constraintdef(c.oid) like '%trigger%' and pg_get_constraintdef(c.oid) not like '%record_assigned%'
  loop
    execute format('alter table cma.message_rule drop constraint %I', v_name);
  end loop;
  if not exists (select 1 from pg_constraint c where c.conrelid = 'cma.message_rule'::regclass and c.contype = 'c'
                   and pg_get_constraintdef(c.oid) like '%record_assigned%') then
    alter table cma.message_rule add constraint message_rule_trigger_check
      check (trigger in ('record_created', 'record_assigned'));
  end if;
end
$$;
comment on column cma.message_rule.trigger is 'record_created: a new record alerts an audience; record_assigned: a record alerts the person its owner maps to (0008a)';

-- ---------------------------------------------------------------------------------------------
-- 2. One alert per record (created), one per record and assignee (assigned)
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_indexes where schemaname = 'cma' and indexname = 'message_rule_ref_idx' and indexdef not like '%assignee%') then
    drop index cma.message_rule_ref_idx;
  end if;
end
$$;
create unique index if not exists message_rule_ref_idx on cma.message (tenant_id, rule_id, ref_system, ref_type, ref_id)
  where rule_id is not null and not (target ? 'assignee');
create unique index if not exists message_rule_ref_assignee_idx on cma.message (tenant_id, rule_id, ref_system, ref_type, ref_id, (target ->> 'assignee'))
  where rule_id is not null and target ? 'assignee';

-- ---------------------------------------------------------------------------------------------
-- 3. Configuration: an assignment rule (tenant.configure)
-- ---------------------------------------------------------------------------------------------
-- Identified by name like every rule; the audience is the record's owner, so the audience fields of
-- 0008 are set to their neutral values and never read for this trigger
create or replace function cma.upsert_assignment_rule(p_name text, p_record_type text, p_pipeline_ids text[],
                                                      p_urgency text, p_max_age_minutes integer default null)
returns uuid
language plpgsql
as $$
declare
  v_tenant    uuid := cma.current_tenant_id();
  v_pipelines text[];
  v_id        uuid;
begin
  perform cma.assert_permission('tenant.configure');
  if coalesce(length(btrim(p_name)), 0) not between 1 and 80 then
    raise exception 'a rule needs a name of 1 to 80 characters' using errcode = 'CMA04';
  end if;
  if coalesce(p_record_type, '') !~ '^[a-z][a-z0-9_]*$' or p_record_type = 'contact' then
    raise exception 'record type % cannot raise alerts', p_record_type using errcode = 'CMA04';
  end if;
  if coalesce(p_urgency, '') not in ('normal', 'urgent') then
    raise exception 'urgency must be normal or urgent' using errcode = 'CMA04';
  end if;
  select coalesce(array_agg(distinct btrim(x) order by btrim(x)), '{}') into v_pipelines
  from unnest(coalesce(p_pipeline_ids, '{}')) x
  where nullif(btrim(x), '') is not null;
  insert into cma.message_rule (tenant_id, name, trigger, record_type, pipeline_ids, audience_permission, match_language,
                                only_clocked_in, fallback_permission, urgency, max_age_minutes)
  values (v_tenant, btrim(p_name), 'record_assigned', p_record_type, v_pipelines, 'leads.accept', false, false, null, p_urgency, p_max_age_minutes)
  on conflict (tenant_id, name) do update
    set trigger = 'record_assigned', record_type = excluded.record_type, pipeline_ids = excluded.pipeline_ids,
        audience_permission = 'leads.accept', match_language = false, only_clocked_in = false, fallback_permission = null,
        urgency = excluded.urgency, max_age_minutes = excluded.max_age_minutes
  returning id into v_id;
  return v_id;
exception when check_violation or not_null_violation then
  raise exception 'invalid assignment rule: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Record alerts of 0008, redefined with the narrower conflict target (the body is unchanged)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.ingest_record_alerts(p_connection_id uuid, p_record_type text, p_source_ids text[])
returns integer
language plpgsql
as $$
declare
  v_tenant     uuid := cma.current_tenant_id();
  v_system     text;
  v_default    integer;
  v_zone       text;
  r            record;
  m            cma.market;
  v_market     text;
  v_users      uuid[];
  v_fallback   boolean;
  v_msg        uuid;
  v_written    integer := 0;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if coalesce(p_record_type, '') !~ '^[a-z][a-z0-9_]*$' then
    raise exception 'a record type is needed' using errcode = 'CMA04';
  end if;
  if p_source_ids is null or cardinality(p_source_ids) > 500 then
    raise exception 'source ids must be an array of at most 500' using errcode = 'CMA04';
  end if;
  v_default := coalesce((select s.value::integer from cma.tenant_settings() s where s.key = 'alerts.max_age_minutes'), 60);
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;

  for r in
    select cr.source_id, cr.market, cr.pipeline_id, cr.source_created_at, cc.country,
           coalesce(p.label, cr.pipeline_id) as pipeline_label,
           coalesce(p.is_counted, true) as pipeline_counted,
           ru.id as rule_id, ru.name as rule_name, ru.pipeline_ids, ru.audience_permission, ru.match_language,
           ru.only_clocked_in, ru.fallback_permission, ru.urgency, coalesce(ru.max_age_minutes, v_default) as max_age
    from cma.crm_record cr
    join cma.message_rule ru
      on ru.tenant_id = cr.tenant_id and ru.enabled and ru.trigger = 'record_created' and ru.record_type = cr.record_type
    left join cma.connection_pipeline p
      on p.tenant_id = cr.tenant_id and p.connection_id = cr.connection_id and p.record_type = cr.record_type
     and p.source_pipeline_id = cr.pipeline_id
    left join cma.crm_contact cc
      on cc.tenant_id = cr.tenant_id and cc.connection_id = cr.connection_id and cc.source_id = cr.contact_source_id
     and cc.source_deleted_at is null
    where cr.tenant_id = v_tenant and cr.connection_id = p_connection_id and cr.record_type = p_record_type
      and cr.source_id = any (p_source_ids)
      and cr.source_deleted_at is null
    order by cr.source_created_at, cr.source_id, ru.name
  loop
    if r.source_created_at < now() - make_interval(mins => r.max_age) then
      continue;
    end if;
    if cardinality(r.pipeline_ids) = 0 then
      if not r.pipeline_counted then
        continue;
      end if;
    elsif r.pipeline_id is null or not (r.pipeline_id = any (r.pipeline_ids)) then
      continue;
    end if;
    if exists (select 1 from cma.message x
               where x.tenant_id = v_tenant and x.rule_id = r.rule_id and x.ref_system = v_system
                 and x.ref_type = p_record_type and x.ref_id = r.source_id) then
      continue;
    end if;

    v_market := coalesce(r.market, r.country);
    m := null;
    select * into m from cma.market mk where mk.tenant_id = v_tenant and mk.code = v_market;

    select coalesce(array_agg(u.id order by u.id), '{}') into v_users
    from cma.app_user u
    where u.tenant_id = v_tenant and u.status = 'active' and u.kind = 'person'
      and cma.has_permission(u.id, r.audience_permission)
      and (not r.only_clocked_in or cma.is_clocked_in(u.id))
      and (not r.match_language
           or (m.id is not null
               and (m.language_skill_key is null
                    or cma.has_skill(u.id, 'language', m.language_skill_key, m.min_language_level))));
    v_fallback := cardinality(v_users) = 0 and r.fallback_permission is not null;
    if v_fallback then
      select coalesce(array_agg(u.id order by u.id), '{}') into v_users
      from cma.app_user u
      where u.tenant_id = v_tenant and u.status = 'active' and u.kind = 'person'
        and cma.has_permission(u.id, r.fallback_permission);
    end if;

    v_msg := null;
    insert into cma.message (tenant_id, kind, urgency, title, body, ref_system, ref_type, ref_id, ref_url, rule_id,
                             target, sender_user_id)
    values (v_tenant, 'alert', r.urgency,
            'New ' || replace(p_record_type, '_', ' '),
            left(coalesce(m.code, v_market, 'unknown') || ' · ' || coalesce(r.pipeline_label, '-') || ' · created '
                 || to_char(r.source_created_at at time zone coalesce(m.time_zone, v_zone), 'HH24:MI'), 500),
            v_system, p_record_type, r.source_id, cma.record_url(p_connection_id, p_record_type, r.source_id), r.rule_id,
            jsonb_build_object('rule', r.rule_name, 'permission', r.audience_permission, 'market', v_market,
                               'matchLanguage', r.match_language, 'onlyClockedIn', r.only_clocked_in,
                               'fallback', v_fallback),
            cma.current_user_id())
    on conflict (tenant_id, rule_id, ref_system, ref_type, ref_id) where rule_id is not null and not (target ? 'assignee') do nothing
    returning id into v_msg;
    if v_msg is not null then
      perform cma.deliver_message(v_msg, v_users);
      v_written := v_written + 1;
    end if;
  end loop;
  return v_written;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Assignment alerts (ingest.write): the ingest service's call after every read-back of records
-- ---------------------------------------------------------------------------------------------
-- For each record (not deleted, with an owner) and each enabled assignment rule of its type whose
-- pipelines it is in, when the record was created or changed within the age limit and its owner maps
-- to an active person (app_user_external_id, system '<adapter>_owner'): one message to that person,
-- once per record and owner. Nothing personal is stored: the title names the record type, the body
-- the market, the pipeline label and the time; the target holds the owner's source id. Answers how
-- many messages were written.
create or replace function cma.ingest_assignment_alerts(p_connection_id uuid, p_record_type text, p_source_ids text[])
returns integer
language plpgsql
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  v_default  integer;
  v_zone     text;
  r          record;
  m          cma.market;
  v_market   text;
  v_user     uuid;
  v_msg      uuid;
  v_written  integer := 0;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if coalesce(p_record_type, '') !~ '^[a-z][a-z0-9_]*$' then
    raise exception 'a record type is needed' using errcode = 'CMA04';
  end if;
  if p_source_ids is null or cardinality(p_source_ids) > 500 then
    raise exception 'source ids must be an array of at most 500' using errcode = 'CMA04';
  end if;
  v_default := coalesce((select s.value::integer from cma.tenant_settings() s where s.key = 'alerts.max_age_minutes'), 60);
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;

  for r in
    select cr.source_id, cr.market, cr.pipeline_id, cr.owner_ref, cc.country,
           greatest(cr.source_created_at, cr.source_updated_at) as changed_at,
           coalesce(p.label, cr.pipeline_id) as pipeline_label,
           coalesce(p.is_counted, true) as pipeline_counted,
           ru.id as rule_id, ru.name as rule_name, ru.pipeline_ids, ru.urgency, coalesce(ru.max_age_minutes, v_default) as max_age
    from cma.crm_record cr
    join cma.message_rule ru
      on ru.tenant_id = cr.tenant_id and ru.enabled and ru.trigger = 'record_assigned' and ru.record_type = cr.record_type
    left join cma.connection_pipeline p
      on p.tenant_id = cr.tenant_id and p.connection_id = cr.connection_id and p.record_type = cr.record_type
     and p.source_pipeline_id = cr.pipeline_id
    left join cma.crm_contact cc
      on cc.tenant_id = cr.tenant_id and cc.connection_id = cr.connection_id and cc.source_id = cr.contact_source_id
     and cc.source_deleted_at is null
    where cr.tenant_id = v_tenant and cr.connection_id = p_connection_id and cr.record_type = p_record_type
      and cr.source_id = any (p_source_ids)
      and cr.source_deleted_at is null and cr.owner_ref is not null
    order by cr.source_created_at, cr.source_id, ru.name
  loop
    if r.changed_at is null or r.changed_at < now() - make_interval(mins => r.max_age) then
      continue;
    end if;
    if cardinality(r.pipeline_ids) = 0 then
      if not r.pipeline_counted then
        continue;
      end if;
    elsif r.pipeline_id is null or not (r.pipeline_id = any (r.pipeline_ids)) then
      continue;
    end if;
    select x.user_id into v_user
    from cma.app_user_external_id x
    join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
    where x.tenant_id = v_tenant and x.system = v_system || '_owner' and x.external_id = r.owner_ref
      and u.status = 'active' and u.kind = 'person';
    if v_user is null then
      continue;
    end if;
    if exists (select 1 from cma.message x
               where x.tenant_id = v_tenant and x.rule_id = r.rule_id and x.ref_system = v_system
                 and x.ref_type = p_record_type and x.ref_id = r.source_id and x.target ->> 'assignee' = r.owner_ref) then
      continue;
    end if;

    v_market := coalesce(r.market, r.country);
    m := null;
    select * into m from cma.market mk where mk.tenant_id = v_tenant and mk.code = v_market;

    v_msg := null;
    insert into cma.message (tenant_id, kind, urgency, title, body, ref_system, ref_type, ref_id, ref_url, rule_id,
                             target, sender_user_id)
    values (v_tenant, 'alert', r.urgency,
            'New ' || replace(p_record_type, '_', ' ') || ' assigned to you',
            left(coalesce(m.code, v_market, 'unknown') || ' · ' || coalesce(r.pipeline_label, '-') || ' · assigned '
                 || to_char(r.changed_at at time zone coalesce(m.time_zone, v_zone), 'HH24:MI'), 500),
            v_system, p_record_type, r.source_id, cma.record_url(p_connection_id, p_record_type, r.source_id), r.rule_id,
            jsonb_build_object('rule', r.rule_name, 'assignee', r.owner_ref, 'market', v_market),
            cma.current_user_id())
    on conflict (tenant_id, rule_id, ref_system, ref_type, ref_id, (target ->> 'assignee')) where rule_id is not null and target ? 'assignee' do nothing
    returning id into v_msg;
    if v_msg is not null then
      perform cma.deliver_message(v_msg, array[v_user]);
      v_written := v_written + 1;
    end if;
  end loop;
  return v_written;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Messages from automations (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- The target names exactly one of everyone, teams, language, users, owners ({"system", "ids"}: the
-- people behind CRM owner ids through app_user_external_id, system '<system>_owner') or emails (work
-- addresses of people of the tenant), optionally with onlyClockedIn. An optional reference (system,
-- type, id) gives the message its link through the connection's record_url_<type> template.
-- Resolved to active people now; a target that reaches nobody is refused (CMA04). Answers the message
-- id and the number of recipients.
create or replace function cma.ingest_send_message(p_connection_id uuid, p_title text, p_body text, p_urgency text, p_target jsonb,
                                                   p_ref_system text default null, p_ref_type text default null, p_ref_id text default null)
returns table (message_id uuid, recipients integer)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_sender   uuid;
  v_groups   int;
  v_clocked  boolean;
  v_keys     text[];
  v_ids      uuid[];
  v_skill    text;
  v_level    smallint;
  v_owner_sys text;
  v_owner_ids text[];
  v_emails   text[];
  v_users    uuid[];
  v_msg      uuid;
  v_url      text;
begin
  v_sender := cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if coalesce(length(btrim(p_title)), 0) not between 1 and 120 or length(coalesce(p_body, '')) > 500 then
    raise exception 'a message needs a title of 1 to 120 characters and a body of at most 500' using errcode = 'CMA04';
  end if;
  if coalesce(p_urgency, 'normal') not in ('normal', 'urgent') then
    raise exception 'urgency must be normal or urgent' using errcode = 'CMA04';
  end if;
  if (p_ref_system is null) <> (p_ref_type is null) or (p_ref_type is null) <> (p_ref_id is null)
     or (p_ref_system is not null and (p_ref_system !~ '^[a-z0-9_]+$' or p_ref_type !~ '^[a-z][a-z0-9_]*$' or p_ref_id !~ '^[A-Za-z0-9_.-]{1,100}$')) then
    raise exception 'a reference is a system, a type and an id, all three or none' using errcode = 'CMA04';
  end if;
  if p_target is null or jsonb_typeof(p_target) <> 'object'
     or exists (select 1 from jsonb_object_keys(p_target) k where k not in ('everyone', 'teams', 'language', 'users', 'owners', 'emails', 'onlyClockedIn')) then
    raise exception 'the target is an object with one of everyone, teams, language, users, owners or emails, and onlyClockedIn' using errcode = 'CMA04';
  end if;
  v_groups := (select count(*) from jsonb_object_keys(p_target) k where k in ('everyone', 'teams', 'language', 'users', 'owners', 'emails'));
  if v_groups <> 1 then
    raise exception 'the target names exactly one of everyone, teams, language, users, owners or emails' using errcode = 'CMA04';
  end if;
  if p_target ? 'onlyClockedIn' and jsonb_typeof(p_target -> 'onlyClockedIn') <> 'boolean' then
    raise exception 'onlyClockedIn must be true or false' using errcode = 'CMA04';
  end if;
  v_clocked := coalesce((p_target ->> 'onlyClockedIn')::boolean, false);

  if p_target ? 'everyone' then
    if p_target -> 'everyone' <> 'true'::jsonb then
      raise exception 'everyone must be true' using errcode = 'CMA04';
    end if;
  elsif p_target ? 'teams' then
    if jsonb_typeof(p_target -> 'teams') <> 'array' or jsonb_array_length(p_target -> 'teams') not between 1 and 50
       or exists (select 1 from jsonb_array_elements(p_target -> 'teams') e where jsonb_typeof(e) <> 'string') then
      raise exception 'teams is a list of 1 to 50 team keys' using errcode = 'CMA04';
    end if;
    select array_agg(distinct e) into v_keys from jsonb_array_elements_text(p_target -> 'teams') e;
    if exists (select 1 from unnest(v_keys) k
               where not exists (select 1 from cma.team t where t.tenant_id = v_tenant and t.key = k
                                   and t.valid_from <= now() and (t.valid_to is null or t.valid_to > now()))) then
      raise exception 'a team of % is not a current team of the tenant', p_target -> 'teams' using errcode = 'CMA02';
    end if;
  elsif p_target ? 'language' then
    if jsonb_typeof(p_target -> 'language') <> 'object'
       or coalesce(p_target #>> '{language,skill}', '') = ''
       or (p_target #> '{language,minLevel}' is not null and jsonb_typeof(p_target #> '{language,minLevel}') <> 'null'
           and (p_target #>> '{language,minLevel}') !~ '^[1-9]$') then
      raise exception 'language is {skill, minLevel 1 to 9 or null}' using errcode = 'CMA04';
    end if;
    v_skill := p_target #>> '{language,skill}';
    v_level := (p_target #>> '{language,minLevel}')::smallint;
    if not exists (select 1 from cma.skill s where s.tenant_id = v_tenant and s.dimension = 'language'
                     and s.key = v_skill and s.status = 'active') then
      raise exception 'no active language skill %', v_skill using errcode = 'CMA02';
    end if;
  elsif p_target ? 'users' then
    if jsonb_typeof(p_target -> 'users') <> 'array' or jsonb_array_length(p_target -> 'users') not between 1 and 500
       or exists (select 1 from jsonb_array_elements(p_target -> 'users') e
                  where jsonb_typeof(e) <> 'string'
                     or (e #>> '{}') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
      raise exception 'users is a list of 1 to 500 user ids' using errcode = 'CMA04';
    end if;
    select array_agg(distinct (e)::uuid) into v_ids from jsonb_array_elements_text(p_target -> 'users') e;
    if exists (select 1 from unnest(v_ids) x
               where not exists (select 1 from cma.app_user u where u.tenant_id = v_tenant and u.id = x
                                   and u.status = 'active' and u.kind = 'person')) then
      raise exception 'a user of the target is not an active person of the tenant' using errcode = 'CMA02';
    end if;
  elsif p_target ? 'owners' then
    if jsonb_typeof(p_target -> 'owners') <> 'object'
       or coalesce(p_target #>> '{owners,system}', '') !~ '^[a-z0-9_]+$'
       or jsonb_typeof(p_target #> '{owners,ids}') <> 'array' or jsonb_array_length(p_target #> '{owners,ids}') not between 1 and 500
       or exists (select 1 from jsonb_array_elements(p_target #> '{owners,ids}') e
                  where jsonb_typeof(e) <> 'string' or (e #>> '{}') !~ '^[A-Za-z0-9_.@-]{1,100}$') then
      raise exception 'owners is {system, ids: a list of 1 to 500 owner ids}' using errcode = 'CMA04';
    end if;
    v_owner_sys := (p_target #>> '{owners,system}') || '_owner';
    select array_agg(distinct e) into v_owner_ids from jsonb_array_elements_text(p_target #> '{owners,ids}') e;
  else
    if jsonb_typeof(p_target -> 'emails') <> 'array' or jsonb_array_length(p_target -> 'emails') not between 1 and 500
       or exists (select 1 from jsonb_array_elements(p_target -> 'emails') e
                  where jsonb_typeof(e) <> 'string' or (e #>> '{}') !~ '^[^@[:space:]]+@[^@[:space:]]+$') then
      raise exception 'emails is a list of 1 to 500 addresses' using errcode = 'CMA04';
    end if;
    select array_agg(distinct lower(e)) into v_emails from jsonb_array_elements_text(p_target -> 'emails') e;
  end if;

  select coalesce(array_agg(u.id order by u.id), '{}') into v_users
  from cma.app_user u
  where u.tenant_id = v_tenant and u.status = 'active' and u.kind = 'person'
    and (not v_clocked or cma.is_clocked_in(u.id))
    and case
          when p_target ? 'teams' then
            exists (select 1 from cma.team_member tm
                    join cma.team t on t.tenant_id = tm.tenant_id and t.id = tm.team_id
                    where tm.tenant_id = v_tenant and tm.user_id = u.id and t.key = any (v_keys)
                      and tm.valid_from <= now() and (tm.valid_to is null or tm.valid_to > now()))
          when p_target ? 'language' then cma.has_skill(u.id, 'language', v_skill, v_level)
          when p_target ? 'users' then u.id = any (v_ids)
          when p_target ? 'owners' then
            exists (select 1 from cma.app_user_external_id x
                    where x.tenant_id = v_tenant and x.user_id = u.id and x.system = v_owner_sys and x.external_id = any (v_owner_ids))
          when p_target ? 'emails' then lower(u.email) = any (v_emails)
          else true
        end;
  if cardinality(v_users) = 0 then
    raise exception 'the target reaches nobody now' using errcode = 'CMA04';
  end if;
  v_url := case when p_ref_type is null then null else cma.record_url(p_connection_id, p_ref_type, p_ref_id) end;

  insert into cma.message (tenant_id, kind, urgency, title, body, ref_system, ref_type, ref_id, ref_url, target, sender_user_id)
  values (v_tenant, 'announcement', coalesce(p_urgency, 'normal'), btrim(p_title), coalesce(p_body, ''),
          p_ref_system, p_ref_type, p_ref_id, v_url, p_target, v_sender)
  returning id into v_msg;
  perform cma.deliver_message(v_msg, v_users);
  message_id := v_msg;
  recipients := cardinality(v_users);
  return next;
exception when check_violation or not_null_violation then
  raise exception 'invalid message: %', sqlerrm using errcode = 'CMA04';
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
    'cma.upsert_assignment_rule(text,text,text[],text,integer)',
    'cma.ingest_record_alerts(uuid,text,text[])',
    'cma.ingest_assignment_alerts(uuid,text,text[])',
    'cma.ingest_send_message(uuid,text,text,text,jsonb,text,text,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

insert into cma.schema_migration (version, description)
values ('0008a', 'Assignment alerts (a record alerts the person its owner maps to, once per record and owner) and messages from automations through the ingest service (owners and emails as targets)')
on conflict (version) do nothing;

reset role;
