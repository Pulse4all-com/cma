-- =============================================================================================
-- 84_first_orders.sql: addition 0008u, first orders: self-service or call center (KPI 2)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 82_email_reports.sql (0008t). Rerunnable, forward-only, in one transaction. Run as your own IAM
-- login, dev first, then prod; then 85_verify_first_orders.sql (dev), then 41_verify_lead_metrics.sql,
-- 69_verify_email_activity.sql and 83_verify_email_reports.sql (dev) again (unchanged).
--
-- Brief N19-A, part 2 (Martin, 18 October 2026; README KPIs, 2 indirect sales): of the new first
-- orders, which came in by self-service and which through the call center. A first order is a won deal
-- in an order pipeline (the deal the CRM's commerce integration creates per new order, won on
-- creation), matched against the same contact's lead deals, the agents' calls and emails with it, a
-- call from the order's phone number (the keyed hashes of 0007a and 0008g) and whether the contact
-- was in the CRM before. The same CRM contact means the same email address: the CRM keeps one contact
-- per address, and the CMA never stores an address. The rules are proposed defaults held as tenant
-- settings; Kira confirms them (README Open decisions, indirect sales). Nothing is written to the CRM.
--
-- What it adds
--   order pipelines    connection_pipeline.is_order (default false): a deal pipeline whose won deals
--                      are orders. cma.set_pipeline_order() (tenant.configure)
--   stage outcomes     connection_stage.outcome (won, lost or none) and outcome_source (source or
--                      person): the adapter gives the source's outcome with every pipelines read (a
--                      deal stage at probability 1.0 is won, a closed one at 0.0 lost; a ticket stage
--                      none); a person's choice on Configuration, Sources (cma.set_stage_outcome(),
--                      tenant.configure, deal stages) survives every later read
--   contact created    crm_contact.source_created_at: the earliest non-empty value of the canonical
--                      field created_at of contacts, slot 1 being the object's own creation time (no
--                      property, so no extra read) and slots 2 to 9 optional properties (a created date
--                      kept from an earlier CRM, say). 0008m's slot rule extends from country to
--                      created_at: contiguous (from 2), removed from the end, no property twice.
--                      cma_read.crm_contact gains it last
--   settings           attribution.window_days (90, 1 to 365), attribution.level_order
--                      (lead_deal,conversation,email,phone_match,attempt,known_contact: one to six of
--                      them, each once), attribution.assisted_levels (lead_deal,conversation,email,
--                      phone_match: none to six of them, each once), attribution.known_contact_minutes
--                      (60, 0 to 10080), attribution.order_match_minutes (1440, 1 to 10080)
--   the definition     cma.first_orders_of(tenant, from, to): every order deal created in the period
--                      with its kind, linked store order, evidence, level, attribution and credited
--                      person (below)
--   reads              cma.first_orders_report() (the period per day, week, market or level, per market
--                      and per level, and the previous period's total, like for like),
--                      cma.first_orders_amounts() (per currency, never summed across),
--                      cma.first_orders_list() (the first orders, newest first, capped by
--                      follow_up.list_rows), cma.first_orders_per_person() (performance.team and
--                      reports.per_person holding orders), cma.first_orders_history_start(); each over a
--                      read of an explicit tenant (cma.*_of), as 0008t
--   reporting views    cma_read.connection_pipeline and connection_stage with the new columns last;
--                      cma_read.first_orders (ids, codes, flags and times)
--
-- Definitions (one place each; README, Data model: first orders)
--   order deal         a deal, not deleted, in a counted pipeline marked is_order, whose stage's outcome
--                      is won; T is its creation time at the source
--   its contact        the deal's primary contact, else its earliest current association to a contact
--   linked order       a store order (not a test, not cancelled, not deleted) of a customer matched to
--                      that contact (0008h), created within attribution.order_match_minutes of T, the
--                      nearest; its amount and currency, else the deal's own
--   kind               no_contact (the deal has none), renewal (the linked order is a renewal),
--                      repeat (the contact has an earlier won order deal), not_first (the store counts
--                      earlier orders for the linked order's customer), else first. Only first orders
--                      are attributed; the others are counted apart
--   evidence           each in [T - attribution.window_days, T):
--                        lead_deal      a deal of the contact (primary or current association) in a
--                                       counted lead pipeline that is no order pipeline, created then
--                        conversation   a CRM call associated with the contact that is a conversation
--                                       as 0008j defines one (cma.crm_call_connected_of), at its
--                                       effective time
--                        email          an email out and sent to the contact by an agent: an inbox
--                                       message (not of a bot, an AI, the system or an integration,
--                                       not in a spam conversation) or an engagement that is neither
--                                       an inbox copy nor an automation by origin (0008t)
--                        phone_match    a call (CRM or telephony, any contact) whose other party's hash
--                                       is the linked order's or its customer's phone hash
--                        attempt        a CRM call associated with the contact that is no conversation
--                      known_contact: the contact was created at the source at least
--                      attribution.known_contact_minutes before T
--   level              the first evidence in attribution.level_order that holds, else self_service
--   attribution        call_center when the level is in attribution.assisted_levels, else self_service
--   credited person    the owner of the latest touch of an assisted kind before T (a lead deal's owner,
--                      a call's owner or telephony user, an email's sender), through the linked accounts
--                      '<adapter>_owner' and '<adapter>_user' (0008e); not linked otherwise, never by id
--   first touch        the earliest touch of any kind in the window; days from it to T
--   date, week         T in the deal's market zone (0007d's market), else the tenant's
--
-- Everything is SECURITY INVOKER and executable by the application only; the cma_read function of the
-- reader view is SECURITY DEFINER, owned by cma_owner, search path pinned, executable by readers only
-- (as 0008o and 0008t). The reads return ids, codes, counts, amounts and times: no name, address or
-- phone number exists to return.
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
  if not exists (select 1 from cma.schema_migration where version = '0008t') then
    raise exception 'addition 0008t (82_email_reports.sql) must run before 0008u';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('attribution.window_days',             'integer', null, '90',
     'Days before a first order in which a lead deal, a call, an email or a phone match counts as evidence (1 to 365)'),
  ('attribution.level_order',             'text',    null, 'lead_deal,conversation,email,phone_match,attempt,known_contact',
     'The evidence levels of a first order in the order they are tried: one to six of lead_deal, conversation, email, phone_match, attempt and known_contact, each once, lower case, comma-separated without spaces'),
  ('attribution.assisted_levels',         'text',    null, 'lead_deal,conversation,email,phone_match',
     'The levels whose first orders count as via the call center; the others count as self-service. None to six of the levels, each once, comma-separated without spaces'),
  ('attribution.known_contact_minutes',   'integer', null, '60',
     'Minutes a contact must have existed in the CRM before a first order to count as a known contact (0 to 10080)'),
  ('attribution.order_match_minutes',     'integer', null, '1440',
     'Minutes around an order deal''s creation within which a store order of the same contact is its order, the nearest (1 to 10080)')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- A list of evidence levels: each from the fixed six at most once, comma-separated without spaces; empty
-- only when p_empty_ok
create or replace function cma.is_attribution_levels(p_value text, p_empty_ok boolean)
returns boolean
language sql immutable
as $$
  select coalesce((p_value = '' and p_empty_ok)
                  or (p_value ~ '^(lead_deal|conversation|email|phone_match|attempt|known_contact)(,(lead_deal|conversation|email|phone_match|attempt|known_contact)){0,5}$'
                      and (select count(*) = count(distinct x) from unnest(string_to_array(p_value, ',')) x)), false)
$$;

-- As 0008t, plus the five attribution settings
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
  -- the per-person report pages (0008t): from the fixed list email, orders
  elsif new.key = 'reports.per_person' and not cma.is_per_person_list(new.value) then
    raise exception 'Setting % takes email and orders, each at most once, lower case, comma-separated without spaces, or nothing', new.key
      using errcode = 'CMA04';
  -- first orders (0008u)
  elsif new.key = 'attribution.window_days'
        and (case when length(new.value) > 3 then true else new.value::integer not between 1 and 365 end) then
    raise exception 'Setting % takes a whole number of days from 1 to 365', new.key using errcode = 'CMA04';
  elsif new.key = 'attribution.level_order' and not cma.is_attribution_levels(new.value, false) then
    raise exception 'Setting % takes one to six of lead_deal, conversation, email, phone_match, attempt and known_contact in the order wanted, each once, lower case, comma-separated without spaces', new.key
      using errcode = 'CMA04';
  elsif new.key = 'attribution.assisted_levels' and not cma.is_attribution_levels(new.value, true) then
    raise exception 'Setting % takes levels from lead_deal, conversation, email, phone_match, attempt and known_contact, each once, lower case, comma-separated without spaces, or nothing', new.key
      using errcode = 'CMA04';
  elsif new.key = 'attribution.known_contact_minutes'
        and (case when length(new.value) > 5 then true else new.value::integer not between 0 and 10080 end) then
    raise exception 'Setting % takes a whole number of minutes from 0 to 10080', new.key using errcode = 'CMA04';
  elsif new.key = 'attribution.order_match_minutes'
        and (case when length(new.value) > 5 then true else new.value::integer not between 1 and 10080 end) then
    raise exception 'Setting % takes a whole number of minutes from 1 to 10080', new.key using errcode = 'CMA04';
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Order pipelines and stage outcomes
-- ---------------------------------------------------------------------------------------------
alter table cma.connection_pipeline add column if not exists is_order boolean not null default false;
comment on column cma.connection_pipeline.is_order is
  'A deal pipeline whose won deals are orders (0008u): the first-orders report reads it. Configuration, never set by a source';
alter table cma.connection_pipeline drop constraint if exists connection_pipeline_is_order_check;
alter table cma.connection_pipeline add constraint connection_pipeline_is_order_check check (not is_order or record_type = 'deal');

alter table cma.connection_stage add column if not exists outcome text;
alter table cma.connection_stage add column if not exists outcome_source text;
alter table cma.connection_stage drop constraint if exists connection_stage_outcome_check;
alter table cma.connection_stage add constraint connection_stage_outcome_check
  check ((outcome is null or outcome in ('won', 'lost'))
         and (outcome_source is null or outcome_source in ('source', 'person'))
         and (outcome is null or outcome_source is not null));
comment on column cma.connection_stage.outcome is
  'won, lost or none (null) (0008u): from the source''s stage (a deal stage at probability 1.0 is won, a closed one at 0.0 lost), unless a person chose it';
comment on column cma.connection_stage.outcome_source is
  'Where the outcome comes from (0008u): source (the pipelines read) or person (Configuration, Sources; kept by every later read); null while neither gave one';

-- Whether a deal pipeline's won deals are orders. A pipeline not yet refreshed from the source is added
-- with its id as label. Deal pipelines only (CMA04 otherwise)
create or replace function cma.set_pipeline_order(p_connection_id uuid, p_record_type text, p_pipeline_id text, p_is_order boolean)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_is_order is null then
    raise exception 'is_order must be true or false' using errcode = 'CMA04';
  end if;
  if p_record_type is distinct from 'deal' then
    raise exception 'only a deal pipeline can be an order pipeline, not a % pipeline', p_record_type using errcode = 'CMA04';
  end if;
  insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_order)
  values (cma.current_tenant_id(), p_connection_id, p_record_type, p_pipeline_id, p_pipeline_id, p_is_order)
  on conflict (tenant_id, connection_id, record_type, source_pipeline_id) do update set is_order = excluded.is_order;
exception when check_violation or not_null_violation then
  raise exception 'invalid pipeline: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- A person's outcome for a deal stage: won, lost or none. It holds over every later pipelines read.
-- CMA02 for a stage the connection has not read; CMA04 for another value or a stage of another record type
create or replace function cma.set_stage_outcome(p_connection_id uuid, p_record_type text, p_pipeline_id text, p_stage_id text,
                                                 p_outcome text)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_outcome is null or p_outcome not in ('won', 'lost', 'none') then
    raise exception 'an outcome is won, lost or none, not %', coalesce(p_outcome, 'nothing') using errcode = 'CMA04';
  end if;
  if p_record_type is distinct from 'deal' then
    raise exception 'only a deal stage has an outcome, not a % stage', p_record_type using errcode = 'CMA04';
  end if;
  update cma.connection_stage cs
     set outcome = nullif(p_outcome, 'none'), outcome_source = 'person'
   where cs.tenant_id = v_tenant and cs.connection_id = p_connection_id and cs.record_type = p_record_type
     and cs.source_pipeline_id = p_pipeline_id and cs.source_stage_id = p_stage_id;
  if not found then
    raise exception 'no stage % in pipeline % of connection %', p_stage_id, p_pipeline_id, p_connection_id using errcode = 'CMA02';
  end if;
end
$$;

-- As 0006, and a stage may give its outcome (outcome: won, lost or null): stored with source 'source'
-- unless a person chose the stage's outcome; a stage item without the key keeps the stored outcome (an
-- adapter that does not read outcomes changes nothing). Anything else CMA04
create or replace function cma.ingest_upsert_pipelines(p_connection_id uuid, p_pipelines jsonb)
returns integer
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  p         jsonb;
  s         jsonb;
  v_n       integer;
  v_outcome text;
  v_has     boolean;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_pipelines is null or jsonb_typeof(p_pipelines) <> 'array' then
    raise exception 'pipelines must be an array' using errcode = 'CMA04';
  end if;
  for p in select value from jsonb_array_elements(p_pipelines) loop
    if coalesce(p ->> 'recordType', '') !~ '^[a-z][a-z0-9_]*$' or coalesce(p ->> 'pipelineId', '') = ''
       or jsonb_typeof(p -> 'stages') is distinct from 'array' then
      raise exception 'every pipeline needs recordType, pipelineId and a stages array' using errcode = 'CMA04';
    end if;
    insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, status, refreshed_at)
    values (v_tenant, p_connection_id, p ->> 'recordType', p ->> 'pipelineId',
            coalesce(nullif(btrim(p ->> 'label'), ''), p ->> 'pipelineId'), 'active', now())
    on conflict (tenant_id, connection_id, record_type, source_pipeline_id)
      do update set label = excluded.label, status = 'active', refreshed_at = now();
    for s in select value from jsonb_array_elements(p -> 'stages') loop
      if coalesce(s ->> 'stageId', '') = '' or jsonb_typeof(s -> 'isClosed') is distinct from 'boolean' then
        raise exception 'every stage needs stageId and isClosed' using errcode = 'CMA04';
      end if;
      v_has := s ? 'outcome';
      v_outcome := s ->> 'outcome';
      if v_has and jsonb_typeof(s -> 'outcome') not in ('string', 'null') or v_outcome not in ('won', 'lost') then
        raise exception 'a stage''s outcome is won, lost or null, not %', s -> 'outcome' using errcode = 'CMA04';
      end if;
      insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id,
                                        label, display_order, is_closed, status, refreshed_at, outcome, outcome_source)
      values (v_tenant, p_connection_id, p ->> 'recordType', p ->> 'pipelineId', s ->> 'stageId',
              coalesce(nullif(btrim(s ->> 'label'), ''), s ->> 'stageId'), coalesce((s ->> 'order')::integer, 0),
              (s ->> 'isClosed')::boolean, 'active', now(), v_outcome, case when v_outcome is not null then 'source' end)
      on conflict (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id)
        do update set label = excluded.label, display_order = excluded.display_order,
                      is_closed = excluded.is_closed, status = 'active', refreshed_at = now(),
                      outcome = case when not v_has or cma.connection_stage.outcome_source = 'person' then cma.connection_stage.outcome
                                     else excluded.outcome end,
                      outcome_source = case when not v_has or cma.connection_stage.outcome_source = 'person' then cma.connection_stage.outcome_source
                                            else excluded.outcome_source end;
    end loop;
    update cma.connection_stage cs
       set status = 'archived'
     where cs.tenant_id = v_tenant and cs.connection_id = p_connection_id
       and cs.record_type = p ->> 'recordType' and cs.source_pipeline_id = p ->> 'pipelineId'
       and cs.status = 'active'
       and not exists (select 1 from jsonb_array_elements(p -> 'stages') x where x ->> 'stageId' = cs.source_stage_id);
  end loop;

  update cma.crm_record cr
     set is_closed = cs.is_closed,
         closed_at = case when cs.is_closed then coalesce(cr.closed_at, now()) end
    from cma.connection_stage cs
   where cr.tenant_id = v_tenant and cr.connection_id = p_connection_id
     and cs.tenant_id = cr.tenant_id and cs.connection_id = cr.connection_id and cs.record_type = cr.record_type
     and cs.source_pipeline_id = cr.pipeline_id and cs.source_stage_id = cr.stage_id
     and cr.is_closed is distinct from cs.is_closed;
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

-- As 0008t, and each pipeline gives isOrder and its stages (id, label, order, closed, outcome and where
-- the outcome comes from, status) in display order
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
                                                                    'status', st.status)
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
-- 3. A contact's creation time
-- ---------------------------------------------------------------------------------------------
-- The canonical field created_at on contacts: slot 1 is the object's own creation time and takes no
-- property; slots 2 to 9 are properties read as well (contiguous from 2, as 0008m's country slots)
alter table cma.connection_field drop constraint if exists connection_field_field_check;
alter table cma.connection_field add constraint connection_field_field_check
  check (field = any (array['market', 'language', 'country', 'currency', 'store', 'amount', 'source_channel', 'category', 'ref', 'created_at']));
alter table cma.connection_field drop constraint if exists connection_field_entity_field_check;
alter table cma.connection_field add constraint connection_field_entity_field_check
  check (case when entity = 'contact' then field = any (array['country', 'language', 'currency', 'store', 'ref', 'created_at'])
              else field = any (array['market', 'language', 'currency', 'amount', 'source_channel', 'category']) end);
alter table cma.connection_field drop constraint if exists connection_field_slot_check;
alter table cma.connection_field add constraint connection_field_slot_check
  check (slot between 1 and 9
         and (slot = 1 or field = 'ref' or (entity = 'contact' and field in ('country', 'created_at')))
         and (field <> 'created_at' or slot >= 2));

alter table cma.crm_contact add column if not exists source_created_at timestamptz;
comment on column cma.crm_contact.source_created_at is
  'When the contact was created at the source (0008u): the earliest of its own creation time and the created_at slots 2 to 9 the connection maps; null when none is known';

-- As 0008m, plus created_at on contacts: slot 1 is the object's creation time, so a property goes to
-- slots 2 to 9, contiguous from 2, removed from the end, one property per slot
create or replace function cma.set_connection_field(p_connection_id uuid, p_entity text, p_field text,
                                                    p_ref_system text, p_source_property text, p_slot smallint)
returns void
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_slot    smallint := coalesce(p_slot, 1);
  v_slotted boolean := p_entity = 'contact' and p_field in ('country', 'created_at');
  v_first   smallint := case when p_entity = 'contact' and p_field = 'created_at' then 2 else 1 end;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_entity = 'contact' and p_field = 'created_at' and v_slot < 2 then
    raise exception 'created_at slot 1 is the contact''s own creation time and takes no property: map slots 2 to 9' using errcode = 'CMA04';
  end if;
  if coalesce(btrim(p_source_property), '') = '' then
    if v_slotted and exists (select 1 from cma.connection_field f
                             where f.tenant_id = v_tenant and f.connection_id = p_connection_id
                               and f.entity = 'contact' and f.field = p_field and f.slot > v_slot) then
      raise exception '% slot % cannot go while a later slot maps a property: remove the last slot first', p_field, v_slot
        using errcode = 'CMA04';
    end if;
    delete from cma.connection_field f
    where f.tenant_id = v_tenant and f.connection_id = p_connection_id
      and f.entity = p_entity and f.field = p_field and f.ref_system = coalesce(p_ref_system, '')
      and f.slot = v_slot;
    return;
  end if;
  if v_slotted and v_slot > v_first
     and not exists (select 1 from cma.connection_field f
                     where f.tenant_id = v_tenant and f.connection_id = p_connection_id
                       and f.entity = 'contact' and f.field = p_field and f.slot = v_slot - 1) then
    raise exception '% slot % needs slot % first: the slots are contiguous', p_field, v_slot, v_slot - 1 using errcode = 'CMA04';
  end if;
  if v_slotted and exists (select 1 from cma.connection_field f
                           where f.tenant_id = v_tenant and f.connection_id = p_connection_id
                             and f.entity = 'contact' and f.field = p_field and f.slot <> v_slot
                             and lower(f.source_property) = lower(btrim(p_source_property))) then
    raise exception 'the property % already feeds another % slot of this connection', btrim(p_source_property), p_field
      using errcode = 'CMA03';
  end if;
  insert into cma.connection_field (tenant_id, connection_id, entity, field, ref_system, slot, source_property)
  values (v_tenant, p_connection_id, p_entity, p_field, coalesce(p_ref_system, ''), v_slot, btrim(p_source_property))
  on conflict (tenant_id, connection_id, entity, field, ref_system, slot)
    do update set source_property = excluded.source_property;
exception when check_violation or not_null_violation then
  raise exception 'invalid field mapping (%, %, %, slot %): %', p_entity, p_field, p_ref_system, p_slot, sqlerrm using errcode = 'CMA04';
end
$$;

-- As 0008n, plus the creation time: createdAt (the object's own, slot 1) or createdAts (element n is
-- slot n, each an ISO time or null); the earliest non-empty is stored. A read without either keeps the
-- stored time (an adapter that does not send it changes nothing); a deletion clears it with the other
-- attributes
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
  v_has_cr   boolean;
  v_created  timestamptz;
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
    -- the creation time: one value or one per slot, the earliest non-empty
    v_has_cr := c ? 'createdAt' or c ? 'createdAts';
    if c ? 'createdAts' then
      if c ? 'createdAt' then
        raise exception 'a contact gives createdAt or createdAts, not both' using errcode = 'CMA04';
      end if;
      if jsonb_typeof(c -> 'createdAts') <> 'array' or jsonb_array_length(c -> 'createdAts') > 9 then
        raise exception 'createdAts must be a list of at most 9 values, each an ISO time or null' using errcode = 'CMA04';
      end if;
      select min(cma.json_time(e.x, 'createdAts')) into v_created from jsonb_array_elements(c -> 'createdAts') as e(x);
    else
      v_created := cma.json_time(c -> 'createdAt', 'createdAt');
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
               source_created_at = null, source_deleted_at = v_deleted, synced_at = now()
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
                                   store, source_updated_at, source_created_at, raw)
      values (v_tenant, p_connection_id, v_system, v_src, v_country, v_csource, nullif(btrim(c ->> 'language'), ''),
              cma.json_currency(c ->> 'currency'), v_store, v_updated, v_created, coalesce(c -> 'raw', '{}'::jsonb))
      returning id into v_id;
    else
      v_id := v_old.id;
      update cma.crm_contact cc
         set country = v_country, country_source = v_csource, language = nullif(btrim(c ->> 'language'), ''),
             currency = cma.json_currency(c ->> 'currency'), store = v_store,
             source_created_at = case when v_has_cr then v_created else cc.source_created_at end,
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

-- ---------------------------------------------------------------------------------------------
-- 4. The definition: every order deal of a period
-- ---------------------------------------------------------------------------------------------
-- One row per order deal created in [p_from, p_to) (see the header for every rule). The evidence, the
-- level, the attribution, the touches and the credited person are there for first orders only; the
-- other kinds carry their kind and their order, nothing else
create or replace function cma.first_orders_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  deal_id                uuid,
  connection_id          uuid,
  source_system          text,
  deal_source_id         text,
  pipeline_id            text,
  pipeline_label         text,
  contact_source_id      text,
  created_at             timestamptz,
  market                 text,
  zone                   text,
  business_date          date,
  week_start             date,
  local_time             time,
  kind                   text,
  order_id               uuid,
  order_source_id        text,
  store_order_kind       text,
  currency               text,
  amount                 numeric,
  phone_hashed           boolean,
  lead_deal              boolean,
  conversation           boolean,
  email                  boolean,
  phone_match            boolean,
  attempt                boolean,
  known_contact          boolean,
  level                  text,
  attribution            text,
  first_touch_at         timestamptz,
  days_from_first_touch  numeric,
  credited_system        text,
  credited_owner_ref     text,
  credited_user_id       uuid
)
language sql stable
set jit = off
as $$
  with s as (
    select t.timezone as tenant_zone,
           make_interval(days => cma.setting_of(t.id, 'attribution.window_days')::integer) as win,
           string_to_array(cma.setting_of(t.id, 'attribution.level_order'), ',') as level_order,
           coalesce(string_to_array(nullif(cma.setting_of(t.id, 'attribution.assisted_levels'), ''), ','), '{}'::text[]) as assisted,
           make_interval(mins => cma.setting_of(t.id, 'attribution.known_contact_minutes')::integer) as known,
           make_interval(mins => cma.setting_of(t.id, 'attribution.order_match_minutes')::integer) as match
    from cma.tenant t where t.id = p_tenant_id
  ),
  -- the won deals of the order pipelines created in the period, with their contact
  d as materialized (
    select r.id, r.connection_id, r.source_system, r.source_id, r.pipeline_id, coalesce(p.label, r.pipeline_id) as pipeline_label,
           r.source_created_at as t, r.market as own_market, r.amount as deal_amount, r.currency as deal_currency,
           coalesce(r.contact_source_id,
                    (select a.to_id from cma.crm_association a
                     where a.tenant_id = r.tenant_id and a.connection_id = r.connection_id and a.from_type = 'deal'
                       and a.from_id = r.source_id and a.to_type = 'contact' and a.removed_at is null
                     order by a.first_seen_at, a.to_id limit 1)) as contact
    from cma.crm_record r
    join cma.connection_pipeline p
      on p.tenant_id = r.tenant_id and p.connection_id = r.connection_id and p.record_type = r.record_type
     and p.source_pipeline_id = r.pipeline_id and p.is_order and p.is_counted
    join cma.connection_stage st
      on st.tenant_id = r.tenant_id and st.connection_id = r.connection_id and st.record_type = r.record_type
     and st.source_pipeline_id = r.pipeline_id and st.source_stage_id = r.stage_id and st.outcome = 'won'
    where r.tenant_id = p_tenant_id and r.record_type = 'deal' and r.source_deleted_at is null
      and r.source_created_at >= p_from and r.source_created_at < p_to
  ),
  -- the market, the linked order and the kind
  k as materialized (
    select d.*, rm.code as market, coalesce(mk.time_zone, s.tenant_zone) as zone,
           o.order_id, o.order_source_id, o.order_kind as store_order_kind, o.currency as order_currency, o.amount as order_amount,
           o.hashes,
           case when d.contact is null then 'no_contact'
                when o.order_kind = 'renewal' then 'renewal'
                when exists (select 1
                             from cma.crm_record r2
                             join cma.connection_pipeline p2
                               on p2.tenant_id = r2.tenant_id and p2.connection_id = r2.connection_id and p2.record_type = r2.record_type
                              and p2.source_pipeline_id = r2.pipeline_id and p2.is_order and p2.is_counted
                             join cma.connection_stage st2
                               on st2.tenant_id = r2.tenant_id and st2.connection_id = r2.connection_id and st2.record_type = r2.record_type
                              and st2.source_pipeline_id = r2.pipeline_id and st2.source_stage_id = r2.stage_id and st2.outcome = 'won'
                             where r2.tenant_id = p_tenant_id and r2.connection_id = d.connection_id and r2.record_type = 'deal'
                               and r2.contact_source_id = d.contact and r2.source_deleted_at is null
                               and (r2.source_created_at < d.t or (r2.source_created_at = d.t and r2.id < d.id)))
                  or exists (select 1
                             from cma.crm_association a2
                             join cma.crm_record r2
                               on r2.tenant_id = a2.tenant_id and r2.connection_id = a2.connection_id and r2.record_type = 'deal'
                              and r2.source_id = a2.from_id and r2.source_deleted_at is null
                             join cma.connection_pipeline p2
                               on p2.tenant_id = r2.tenant_id and p2.connection_id = r2.connection_id and p2.record_type = r2.record_type
                              and p2.source_pipeline_id = r2.pipeline_id and p2.is_order and p2.is_counted
                             join cma.connection_stage st2
                               on st2.tenant_id = r2.tenant_id and st2.connection_id = r2.connection_id and st2.record_type = r2.record_type
                              and st2.source_pipeline_id = r2.pipeline_id and st2.source_stage_id = r2.stage_id and st2.outcome = 'won'
                             where a2.tenant_id = p_tenant_id and a2.connection_id = d.connection_id and a2.from_type = 'deal'
                               and a2.to_type = 'contact' and a2.to_id = d.contact and a2.removed_at is null
                               and (r2.source_created_at < d.t or (r2.source_created_at = d.t and r2.id < d.id)))
                  then 'repeat'
                when o.order_kind = 'repeat' then 'not_first'
                else 'first' end as kind
    from d
    cross join s
    cross join lateral cma.record_market_of(p_tenant_id, d.connection_id, d.own_market, d.contact) rm
    left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = rm.code
    left join lateral (
      select co.id as order_id, co.source_id as order_source_id, co.order_kind, co.currency, co.total_amount as amount,
             array_remove(array[co.phone_hash, cu.phone_hash], null) as hashes
      from cma.commerce_customer cu
      join cma.commerce_order co
        on co.tenant_id = cu.tenant_id and co.connection_id = cu.connection_id and co.customer_source_id = cu.source_id
      where cu.tenant_id = p_tenant_id and cu.crm_connection_id = d.connection_id and cu.crm_contact_source_id = d.contact
        and not co.is_test and co.cancelled_at is null and co.source_deleted_at is null
        and co.source_created_at >= d.t - s.match and co.source_created_at <= d.t + s.match
      order by abs(extract(epoch from co.source_created_at - d.t)), co.source_created_at, co.id
      limit 1) o on true
  ),
  -- the touches of each first order in its window
  x as (
    select k.id, tt.touch, tt.at, tt.sys, tt.owner_ref
    from k
    cross join s
    cross join lateral (
      -- lead deals of the contact: primary contact
      select 'lead_deal'::text as touch, r3.source_created_at as at, r3.source_system || '_owner' as sys, r3.owner_ref
      from cma.crm_record r3
      left join cma.connection_pipeline p3
        on p3.tenant_id = r3.tenant_id and p3.connection_id = r3.connection_id and p3.record_type = r3.record_type
       and p3.source_pipeline_id = r3.pipeline_id
      where r3.tenant_id = p_tenant_id and r3.connection_id = k.connection_id and r3.record_type = 'deal'
        and r3.contact_source_id = k.contact and r3.source_deleted_at is null and r3.id <> k.id
        and coalesce(p3.is_counted, true) and coalesce(p3.is_lead, true) and not coalesce(p3.is_order, false)
        and r3.source_created_at >= k.t - s.win and r3.source_created_at < k.t
      union all
      -- lead deals of the contact: a current association
      select 'lead_deal', r3.source_created_at, r3.source_system || '_owner', r3.owner_ref
      from cma.crm_association a3
      join cma.crm_record r3
        on r3.tenant_id = a3.tenant_id and r3.connection_id = a3.connection_id and r3.record_type = 'deal' and r3.source_id = a3.from_id
      left join cma.connection_pipeline p3
        on p3.tenant_id = r3.tenant_id and p3.connection_id = r3.connection_id and p3.record_type = r3.record_type
       and p3.source_pipeline_id = r3.pipeline_id
      where a3.tenant_id = p_tenant_id and a3.connection_id = k.connection_id and a3.from_type = 'deal' and a3.to_type = 'contact'
        and a3.to_id = k.contact and a3.removed_at is null
        and r3.contact_source_id is distinct from k.contact and r3.source_deleted_at is null and r3.id <> k.id
        and coalesce(p3.is_counted, true) and coalesce(p3.is_lead, true) and not coalesce(p3.is_order, false)
        and r3.source_created_at >= k.t - s.win and r3.source_created_at < k.t
      union all
      -- calls with the contact: a conversation, else an attempt
      select case when cc.is_connected then 'conversation' else 'attempt' end, cc.effective_at, c.source_system || '_owner', c.owner_ref
      from cma.crm_association a4
      join cma.crm_call c
        on c.tenant_id = a4.tenant_id and c.connection_id = a4.connection_id and c.source_id = a4.from_id and c.source_deleted_at is null
      cross join lateral cma.crm_call_connected_of(p_tenant_id, c.id) cc
      where a4.tenant_id = p_tenant_id and a4.connection_id = k.connection_id and a4.from_type = 'crm_call' and a4.to_type = 'contact'
        and a4.to_id = k.contact and a4.removed_at is null
        and cc.effective_at >= k.t - s.win and cc.effective_at < k.t
      union all
      -- agent emails to the contact: the message's own contact, its conversation's, or an engagement's association
      select 'email', em.occurred_at, em.source_system || '_owner', em.owner_ref
      from (select em1.id from cma.email_message em1
            where em1.tenant_id = p_tenant_id and em1.connection_id = k.connection_id and em1.contact_source_id = k.contact
            union
            select em2.id from cma.email_thread th2
            join cma.email_message em2
              on em2.tenant_id = th2.tenant_id and em2.connection_id = th2.connection_id and em2.thread_source_id = th2.source_id
            where th2.tenant_id = p_tenant_id and th2.connection_id = k.connection_id and th2.contact_source_id = k.contact
            union
            select em3.id from cma.crm_association a5
            join cma.email_message em3
              on em3.tenant_id = a5.tenant_id and em3.connection_id = a5.connection_id and em3.source_kind = 'crm_email'
             and em3.source_id = a5.from_id
            where a5.tenant_id = p_tenant_id and a5.connection_id = k.connection_id and a5.from_type = 'crm_email'
              and a5.to_type = 'contact' and a5.to_id = k.contact and a5.removed_at is null) ids
      join cma.email_message em on em.tenant_id = p_tenant_id and em.id = ids.id
      join cma.integration_connection ic on ic.tenant_id = em.tenant_id and ic.id = em.connection_id
      left join cma.email_thread th
        on th.tenant_id = em.tenant_id and th.connection_id = em.connection_id and th.source_id = em.thread_source_id
      where em.direction = 'out' and em.status = 'sent' and em.source_deleted_at is null
        and em.occurred_at >= k.t - s.win and em.occurred_at < k.t
        and case when em.source_kind = 'inbox_message'
                 then em.actor_kind not in ('bot', 'ai', 'system', 'integration') and not coalesce(th.is_spam, false)
                 else not (lower(coalesce(em.origin, '')) = any (cma.setting_codes(ic.settings, 'email_inbox_copy_origins')))
                      and not (lower(coalesce(em.origin, '')) = any (cma.setting_codes(ic.settings, 'email_automated_origins'))) end
      union all
      -- a CRM call from the order's phone number, any contact
      select 'phone_match', cc.effective_at, c.source_system || '_owner', c.owner_ref
      from cma.crm_call c
      cross join lateral cma.crm_call_connected_of(p_tenant_id, c.id) cc
      where cardinality(k.hashes) > 0 and c.tenant_id = p_tenant_id and c.counterpart_hash = any (k.hashes)
        and c.source_deleted_at is null and cc.effective_at >= k.t - s.win and cc.effective_at < k.t
      union all
      -- a telephony call from the order's phone number, any contact
      select 'phone_match', tc.started_at, tc.source_system || '_user', tc.user_ref
      from cma.telephony_call tc
      where cardinality(k.hashes) > 0 and tc.tenant_id = p_tenant_id and tc.counterpart_hash = any (k.hashes)
        and tc.source_deleted_at is null and tc.started_at >= k.t - s.win and tc.started_at < k.t
    ) tt
    where k.kind = 'first'
  ),
  f as (
    select k.id,
           coalesce(bool_or(x.touch = 'lead_deal'), false) as f_lead,
           coalesce(bool_or(x.touch = 'conversation'), false) as f_conv,
           coalesce(bool_or(x.touch = 'email'), false) as f_email,
           coalesce(bool_or(x.touch = 'phone_match'), false) as f_phone,
           coalesce(bool_or(x.touch = 'attempt'), false) as f_attempt,
           coalesce((select kc.source_created_at <= k.t - s.known
                     from cma.crm_contact kc
                     where kc.tenant_id = p_tenant_id and kc.connection_id = k.connection_id and kc.source_id = k.contact), false) as f_known,
           min(x.at) as first_at,
           (array_agg(x.sys order by x.at desc, x.touch, x.owner_ref) filter (where x.touch = any (s.assisted)))[1] as c_sys,
           (array_agg(x.owner_ref order by x.at desc, x.touch, x.owner_ref) filter (where x.touch = any (s.assisted)))[1] as c_owner
    from k
    cross join s
    left join x on x.id = k.id
    where k.kind = 'first'
    group by k.id, k.t, k.connection_id, k.contact, s.known
  ),
  l as (
    select f.*,
           coalesce((select u.lv
                     from unnest(s.level_order) with ordinality as u(lv, i)
                     where case u.lv when 'lead_deal' then f.f_lead when 'conversation' then f.f_conv when 'email' then f.f_email
                                     when 'phone_match' then f.f_phone when 'attempt' then f.f_attempt when 'known_contact' then f.f_known
                                     else false end
                     order by u.i limit 1), 'self_service') as lv,
           s.assisted
    from f cross join s
  )
  select k.id, k.connection_id, k.source_system, k.source_id, k.pipeline_id, k.pipeline_label, k.contact, k.t, k.market, k.zone,
         (k.t at time zone k.zone)::date,
         date_trunc('week', (k.t at time zone k.zone)::date::timestamp)::date,
         (k.t at time zone k.zone)::time,
         k.kind, k.order_id, k.order_source_id, k.store_order_kind,
         case when k.order_id is not null then k.order_currency else k.deal_currency end,
         case when k.order_id is not null then k.order_amount else k.deal_amount end,
         cardinality(k.hashes) > 0,
         l.f_lead, l.f_conv, l.f_email, l.f_phone, l.f_attempt, l.f_known,
         l.lv,
         case when l.id is null then null when l.lv = any (l.assisted) then 'call_center' else 'self_service' end,
         l.first_at,
         case when l.first_at is not null then round((extract(epoch from k.t - l.first_at) / 86400)::numeric, 2) end,
         l.c_sys, l.c_owner,
         (select xi.user_id from cma.app_user_external_id xi
          where xi.tenant_id = p_tenant_id and xi.system = l.c_sys and xi.external_id = l.c_owner)
  from k
  left join l on l.id = k.id
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The reads of an explicit tenant
-- ---------------------------------------------------------------------------------------------
-- The figures of business dates [p_from, p_to] (each deal's own market zone), cut on p_to at p_until's
-- time of day in each zone (the previous span, like for like), narrowed by market and level, per
-- dimension asked for (day, week, market, level) and the total. A level filter keeps first orders of
-- that level only, so the kinds counted apart are 0 with it
create or replace function cma.first_orders_figures_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_level text,
                                                       p_dimensions text[], p_until timestamptz default null)
returns table (
  dimension          text,
  group_key          text,
  first_orders       integer,
  call_center        integer,
  self_service       integer,
  repeats            integer,
  renewals           integer,
  not_first          integer,
  no_contact         integer,
  with_touch         integer,
  days_median        numeric
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  b as (select (p_from - 1)::timestamp at time zone s.zone as from_at, (p_to + 2)::timestamp at time zone s.zone as to_at from s),
  o as materialized (
    select x.* from b cross join lateral cma.first_orders_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to
      and (p_until is null or x.business_date < p_to or x.local_time <= (p_until at time zone x.zone)::time)
      and (p_market is null or x.market = p_market)
      and (p_level is null or x.level = p_level)
  ),
  g as (
    select dd.dim, dd.k, o.*
    from o
    cross join lateral (
      values ('total', null::text),
             ('day', o.business_date::text),
             ('week', o.week_start::text),
             ('market', o.market),
             ('level', o.level)) as dd(dim, k)
    where dd.dim = 'total' or (dd.dim = any (p_dimensions) and (dd.dim <> 'level' or o.kind = 'first'))
  ),
  agg as (
    select g.dim, g.k,
           (count(*) filter (where g.kind = 'first'))::integer as first_orders,
           (count(*) filter (where g.attribution = 'call_center'))::integer as call_center,
           (count(*) filter (where g.attribution = 'self_service'))::integer as self_service,
           (count(*) filter (where g.kind = 'repeat'))::integer as repeats,
           (count(*) filter (where g.kind = 'renewal'))::integer as renewals,
           (count(*) filter (where g.kind = 'not_first'))::integer as not_first,
           (count(*) filter (where g.kind = 'no_contact'))::integer as no_contact,
           (count(*) filter (where g.kind = 'first' and g.first_touch_at is not null))::integer as with_touch,
           percentile_cont(0.5) within group (order by g.days_from_first_touch)
             filter (where g.kind = 'first' and g.days_from_first_touch is not null) as dm
    from g
    group by g.dim, g.k
  )
  select a.dim, a.k, a.first_orders, a.call_center, a.self_service, a.repeats, a.renewals, a.not_first, a.no_contact, a.with_touch,
         round(a.dm::numeric, 1)
  from agg a
  union all
  -- the total is there even for a period without anything
  select 'total', null, 0, 0, 0, 0, 0, 0, 0, 0, null
  where not exists (select 1 from agg where agg.dim = 'total')
  order by 1, 2
$$;

-- The report page in one read: the period per p_group (day, week, market or level), per market and per
-- level, and the total ('current'); then the previous period's total ('previous'), like for like
-- (cma.forms_previous_of, as 0008j, 0008p and 0008t). p_now is now() for the application; a verifier
-- gives a fixed instant
create or replace function cma.first_orders_report_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_market text, p_level text,
                                                      p_now timestamptz default now())
returns table (
  period             text,
  dimension          text,
  group_key          text,
  first_orders       integer,
  call_center        integer,
  self_service       integer,
  repeats            integer,
  renewals           integer,
  not_first          integer,
  no_contact         integer,
  with_touch         integer,
  days_median        numeric
)
language sql stable
as $$
  select x.period, x.dimension, x.group_key, x.first_orders, x.call_center, x.self_service, x.repeats, x.renewals, x.not_first,
         x.no_contact, x.with_touch, x.days_median
  from (
    select 'current'::text as period, 1 as part, f.*
    from cma.first_orders_figures_of(p_tenant_id, p_from, p_to, p_market, p_level, array[p_group, 'market', 'level']) f
    union all
    select 'previous', 2, f.*
    from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now) v
    cross join lateral cma.first_orders_figures_of(p_tenant_id, v.prev_from, v.prev_to, p_market, p_level, '{}'::text[], v.until) f
  ) x
  order by x.part, x.dimension, x.group_key
$$;

-- The first orders' amounts per currency (never summed across currencies), in total and per market, with
-- the call-center and self-service parts; first orders without a currency (no store order and no deal
-- amount) come as currency 'none' without an amount
create or replace function cma.first_orders_amounts_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_level text)
returns table (
  dimension              text,
  group_key              text,
  currency               text,
  orders                 integer,
  amount                 numeric,
  call_center_amount     numeric,
  self_service_amount    numeric
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  b as (select (p_from - 1)::timestamp at time zone s.zone as from_at, (p_to + 2)::timestamp at time zone s.zone as to_at from s),
  o as (
    select x.* from b cross join lateral cma.first_orders_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to and x.kind = 'first'
      and (p_market is null or x.market = p_market)
      and (p_level is null or x.level = p_level)
  )
  select dd.dim, dd.k, coalesce(o.currency, 'none'), count(*)::integer, sum(o.amount),
         coalesce(sum(o.amount) filter (where o.attribution = 'call_center'), 0),
         coalesce(sum(o.amount) filter (where o.attribution = 'self_service'), 0)
  from o
  cross join lateral (values ('total', null::text), ('market', o.market)) as dd(dim, k)
  group by dd.dim, dd.k, coalesce(o.currency, 'none')
  order by 1, 2, 3
$$;

-- Per credited person (performance.team and reports.per_person holding orders): the first orders whose
-- latest assisted touch was theirs, through the linked accounts; touches of an owner id without a person
-- (or without an owner) as one not-linked row with how many owner ids that is, never which; the first
-- orders via the call center without a credited touch are not here (none, for a level other than the
-- assisted ones). By name, never ranked; then the total
create or replace function cma.first_orders_per_person_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_level text)
returns table (
  row_kind           text,
  user_id            uuid,
  display_name       text,
  unlinked_owners    integer,
  orders             integer,
  lead_deal          integer,
  conversation       integer,
  email              integer,
  phone_match        integer,
  other_levels       integer,
  days_median        numeric
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  b as (select (p_from - 1)::timestamp at time zone s.zone as from_at, (p_to + 2)::timestamp at time zone s.zone as to_at from s),
  o as (
    select x.*, case when u.id is null then 'not_linked' else 'person' end as rk, u.id as uid, u.display_name as uname
    from b cross join lateral cma.first_orders_of(p_tenant_id, b.from_at, b.to_at) x
    left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = x.credited_user_id
    where x.business_date between p_from and p_to and x.kind = 'first' and x.attribution = 'call_center'
      and (p_market is null or x.market = p_market)
      and (p_level is null or x.level = p_level)
  )
  select coalesce(o.rk, 'total'), o.uid, o.uname,
         case when o.rk = 'not_linked' then (count(distinct o.credited_owner_ref))::integer end,
         count(*)::integer,
         (count(*) filter (where o.level = 'lead_deal'))::integer,
         (count(*) filter (where o.level = 'conversation'))::integer,
         (count(*) filter (where o.level = 'email'))::integer,
         (count(*) filter (where o.level = 'phone_match'))::integer,
         (count(*) filter (where o.level not in ('lead_deal', 'conversation', 'email', 'phone_match')))::integer,
         round((percentile_cont(0.5) within group (order by o.days_from_first_touch) filter (where o.days_from_first_touch is not null))::numeric, 1)
  from o
  group by grouping sets ((o.rk, o.uid, o.uname), ())
  order by grouping(o.rk), o.rk = 'not_linked', o.uname, o.uid
$$;

-- The history: from the later of intake.start_date + attribution.window_days (the first date whose window
-- the stored data covers) and the earliest stored order deal's date (the tenant's zone); null without an
-- order deal. The phone tier's own start: the earliest stored store order carrying a phone hash (its own
-- or its customer's), the tenant's zone; null without one
create or replace function cma.first_orders_history_start_of(p_tenant_id uuid, out history_start date, out phone_start date)
language sql stable
as $$
  with s as (
    select t.timezone as zone, cma.setting_of(t.id, 'intake.start_date')::date as intake_start,
           cma.setting_of(t.id, 'attribution.window_days')::integer as win
    from cma.tenant t where t.id = p_tenant_id
  ),
  od as (
    select min(r.source_created_at) as first_at
    from cma.crm_record r
    join cma.connection_pipeline p
      on p.tenant_id = r.tenant_id and p.connection_id = r.connection_id and p.record_type = r.record_type
     and p.source_pipeline_id = r.pipeline_id and p.is_order and p.is_counted
    join cma.connection_stage st
      on st.tenant_id = r.tenant_id and st.connection_id = r.connection_id and st.record_type = r.record_type
     and st.source_pipeline_id = r.pipeline_id and st.source_stage_id = r.stage_id and st.outcome = 'won'
    where r.tenant_id = p_tenant_id and r.record_type = 'deal' and r.source_deleted_at is null
  ),
  ph as (
    select min(co.source_created_at) as first_at
    from cma.commerce_order co
    left join cma.commerce_customer cu
      on cu.tenant_id = co.tenant_id and cu.connection_id = co.connection_id and cu.source_id = co.customer_source_id
    where co.tenant_id = p_tenant_id and not co.is_test and co.source_deleted_at is null
      and (co.phone_hash is not null or cu.phone_hash is not null)
  )
  select case when od.first_at is not null
              then greatest(s.intake_start + s.win, (od.first_at at time zone s.zone)::date) end,
         (ph.first_at at time zone s.zone)::date
  from s cross join od cross join ph
$$;

-- Whether the tenant has the source: an order pipeline (else "No order pipeline connected", never 0)
create or replace function cma.first_orders_connected_of(p_tenant_id uuid)
returns boolean
language sql stable
as $$
  select exists (select 1 from cma.connection_pipeline p where p.tenant_id = p_tenant_id and p.is_order and p.is_counted)
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The application's reads (permission checked, filters checked, current tenant, row-level security)
-- ---------------------------------------------------------------------------------------------
-- The filters every read takes: a market is a two-letter code or 'unknown'; a level one of the six or
-- self_service. Anything else CMA04
create or replace function cma.first_orders_filters_check(p_market text, p_level text)
returns void
language plpgsql immutable
as $$
begin
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'a market filter is a market code or unknown, not %', p_market using errcode = 'CMA04';
  end if;
  if p_level is not null and p_level not in ('lead_deal', 'conversation', 'email', 'phone_match', 'attempt', 'known_contact', 'self_service') then
    raise exception 'a level filter is lead_deal, conversation, email, phone_match, attempt, known_contact or self_service, not %', p_level
      using errcode = 'CMA04';
  end if;
end
$$;

create or replace function cma.first_orders_report(p_from date, p_to date, p_group text, p_market text, p_level text)
returns table (
  period             text,
  dimension          text,
  group_key          text,
  first_orders       integer,
  call_center        integer,
  self_service       integer,
  repeats            integer,
  renewals           integer,
  not_first          integer,
  no_contact         integer,
  with_touch         integer,
  days_median        numeric
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'week', 'market', 'level') then
    raise exception 'group by day, week, market or level, not %', p_group using errcode = 'CMA04';
  end if;
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.first_orders_filters_check(p_market, p_level);
  return query select * from cma.first_orders_report_of(v_tenant, p_from, p_to, p_group, p_market, p_level);
end
$$;

create or replace function cma.first_orders_amounts(p_from date, p_to date, p_market text, p_level text)
returns table (
  dimension              text,
  group_key              text,
  currency               text,
  orders                 integer,
  amount                 numeric,
  call_center_amount     numeric,
  self_service_amount    numeric
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.first_orders_filters_check(p_market, p_level);
  return query select * from cma.first_orders_amounts_of(v_tenant, p_from, p_to, p_market, p_level);
end
$$;

-- The first orders of the period, newest first: the first follow_up.list_rows rows after the filters (or
-- p_rows, held within 1 to 500), each with the filtered total and the deal's record link
create or replace function cma.first_orders_list(p_from date, p_to date, p_market text, p_level text, p_rows integer default null)
returns table (
  connection_id          uuid,
  deal_source_id         text,
  market                 text,
  created_at             timestamptz,
  business_date          date,
  level                  text,
  attribution            text,
  lead_deal              boolean,
  conversation           boolean,
  email                  boolean,
  phone_match            boolean,
  attempt                boolean,
  known_contact          boolean,
  phone_hashed           boolean,
  has_order              boolean,
  currency               text,
  amount                 numeric,
  days_from_first_touch  numeric,
  record_url             text,
  total_rows             integer
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_rows   integer;
  v_zone   text;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.first_orders_filters_check(p_market, p_level);
  v_rows := least(500, greatest(1, coalesce(p_rows, cma.setting_of(v_tenant, 'follow_up.list_rows')::integer)));
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;
  return query
    with o as (
      select x.* from cma.first_orders_of(v_tenant, (p_from - 1)::timestamp at time zone v_zone, (p_to + 2)::timestamp at time zone v_zone) x
      where x.business_date between p_from and p_to and x.kind = 'first'
        and (p_market is null or x.market = p_market)
        and (p_level is null or x.level = p_level)
    )
    select o.connection_id, o.deal_source_id, o.market, o.created_at, o.business_date, o.level, o.attribution, o.lead_deal, o.conversation,
           o.email, o.phone_match, o.attempt, o.known_contact, o.phone_hashed, o.order_id is not null, o.currency, o.amount,
           o.days_from_first_touch, cma.record_url(o.connection_id, 'deal', o.deal_source_id), (count(*) over ())::integer
    from o
    order by o.created_at desc, o.deal_source_id
    limit v_rows;
end
$$;

create or replace function cma.first_orders_per_person(p_from date, p_to date, p_market text, p_level text)
returns table (
  row_kind           text,
  user_id            uuid,
  display_name       text,
  unlinked_owners    integer,
  orders             integer,
  lead_deal          integer,
  conversation       integer,
  email              integer,
  phone_match        integer,
  other_levels       integer,
  days_median        numeric
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_per_person('orders');
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.first_orders_filters_check(p_market, p_level);
  return query select * from cma.first_orders_per_person_of(v_tenant, p_from, p_to, p_market, p_level);
end
$$;

-- The history start, the phone tier's start and whether an order pipeline is set
create or replace function cma.first_orders_history_start(out history_start date, out phone_start date, out connected boolean)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  select h.history_start, h.phone_start into history_start, phone_start from cma.first_orders_history_start_of(v_tenant) h;
  connected := cma.first_orders_connected_of(v_tenant);
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
    'cma.is_attribution_levels(text,boolean)',
    'cma.set_pipeline_order(uuid,text,text,boolean)',
    'cma.set_stage_outcome(uuid,text,text,text,text)',
    'cma.ingest_upsert_pipelines(uuid,jsonb)',
    'cma.connection_config(uuid)',
    'cma.set_connection_field(uuid,text,text,text,text,smallint)',
    'cma.ingest_upsert_contacts(uuid,jsonb)',
    'cma.first_orders_of(uuid,timestamptz,timestamptz)',
    'cma.first_orders_figures_of(uuid,date,date,text,text,text[],timestamptz)',
    'cma.first_orders_report_of(uuid,date,date,text,text,text,timestamptz)',
    'cma.first_orders_amounts_of(uuid,date,date,text,text)',
    'cma.first_orders_per_person_of(uuid,date,date,text,text)',
    'cma.first_orders_history_start_of(uuid)',
    'cma.first_orders_connected_of(uuid)',
    'cma.first_orders_filters_check(text,text)',
    'cma.first_orders_report(date,date,text,text,text)',
    'cma.first_orders_amounts(date,date,text,text)',
    'cma.first_orders_list(date,date,text,text,integer)',
    'cma.first_orders_per_person(date,date,text,text)',
    'cma.first_orders_history_start()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Reporting views
-- ---------------------------------------------------------------------------------------------
-- The earlier views with the new columns at the end (the earlier columns as they were)
create or replace view cma_read.crm_contact as
  select id, tenant_id, connection_id, source_system, source_id, country, language,
         source_updated_at, source_deleted_at, synced_at, currency, store, country_source, source_created_at
  from cma.crm_contact
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.connection_pipeline as
  select id, tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted, is_routed, work_type_skill_id, status,
         refreshed_at, is_lead, is_order
  from cma.connection_pipeline
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.connection_stage as
  select tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, display_order, is_closed, status,
         refreshed_at, outcome, outcome_source
  from cma.connection_stage
  where cma_read.reader_sees(tenant_id);

-- The order deals since each tenant's history start for readers, as 0008o's lists: over a SECURITY
-- DEFINER function in cma_read (owned by cma_owner, search path pinned, executable by readers only) that
-- reads every tenant the reader sees; ids, codes, flags, amounts and times only
create or replace function cma_read.first_orders_rows()
returns table (tenant_id uuid, connection_id uuid, deal_source_id text, created_at timestamptz, business_date date, market text,
               kind text, level text, attribution text, lead_deal boolean, conversation boolean, email boolean, phone_match boolean,
               attempt boolean, known_contact boolean, phone_hashed boolean, has_order boolean, currency text, amount numeric,
               days_from_first_touch numeric, credited_user_id uuid)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, r.connection_id, r.deal_source_id, r.created_at, r.business_date, r.market, r.kind, r.level, r.attribution, r.lead_deal,
         r.conversation, r.email, r.phone_match, r.attempt, r.known_contact, r.phone_hashed, r.order_id is not null, r.currency, r.amount,
         r.days_from_first_touch, r.credited_user_id
  from cma.tenant t
  cross join lateral cma.first_orders_history_start_of(t.id) h
  cross join lateral cma.first_orders_of(t.id, (h.history_start::timestamp at time zone t.timezone), now()) r
  where cma_read.reader_sees(t.id) and h.history_start is not null
$$;

do $$
begin
  execute 'revoke execute on function cma_read.first_orders_rows() from public';
  execute 'grant execute on function cma_read.first_orders_rows() to cma_readonly';
end
$$;

create or replace view cma_read.first_orders as
  select * from cma_read.first_orders_rows();

-- ---------------------------------------------------------------------------------------------
-- 9. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008u', 'First orders: order pipelines, stage outcomes from the source or a person, a contact''s creation time with slots, the attribution settings, the definition cma.first_orders_of (kind, linked store order, evidence, level, call center or self-service, credited person), the report, amounts per currency, the list, per person, the history start, the reporting views')
on conflict (version) do nothing;

commit;
reset role;
