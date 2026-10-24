-- =============================================================================================
-- 100_definitions_calls.sql: addition 0008zc, step 1 of docs/definitions.md: tag meanings, Connected and Conversation
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 98_funnel.sql
-- (0008zb). Rerunnable, forward-only, in one transaction. Run as your own IAM login: dev first, then
-- 101_verify_definitions_calls.sql (dev), then 63, 95, 41, 75, 83, 85, 91, 93, 99 again (dev; 91 and 99 from the
-- Terminal); then prod together with the web deploy: the calls and attempts reads rename their columns, so the web of
-- main answers an error on Calls, Calls per agent, Attempts per deal and Attempts per agent between this script and
-- the deploy (docs/definitions-2026-10/RUNBOOK.md).
--
-- docs/definitions.md (24 October 2026; Decision log, "Definitions:" rows of 24 October 2026) defines the call terms
-- after Aircall (R2) and from the telephony system only (R1). This addition makes the code follow three of them, and
-- Talk time and Untagged with them because their figures hang on the conversations today:
--   Tag            a meaning per tag of a telephony connection, configuration only: not_reached, call_type,
--                  courtesy_attempt, courtesy_completed_positive, courtesy_completed_neutral or
--                  courtesy_completed_negative, or none. One meaning per tag; ingest never writes it and a catalog
--                  refresh keeps it (as is_counted). Only not_reached is read here; is_counted has no effect on it
--   Connected      Aircall's connected: an outbound call answered by the recipient or their voicemail (answered_at
--                  set), at any talk time, so an answered call still in progress is connected. The setting
--                  telephony.connected_min_seconds stays: above 0 it also needs that much talk time. Its default
--                  becomes 0, and a tenant holding 0008j's 10 seconds moves to 0 (the 10-second rule is retired)
--   Conversation   a connected outbound or an answered inbound call with at least calls.conversation_min_talk_seconds
--                  of talk time (which replaces attempts.reached_min_talk_seconds, each tenant's value copied) that
--                  carries no current tag whose meaning is not_reached; an untagged call is decided by talk time
--                  alone. A CRM call is a conversation only through its linked telephony call (R1): an unlinked CRM
--                  call is never one, and no CRM call outcome decides it. One helper, cma.is_conversation()
--   Talk time      Reports, Calls averages and totals talk time over the answered calls with talk time
--   Untagged       the calls in scope without a current tag, missed inbound calls included; its share is over every
--                  call in scope
--
-- What it adds or changes
--   tags           cma.telephony_tag.meaning (null, or one key of the set above, a check) with
--                  cma.set_telephony_tag_meaning(connection, tag, meaning) (tenant.configure, as cma.set_telephony_tag);
--                  cma.call_not_reached_of(): whether a call carries a current tag meaning not_reached;
--                  cma.connection_catalogs() gives each tag's meaning; cma_read.telephony_tag gains meaning
--   settings       calls.conversation_min_talk_seconds (30, 0 to 600) in place of attempts.reached_min_talk_seconds
--                  (its tenant values copied, then the key retired with its check); telephony.connected_min_seconds
--                  defaults to 0 and a value of 10 (0008j's) moves to 0; cma.check_tenant_setting() as 0008zb with
--                  the new key
--   helpers        cma.is_connected() and cma.is_conversation(): the two definitions written once, as expressions
--                  the planner inlines
--   calls          cma.calls_of: connected and conversation by the helpers; cma.calls_figures_of, calls_overview_of,
--                  calls_overview: connected, connected_rate and untagged (renamed from connected_outbound,
--                  connected_pct and untagged_conversations), talk time over the answered calls, untagged over every
--                  call; cma.calls_tag_use_of and calls_per_person_tags_of: conversations per tag, no untagged row;
--                  cma.calls_per_person_of, calls_per_person: connected and untagged (renamed), untagged over the
--                  person's calls
--   CRM calls      cma.crm_call_connected_of(): whether a CRM call is a conversation, through its linked telephony call
--                  only, at that call's start (Email's not responding); first orders (cma.first_orders_of): a call
--                  is evidence through its linked telephony call, a conversation as the helper says, an attempt when
--                  outbound; the data-quality check telephony_call_unlinked skips an outbound call not connected (no
--                  answer) and untagged by that rule alone
--   attempts       cma.deal_calls_of: connected and conversation from the linked telephony call (the outcome decides
--                  neither, so cma.lead_calls_of's connected is Connected); cma.deal_attempts_of without the reached
--                  threshold, connected and conversation in place of answered and reached, reached_by gone; the row
--                  type cma.attempt_deal with conversation_attempts, first_conversation_attempt and
--                  talk_seconds_conversation (renamed from the reached columns) and the reads over it;
--                  cma.attempts_of_deal: connected and conversation; cma_read.attempts_per_deal with the renamed columns
--
-- The CRM call outcomes' connected flag (cma.connection_call_outcome.is_connected, cma.set_call_outcome) stays as data
-- and is read by nothing here; ingest keeps reading the outcomes until a later step (docs/definitions.md, Gaps).
-- No table besides the column, no index. Everything is SECURITY INVOKER and executable by the application only, as
-- before; the cma_read function of the reader view is SECURITY DEFINER, owned by cma_owner, search path pinned.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zb') then
    raise exception 'addition 0008zb (98_funnel.sql) must run before 0008zc';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Tag meanings
-- ---------------------------------------------------------------------------------------------
-- One meaning per tag of a telephony connection, from a fixed set of keys (docs/definitions.md, Tag), or none.
-- Configuration only: ingest never writes it (the catalog refresh sets name, status and refreshed time; a call's
-- tag is added with nothing else), so a refresh keeps it, as it keeps is_counted. The keys are product vocabulary,
-- the same for every tenant; which tag carries which meaning is the tenant's configuration
alter table cma.telephony_tag add column if not exists meaning text;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'cma.telephony_tag'::regclass and conname = 'telephony_tag_meaning_check') then
    alter table cma.telephony_tag add constraint telephony_tag_meaning_check
      check (meaning in ('not_reached', 'call_type', 'courtesy_attempt', 'courtesy_completed_positive',
                         'courtesy_completed_neutral', 'courtesy_completed_negative'));
  end if;
end
$$;
comment on table cma.telephony_tag is 'Tags of the telephony system per connection; is_counted and meaning (configuration) say which count in reporting and what a tag means; name and status from the source';
comment on column cma.telephony_tag.meaning is 'What the tag means (configuration, 0008zc): not_reached, call_type, courtesy_attempt, courtesy_completed_positive, courtesy_completed_neutral or courtesy_completed_negative; null for none. A current tag meaning not_reached keeps a call from being a conversation';

-- Sets or clears a tag's meaning (tenant.configure), as cma.set_telephony_tag sets is_counted: a tag the catalog does
-- not hold yet is added with its ref as its name. p_meaning null clears it; a key outside the set is CMA04
create or replace function cma.set_telephony_tag_meaning(p_connection_id uuid, p_tag_ref text, p_meaning text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_meaning is not null and p_meaning not in ('not_reached', 'call_type', 'courtesy_attempt', 'courtesy_completed_positive',
                                                 'courtesy_completed_neutral', 'courtesy_completed_negative') then
    raise exception 'a tag''s meaning is not_reached, call_type, courtesy_attempt, courtesy_completed_positive, courtesy_completed_neutral, courtesy_completed_negative or none, not %', p_meaning
      using errcode = 'CMA04';
  end if;
  insert into cma.telephony_tag (tenant_id, connection_id, tag_ref, name, meaning)
  values (cma.current_tenant_id(), p_connection_id, btrim(p_tag_ref), left(btrim(p_tag_ref), 100), p_meaning)
  on conflict (tenant_id, connection_id, tag_ref) do update set meaning = excluded.meaning;
exception when check_violation or not_null_violation then
  raise exception 'invalid tag: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Whether a telephony call carries a current tag (untagged_at empty) whose meaning is not_reached, whatever the tag's
-- is_counted; false for a call without one, or without a call (a null connection). One row, so a read joins it
-- laterally and the planner inlines it
create or replace function cma.call_not_reached_of(p_tenant_id uuid, p_connection_id uuid, p_call_source_id text)
returns table (not_reached boolean)
language sql stable
as $$
  select exists (select 1
                 from cma.telephony_call_tag ct
                 join cma.telephony_tag tg
                   on tg.tenant_id = ct.tenant_id and tg.connection_id = ct.connection_id and tg.tag_ref = ct.tag_ref
                 where ct.tenant_id = p_tenant_id and ct.connection_id = p_connection_id and ct.call_source_id = p_call_source_id
                   and ct.untagged_at is null and tg.meaning = 'not_reached')
$$;

-- As 0008p (74), and each tag with its meaning (null for none)
create or replace function cma.connection_catalogs(p_connection_id uuid)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  return jsonb_build_object(
    'forms', coalesce((select jsonb_agg(jsonb_build_object('formId', f.source_form_id, 'name', f.name, 'isCounted', f.is_counted,
                                                            'leadSource', f.lead_source, 'market', f.market,
                                                            'keptFields', to_jsonb(f.kept_fields), 'status', f.status,
                                                            'isPolled', f.is_polled, 'category', f.category,
                                                            'marketField', f.market_field, 'leadCondition', f.lead_condition,
                                                            'fieldsRefreshedAt', f.fields_refreshed_at,
                                                            'fields', coalesce((select jsonb_agg(jsonb_build_object('name', ff.name, 'kind', ff.kind,
                                                                                                                    'options', to_jsonb(ff.options))
                                                                                                 order by ff.sort_order, ff.name)
                                                                                from cma.connection_form_field ff
                                                                                where ff.tenant_id = f.tenant_id and ff.connection_id = f.connection_id
                                                                                  and ff.source_form_id = f.source_form_id and ff.status = 'active'),
                                                                               '[]'::jsonb))
                                        order by f.name, f.source_form_id)
                       from cma.connection_form f where f.tenant_id = v_tenant and f.connection_id = p_connection_id), '[]'::jsonb),
    'callOutcomes', coalesce((select jsonb_agg(jsonb_build_object('outcomeRef', o.outcome_ref, 'label', o.label,
                                                                   'isConnected', o.is_connected, 'status', o.status)
                                               order by o.label, o.outcome_ref)
                              from cma.connection_call_outcome o where o.tenant_id = v_tenant and o.connection_id = p_connection_id), '[]'::jsonb),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('lineRef', n.number_ref, 'name', n.name, 'digits', n.digits,
                                                            'market', n.market, 'isCounted', n.is_counted, 'status', n.status)
                                        order by n.name, n.number_ref)
                       from cma.telephony_number n where n.tenant_id = v_tenant and n.connection_id = p_connection_id), '[]'::jsonb),
    'tags', coalesce((select jsonb_agg(jsonb_build_object('tagRef', t.tag_ref, 'name', t.name, 'isCounted', t.is_counted,
                                                           'status', t.status, 'meaning', t.meaning)
                                       order by t.name, t.tag_ref)
                      from cma.telephony_tag t where t.tenant_id = v_tenant and t.connection_id = p_connection_id), '[]'::jsonb),
    'sampleIds', coalesce((select jsonb_object_agg(x.record_type, x.source_id)
                           from (select distinct on (r.record_type) r.record_type, r.source_id
                                 from cma.crm_record r
                                 where r.tenant_id = v_tenant and r.connection_id = p_connection_id and r.source_deleted_at is null
                                 order by r.record_type, r.source_created_at desc nulls last, r.source_id) x), '{}'::jsonb));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Settings
-- ---------------------------------------------------------------------------------------------
-- calls.conversation_min_talk_seconds is the Conversation threshold for every call figure; telephony.connected_min_seconds
-- stays, at 0 by default: Connected is answered, at any talk time
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('calls.conversation_min_talk_seconds', 'integer', null, '30',
     'A connected outbound or an answered inbound call is a conversation at this many seconds of talk time or more (0 to 600), unless a current tag means not reached'),
  ('telephony.connected_min_seconds',     'integer', null, '0',
     'An outbound call is connected when it is answered (by the recipient or their voicemail); above 0, it also needs at least this many seconds of talk time (from the answer to the end, no ringing)')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0008zb (98), with calls.conversation_min_talk_seconds (0 to 600) in place of attempts.reached_min_talk_seconds
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
  if new.key in ('leads.age_buckets_business_days', 'attempts.since_last_buckets_business_days', 'attempts.speed_buckets_business_minutes') then
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
  -- the per-person report pages (0008t; attempts since 0008y): from the fixed list email, orders, attempts
  elsif new.key = 'reports.per_person' and not cma.is_per_person_list(new.value) then
    raise exception 'Setting % takes email, orders, attempts and deals, each at most once, lower case, comma-separated without spaces, or nothing', new.key
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
  -- attempts per deal (0008y)
  elsif new.key = 'attempts.max_bucket'
        and (case when length(new.value) > 2 then true else new.value::integer not between 2 and 20 end) then
    raise exception 'Setting % takes a whole number of attempts from 2 to 20', new.key using errcode = 'CMA04';
  elsif new.key = 'attempts.since_last_buckets_business_days' and not cma.is_bucket_list(new.value, 6) then
    raise exception 'Setting % takes one to six increasing whole numbers of business days, comma-separated, such as 1,2,5', new.key using errcode = 'CMA04';
  -- attempts per deal for sales (0008z); attempts.source is held to its two values by the catalog
  elsif new.key = 'attempts.speed_buckets_business_minutes' and not cma.is_bucket_list(new.value, 6) then
    raise exception 'Setting % takes one to six increasing whole numbers of business minutes, comma-separated, such as 5,15,60,240,1440', new.key using errcode = 'CMA04';
  -- Conversation (0008zc): the talk time a connected or answered call needs
  elsif new.key = 'calls.conversation_min_talk_seconds'
        and (case when length(new.value) > 3 then true else new.value::integer not between 0 and 600 end) then
    raise exception 'Setting % takes a whole number of seconds from 0 to 600', new.key using errcode = 'CMA04';
  -- the funnel reports (0008zb): the record kind Reports, Cancellations counts, an active kind of the tenant, or nothing
  elsif new.key = 'reports.cancellation_kind' then
    new.value := btrim(new.value);
    if new.value <> '' and not exists (select 1 from cma.record_kind k
                                       where k.tenant_id = new.tenant_id and k.key = new.value and k.status = 'active') then
      raise exception 'Setting % takes the key of an active record kind, or nothing', new.key using errcode = 'CMA04';
    end if;
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- Each tenant's reached threshold becomes its Conversation threshold (a tenant without one keeps the default, 30, which
-- was reached's default too); then the old key goes, its values first. A rerun finds the old key gone and does nothing
insert into cma.tenant_setting (tenant_id, key, value)
select ts.tenant_id, 'calls.conversation_min_talk_seconds', ts.value
from cma.tenant_setting ts
where ts.key = 'attempts.reached_min_talk_seconds'
on conflict (tenant_id, key) do nothing;
delete from cma.tenant_setting where key = 'attempts.reached_min_talk_seconds';
delete from cma.setting where key = 'attempts.reached_min_talk_seconds';

-- 0008j's connected rule of 10 seconds of talk is retired (Decision log, 24 October 2026, "Definitions: Connected"): a
-- tenant holding it moves to 0, answered at any talk time. Another value is a tenant's own choice and stays
update cma.tenant_setting set value = '0'
where key = 'telephony.connected_min_seconds' and value = '10';

-- ---------------------------------------------------------------------------------------------
-- 3. Connected and Conversation, written once
-- ---------------------------------------------------------------------------------------------
-- Plain expressions (immutable, not strict), so the planner inlines them where a read calls them. The thresholds and
-- the not-reached flag come from the caller, which reads the settings once and cma.call_not_reached_of per call.
-- Connected (Aircall's connected): an outbound call that was answered, by the recipient or their voicemail; with
-- p_connected_min above 0 (telephony.connected_min_seconds), also at least that much talk time. Never null
create or replace function cma.is_connected(p_direction text, p_answered boolean, p_talk_seconds integer, p_connected_min integer)
returns boolean
language sql immutable
as $$
  select coalesce(p_direction = 'outbound', false) and coalesce(p_answered, false)
         and (coalesce(p_connected_min, 0) <= 0 or coalesce(p_talk_seconds >= p_connected_min, false))
$$;

-- Conversation: a connected outbound call or an answered inbound call, with at least p_conversation_min seconds of talk
-- time (calls.conversation_min_talk_seconds; a call not ended has no talk time yet, so it is none until it ends), that
-- carries no current tag meaning not_reached (p_not_reached, cma.call_not_reached_of). Never null
create or replace function cma.is_conversation(p_direction text, p_answered boolean, p_talk_seconds integer, p_connected_min integer,
                                               p_conversation_min integer, p_not_reached boolean)
returns boolean
language sql immutable
as $$
  select (cma.is_connected(p_direction, p_answered, p_talk_seconds, p_connected_min)
          or (coalesce(p_direction = 'inbound', false) and coalesce(p_answered, false)))
         and coalesce(p_talk_seconds >= greatest(0, coalesce(p_conversation_min, 0)), false)
         and not coalesce(p_not_reached, false)
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Reports, Calls and Calls per agent
-- ---------------------------------------------------------------------------------------------
-- As 0008q (76), with Connected and Conversation by the helpers: is_connected_outbound is Connected (answered, at
-- telephony.connected_min_seconds of talk when that is above 0), is_conversation is Conversation (connected or answered
-- inbound, at least calls.conversation_min_talk_seconds of talk, no current tag meaning not_reached). Its columns and
-- everything else stay as they were

create or replace function cma.calls_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz, p_market text, p_line text)
returns table(connection_id uuid, source_system text, direction text, line_key text, line_name text, market text, zone text,
              started_at timestamptz, business_date date, week_start date, local_time time, user_ref text,
              is_answered_inbound boolean, is_connected_outbound boolean, is_conversation boolean, talk_seconds integer,
              tag_refs text[], is_tagged boolean)
language sql stable
as $$
  with s as (
    select t.timezone as tenant_zone,
           greatest(0, cma.setting_of(t.id, 'telephony.connected_min_seconds')::integer) as connected_min,
           greatest(0, cma.setting_of(t.id, 'calls.conversation_min_talk_seconds')::integer) as conversation_min
    from cma.tenant t where t.id = p_tenant_id
  ),
  c as (
    select tc.connection_id, tc.source_system, tc.direction, tc.source_id, tc.started_at, tc.answered_at, tc.talk_seconds,
           tc.user_ref, tc.connection_id::text || ':' || coalesce(tc.number_ref, '') as lk,
           coalesce(n.name, tc.number_ref) as ln, coalesce(m.code, 'unknown') as mk, coalesce(m.time_zone, s.tenant_zone) as z,
           s.connected_min, s.conversation_min
    from cma.telephony_call tc
    cross join s
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = p_tenant_id
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and coalesce(n.is_counted, true)
      and tc.started_at >= coalesce(p_from, '-infinity'::timestamptz)
      and tc.started_at < coalesce(p_to, 'infinity'::timestamptz)
  )
  select c.connection_id, c.source_system, c.direction, c.lk, c.ln, c.mk, c.z, c.started_at,
         (c.started_at at time zone c.z)::date,
         date_trunc('week', (c.started_at at time zone c.z)::date::timestamp)::date,
         (c.started_at at time zone c.z)::time,
         c.user_ref,
         k.answered_in, k.connected_out,
         cma.is_conversation(c.direction, c.answered_at is not null, c.talk_seconds, c.connected_min, c.conversation_min, nr.not_reached),
         c.talk_seconds,
         coalesce(tg.refs, '{}'::text[]), tg.refs is not null
  from c
  cross join lateral (
    select c.direction = 'inbound' and c.answered_at is not null as answered_in,
           cma.is_connected(c.direction, c.answered_at is not null, c.talk_seconds, c.connected_min) as connected_out) k
  cross join lateral cma.call_not_reached_of(p_tenant_id, c.connection_id, c.source_id) nr
  left join lateral (
    select array_agg(ct.tag_ref order by ct.tag_ref) as refs
    from cma.telephony_call_tag ct
    where ct.tenant_id = p_tenant_id and ct.connection_id = c.connection_id and ct.call_source_id = c.source_id
      and ct.untagged_at is null) tg on true
  where (p_market is null or c.mk = p_market)
    and (p_line is null or c.lk = p_line)
$$;

drop function if exists cma.calls_overview(date, date, text, text, text);
drop function if exists cma.calls_overview_of(uuid, date, date, text, text, text, timestamptz);
drop function if exists cma.calls_figures_of(uuid, date, date, text, text, text, timestamptz);


-- As 0008j (62), with the terms of docs/definitions.md: connected and its connected rate (Connected), the
-- conversations (Conversation), talk time in all and on average over the answered calls with talk time (Talk
-- time), and untagged: the calls without a current tag, missed inbound calls included (Untagged).
-- Per group of the business dates [p_from, p_to] (each call's date in its own zone): day (the date),
-- week (the Monday of the ISO week), market (the line's market or 'unknown') or line (connection:line
-- ref, labelled with the line's name); then the total over every call as the last row, with group_key
-- and group_label null (averages and shares do not add up across groups, so the total is computed,
-- not summed; it is there even for a period without calls). With p_until (the previous period of a
-- period that reaches today), the calls of p_to count only up to p_until's time of day in each
-- call's own zone; the other dates count whole. Without it (null, the default) every date counts whole.
create function cma.calls_figures_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_line text, p_group text,
                                                p_until timestamptz default null)
returns table (
  group_key               text,
  group_label             text,
  calls                   integer,
  inbound                 integer,
  outbound                integer,
  answered_inbound        integer,
  connected               integer,
  connected_rate          numeric,
  conversations           integer,
  talk_seconds_total      bigint,
  talk_seconds_avg        numeric,
  outbound_talk_seconds   bigint,
  outbound_talk_avg       numeric,
  untagged                integer
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  c as (
    -- a day on each side, so a line in another zone than the tenant's keeps its whole dates
    select x.* from s
    cross join lateral cma.calls_of(p_tenant_id, (p_from - 1)::timestamp at time zone s.zone,
                                    (p_to + 2)::timestamp at time zone s.zone, p_market, p_line) x
    where x.business_date between p_from and p_to
      and (p_until is null or x.business_date < p_to or x.local_time <= (p_until at time zone x.zone)::time)
  )
  select g.k, g.l,
         count(*)::integer,
         (count(*) filter (where c.direction = 'inbound'))::integer,
         (count(*) filter (where c.direction = 'outbound'))::integer,
         (count(*) filter (where c.is_answered_inbound))::integer,
         (count(*) filter (where c.is_connected_outbound))::integer,
         round(100.0 * count(*) filter (where c.is_connected_outbound) / nullif(count(*) filter (where c.direction = 'outbound'), 0), 1),
         (count(*) filter (where c.is_conversation))::integer,
         coalesce(sum(c.talk_seconds), 0)::bigint,
         round(avg(c.talk_seconds), 1),
         coalesce(sum(c.talk_seconds) filter (where c.is_connected_outbound), 0)::bigint,
         round(avg(c.talk_seconds) filter (where c.is_connected_outbound), 1),
         (count(*) filter (where not c.is_tagged))::integer
  from c
  cross join lateral (
    select case p_group when 'day' then c.business_date::text
                        when 'week' then c.week_start::text
                        when 'market' then c.market
                        else c.line_key end as k,
           case p_group when 'day' then c.business_date::text
                        when 'week' then c.week_start::text
                        when 'market' then c.market
                        else coalesce(c.line_name, 'unknown') end as l) g
  group by grouping sets ((g.k, g.l), ())
  order by grouping(g.k), case when p_group = 'line' then g.l end, g.k
$$;

-- As 0008j (62), with the columns of cma.calls_figures_of. The overview: the groups and the total of the period ('current'), then the total of the previous
-- period ('previous'), for the deltas, like for like as the header says: today is p_now's date in the
-- tenant's zone; a period that reaches it compares with the same elapsed dates, the last of them up to
-- p_now's time of day. p_now is now() for the application; a verifier gives a fixed instant
create function cma.calls_overview_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_line text, p_group text,
                                                 p_now timestamptz default now())
returns table (
  period                  text,
  group_key               text,
  group_label             text,
  calls                   integer,
  inbound                 integer,
  outbound                integer,
  answered_inbound        integer,
  connected               integer,
  connected_rate          numeric,
  conversations           integer,
  talk_seconds_total      bigint,
  talk_seconds_avg        numeric,
  outbound_talk_seconds   bigint,
  outbound_talk_avg       numeric,
  untagged                integer
)
language sql stable
as $$
  with s as (
    select (p_now at time zone t.timezone)::date as today, p_to - p_from + 1 as len
    from cma.tenant t where t.id = p_tenant_id
  ),
  -- the previous span: from as many dates before p_from as the period holds, to as many before the
  -- period's last elapsed date (p_from - 1 for a period that ended); cut at p_now when it reaches today
  v as (
    select p_from - s.len as prev_from, least(p_to, s.today) - s.len as prev_to,
           case when p_to >= s.today then p_now end as until
    from s
  )
  select x.period, x.group_key, x.group_label, x.calls, x.inbound, x.outbound, x.answered_inbound, x.connected,
         x.connected_rate, x.conversations, x.talk_seconds_total, x.talk_seconds_avg, x.outbound_talk_seconds, x.outbound_talk_avg,
         x.untagged
  from (
    select 'current'::text as period, 1 as part, f.*
    from cma.calls_figures_of(p_tenant_id, p_from, p_to, p_market, p_line, p_group) with ordinality f
    union all
    select 'previous', 2, f.*
    from v
    cross join lateral cma.calls_figures_of(p_tenant_id, v.prev_from, v.prev_to, p_market, p_line, p_group, v.until) with ordinality f
    where f.group_key is null
  ) x
  order by x.part, x.ordinality
$$;

-- As 0008j (62), with Conversation as docs/definitions.md defines it, and without the untagged row: Untagged
-- counts calls, not conversations, and is cma.calls_figures_of's per group and in total. Per group and per
-- current tag (any tag, counted or not): the conversations carrying it, tag_key the connection id ':' tag ref,
-- with the catalog's name and is_counted. Then the same over the whole period with group_key null. A
-- conversation with two tags counts under each. Groups as cma.calls_figures_of; within a group the most used
-- tag first.
create or replace function cma.calls_tag_use_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_line text, p_group text)
returns table (
  group_key      text,
  group_label    text,
  tag_key        text,
  tag_name       text,
  is_counted     boolean,
  conversations  integer
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  c as (
    select x.* from s
    cross join lateral cma.calls_of(p_tenant_id, (p_from - 1)::timestamp at time zone s.zone,
                                    (p_to + 2)::timestamp at time zone s.zone, p_market, p_line) x
    where x.business_date between p_from and p_to and x.is_conversation
  ),
  t as (
    select g.k, g.l, c.connection_id::text || ':' || tr.ref as tk, tg.name as tn, tg.is_counted as tc
    from c
    cross join lateral (
      select case p_group when 'day' then c.business_date::text
                          when 'week' then c.week_start::text
                          when 'market' then c.market
                          else c.line_key end as k,
             case p_group when 'day' then c.business_date::text
                          when 'week' then c.week_start::text
                          when 'market' then c.market
                          else coalesce(c.line_name, 'unknown') end as l) g
    cross join lateral unnest(c.tag_refs) as tr(ref)
    left join cma.telephony_tag tg
      on tg.tenant_id = p_tenant_id and tg.connection_id = c.connection_id and tg.tag_ref = tr.ref
  )
  select t.k, t.l, t.tk, t.tn, t.tc, count(*)::integer
  from t
  group by grouping sets ((t.k, t.l, t.tk, t.tn, t.tc), (t.tk, t.tn, t.tc))
  order by grouping(t.k), case when p_group = 'line' then t.l end, t.k, count(*) desc, t.tn, t.tk
$$;

drop function if exists cma.calls_per_person(date, date, text, text);
drop function if exists cma.calls_per_person_of(uuid, date, date, text, text);


-- As 0008j (62), with the terms of docs/definitions.md: connected (Connected), the conversations (Conversation)
-- and untagged, the person's calls without a current tag (Untagged). One row per person with calls in the
-- period ('person', by name), then the calls of telephony users without a person and of calls without a user
-- ('not_linked', with the number of such users, never who they are), then the total over every call
-- ('total'). Talk time totals and averages per direction over the answered inbound and the connected outbound
-- calls with talk time.
create function cma.calls_per_person_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_line text)
returns table (
  row_kind                text,
  user_id                 uuid,
  display_name            text,
  unlinked_users          integer,
  answered_inbound        integer,
  inbound_talk_seconds    bigint,
  inbound_talk_avg        numeric,
  outbound_calls          integer,
  connected               integer,
  outbound_talk_seconds   bigint,
  outbound_talk_avg       numeric,
  conversations           integer,
  untagged                integer,
  first_call_time         time,
  last_call_time          time
)
language sql stable
as $$
  select coalesce(p.row_kind, 'total'), p.user_id, p.display_name,
         case when p.row_kind = 'not_linked' then (count(distinct p.user_ref))::integer end,
         (count(*) filter (where p.is_answered_inbound))::integer,
         coalesce(sum(p.talk_seconds) filter (where p.is_answered_inbound), 0)::bigint,
         round(avg(p.talk_seconds) filter (where p.is_answered_inbound), 1),
         (count(*) filter (where p.direction = 'outbound'))::integer,
         (count(*) filter (where p.is_connected_outbound))::integer,
         coalesce(sum(p.talk_seconds) filter (where p.is_connected_outbound), 0)::bigint,
         round(avg(p.talk_seconds) filter (where p.is_connected_outbound), 1),
         (count(*) filter (where p.is_conversation))::integer,
         (count(*) filter (where not p.is_tagged))::integer,
         min(p.local_time), max(p.local_time)
  from cma.calls_people_of(p_tenant_id, p_from, p_to, p_market, p_line) p
  group by grouping sets ((p.row_kind, p.user_id, p.display_name), ())
  order by grouping(p.row_kind), p.row_kind = 'not_linked', p.display_name, p.user_id
$$;

-- As 0008j (62), with Conversation as docs/definitions.md defines it, and without the untagged row (Untagged
-- counts calls and is cma.calls_per_person_of's). Per person (and the not-linked calls) and per counted tag:
-- the conversations carrying it. Persons by name, not-linked last; within a person the most used tag first.
create or replace function cma.calls_per_person_tags_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_line text)
returns table (
  row_kind       text,
  user_id        uuid,
  tag_key        text,
  tag_name       text,
  conversations  integer
)
language sql stable
as $$
  with p as materialized (
    select * from cma.calls_people_of(p_tenant_id, p_from, p_to, p_market, p_line) where is_conversation
  ),
  r as (
    select p.row_kind, p.user_id, p.display_name, p.connection_id::text || ':' || tg.tag_ref as tk, tg.name as tn, count(*)::integer as n
    from p
    cross join lateral unnest(p.tag_refs) as tr(ref)
    join cma.telephony_tag tg
      on tg.tenant_id = p_tenant_id and tg.connection_id = p.connection_id and tg.tag_ref = tr.ref and tg.is_counted
    group by 1, 2, 3, 4, 5
  )
  select r.row_kind, r.user_id, r.tk, r.tn, r.n
  from r
  order by r.row_kind = 'not_linked', r.display_name, r.user_id, r.n desc, r.tn, r.tk
$$;

-- As 0008j (62), with the columns of cma.calls_figures_of
create function cma.calls_overview(p_from date, p_to date, p_market text, p_line text, p_group text)
returns table (
  period                  text,
  group_key               text,
  group_label             text,
  calls                   integer,
  inbound                 integer,
  outbound                integer,
  answered_inbound        integer,
  connected               integer,
  connected_rate          numeric,
  conversations           integer,
  talk_seconds_total      bigint,
  talk_seconds_avg        numeric,
  outbound_talk_seconds   bigint,
  outbound_talk_avg       numeric,
  untagged                integer
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'week', 'market', 'line') then
    raise exception 'group by day, week, market or line, not %', p_group using errcode = 'CMA04';
  end if;
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.calls_filters_check(p_market, p_line);
  return query select * from cma.calls_overview_of(v_tenant, p_from, p_to, p_market, p_line, p_group);
end
$$;

-- As 0008j (62), with the columns of cma.calls_per_person_of
create function cma.calls_per_person(p_from date, p_to date, p_market text, p_line text)
returns table (
  row_kind                text,
  user_id                 uuid,
  display_name            text,
  unlinked_users          integer,
  answered_inbound        integer,
  inbound_talk_seconds    bigint,
  inbound_talk_avg        numeric,
  outbound_calls          integer,
  connected               integer,
  outbound_talk_seconds   bigint,
  outbound_talk_avg       numeric,
  conversations           integer,
  untagged                integer,
  first_call_time         time,
  last_call_time          time
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('performance.team');
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.calls_filters_check(p_market, p_line);
  return query select * from cma.calls_per_person_of(v_tenant, p_from, p_to, p_market, p_line);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. A CRM call's conversation, first orders and the data-quality skip
-- ---------------------------------------------------------------------------------------------
-- As 0008t (82), from the telephony system only (R1): a CRM call is a conversation when its linked telephony call
-- (while the link is current and the call not deleted) is a Conversation (cma.is_conversation); a CRM call without one
-- is never one, whatever its outcome. effective_at is that telephony call's start, null without one. Its name and
-- columns stay, so Email's not-responding read (cma.email_not_responding_of) keeps its text and reads the new rule
create or replace function cma.crm_call_connected_of(p_tenant_id uuid, p_crm_call_id uuid,
                                                     out effective_at timestamptz, out is_connected boolean)
language sql stable
as $$
  select tc.started_at,
         tc.id is not null
         and cma.is_conversation(tc.direction, tc.answered_at is not null, tc.talk_seconds,
                                 greatest(0, cma.setting_of(p_tenant_id, 'telephony.connected_min_seconds')::integer),
                                 greatest(0, cma.setting_of(p_tenant_id, 'calls.conversation_min_talk_seconds')::integer),
                                 nr.not_reached)
  from cma.crm_call cc
  left join cma.call_link l on l.tenant_id = cc.tenant_id and l.crm_call_id = cc.id and l.unlinked_at is null
  left join cma.telephony_call tc on tc.tenant_id = l.tenant_id and tc.id = l.telephony_call_id and tc.source_deleted_at is null
  cross join lateral cma.call_not_reached_of(p_tenant_id, tc.connection_id, tc.source_id) nr
  where cc.tenant_id = p_tenant_id and cc.id = p_crm_call_id
$$;

-- As 0008x (90), with the calls of docs/definitions.md: a call with the contact is evidence through its linked
-- telephony call only (R1), at that call's start: a conversation when the call is a Conversation (cma.is_conversation),
-- an attempt when it is an outbound call (Attempt: every outbound call, a conversation included). A CRM call without a
-- current link, an inbound call that is no conversation and a CRM call's outcome are no evidence. Everything else as
-- 0008x: the phone match keeps its CRM call's time when the call has no link
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
           make_interval(mins => cma.setting_of(t.id, 'attribution.order_match_minutes')::integer) as match,
           greatest(0, cma.setting_of(t.id, 'telephony.connected_min_seconds')::integer) as connected_min,
           greatest(0, cma.setting_of(t.id, 'calls.conversation_min_talk_seconds')::integer) as conversation_min
    from cma.tenant t where t.id = p_tenant_id
  ),
  -- the won deals of the order pipelines created in the period, with their contact and its country
  d0 as materialized (
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
  d as materialized (
    select d0.*, cc.country
    from d0
    left join cma.crm_contact cc on cc.tenant_id = p_tenant_id and cc.connection_id = d0.connection_id and cc.source_id = d0.contact
  ),
  -- the catalog market of every value a deal's market reads (its own, its contact's country), once per value,
  -- as one map
  mv as materialized (
    select coalesce(jsonb_object_agg(v.value, cma.market_code_of(p_tenant_id, v.value)), '{}'::jsonb) as code_of
    from (select d.own_market as value from d union select d.country from d) v
    where v.value is not null
  ),
  -- the market, the linked order and the kind
  k as materialized (
    select d.*, coalesce(mv.code_of ->> d.own_market, mv.code_of ->> d.country, 'unknown') as market, coalesce(mk.time_zone, s.tenant_zone) as zone,
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
    cross join mv
    left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = coalesce(mv.code_of ->> d.own_market, mv.code_of ->> d.country, 'unknown')
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
  -- the first orders: only they are attributed
  fo as materialized (
    select k.*, array(select distinct h from unnest(k.hashes) h) as phones
    from k
    where k.kind = 'first'
  ),
  -- the CRM calls a first order can count, once each: those associated with its contact and those from its
  -- order's phone number (any contact); with the effective time (the linked telephony call's start while the
  -- link is current, else the CRM call's time: the phone match's), the linked telephony call's start, and
  -- whether that telephony call is a conversation and whether it is an attempt (none without a link, R1)
  cl as materialized (
    select c.id, c.connection_id, c.source_id, c.source_system, c.owner_ref, c.counterpart_hash,
           coalesce(tc.started_at, c.occurred_at) as effective_at,
           tc.started_at as call_started_at,
           tc.id is not null and cma.is_conversation(tc.direction, tc.answered_at is not null, tc.talk_seconds, s.connected_min,
                                                     s.conversation_min, nr.not_reached) as is_conversation,
           coalesce(tc.direction = 'outbound', false) as is_attempt
    from (select a.connection_id, a.from_id as source_id
          from fo
          join cma.crm_association a
            on a.tenant_id = p_tenant_id and a.connection_id = fo.connection_id and a.from_type = 'crm_call' and a.to_type = 'contact'
           and a.to_id = fo.contact and a.removed_at is null
          union
          select c2.connection_id, c2.source_id
          from (select distinct h from fo cross join unnest(fo.phones) h) ph
          join cma.crm_call c2 on c2.tenant_id = p_tenant_id and c2.counterpart_hash = ph.h) ids
    join cma.crm_call c
      on c.tenant_id = p_tenant_id and c.connection_id = ids.connection_id and c.source_id = ids.source_id and c.source_deleted_at is null
    cross join s
    left join cma.call_link l on l.tenant_id = c.tenant_id and l.crm_call_id = c.id and l.unlinked_at is null
    left join cma.telephony_call tc on tc.tenant_id = l.tenant_id and tc.id = l.telephony_call_id and tc.source_deleted_at is null
    cross join lateral cma.call_not_reached_of(p_tenant_id, tc.connection_id, tc.source_id) nr
  ),
  -- the touches of each first order in its window, once per first order
  x as materialized (
    -- lead deals of the contact: primary contact
    select fo.id, 'lead_deal'::text as touch, r3.source_created_at as at, r3.source_system || '_owner' as sys, r3.owner_ref
    from fo
    cross join s
    join cma.crm_record r3
      on r3.tenant_id = p_tenant_id and r3.connection_id = fo.connection_id and r3.record_type = 'deal' and r3.contact_source_id = fo.contact
    left join cma.connection_pipeline p3
      on p3.tenant_id = r3.tenant_id and p3.connection_id = r3.connection_id and p3.record_type = r3.record_type
     and p3.source_pipeline_id = r3.pipeline_id
    where r3.source_deleted_at is null and r3.id <> fo.id
      and coalesce(p3.is_counted, true) and coalesce(p3.is_lead, true) and not coalesce(p3.is_order, false)
      and r3.source_created_at >= fo.t - s.win and r3.source_created_at < fo.t
    union all
    -- lead deals of the contact: a current association
    select fo.id, 'lead_deal', r3.source_created_at, r3.source_system || '_owner', r3.owner_ref
    from fo
    cross join s
    join cma.crm_association a3
      on a3.tenant_id = p_tenant_id and a3.connection_id = fo.connection_id and a3.from_type = 'deal' and a3.to_type = 'contact'
     and a3.to_id = fo.contact and a3.removed_at is null
    join cma.crm_record r3
      on r3.tenant_id = a3.tenant_id and r3.connection_id = a3.connection_id and r3.record_type = 'deal' and r3.source_id = a3.from_id
    left join cma.connection_pipeline p3
      on p3.tenant_id = r3.tenant_id and p3.connection_id = r3.connection_id and p3.record_type = r3.record_type
     and p3.source_pipeline_id = r3.pipeline_id
    where r3.contact_source_id is distinct from fo.contact and r3.source_deleted_at is null and r3.id <> fo.id
      and coalesce(p3.is_counted, true) and coalesce(p3.is_lead, true) and not coalesce(p3.is_order, false)
      and r3.source_created_at >= fo.t - s.win and r3.source_created_at < fo.t
    union all
    -- calls with the contact, through their linked telephony call: a conversation, and an attempt (an outbound call)
    select fo.id, e.touch, c.call_started_at, c.source_system || '_owner', c.owner_ref
    from fo
    cross join s
    join cma.crm_association a4
      on a4.tenant_id = p_tenant_id and a4.connection_id = fo.connection_id and a4.from_type = 'crm_call' and a4.to_type = 'contact'
     and a4.to_id = fo.contact and a4.removed_at is null
    join cl c on c.connection_id = a4.connection_id and c.source_id = a4.from_id
    cross join lateral (values ('conversation'::text, c.is_conversation), ('attempt', c.is_attempt)) e(touch, holds)
    where e.holds and c.call_started_at >= fo.t - s.win and c.call_started_at < fo.t
    union all
    -- agent emails to the contact: the message's own contact, its conversation's, or an engagement's association
    select fo.id, 'email', em.occurred_at, em.source_system || '_owner', em.owner_ref
    from fo
    cross join s
    cross join lateral (
      select em1.id from cma.email_message em1
      where em1.tenant_id = p_tenant_id and em1.connection_id = fo.connection_id and em1.contact_source_id = fo.contact
      union
      select em2.id from cma.email_thread th2
      join cma.email_message em2
        on em2.tenant_id = th2.tenant_id and em2.connection_id = th2.connection_id and em2.thread_source_id = th2.source_id
      where th2.tenant_id = p_tenant_id and th2.connection_id = fo.connection_id and th2.contact_source_id = fo.contact
      union
      select em3.id from cma.crm_association a5
      join cma.email_message em3
        on em3.tenant_id = a5.tenant_id and em3.connection_id = a5.connection_id and em3.source_kind = 'crm_email'
       and em3.source_id = a5.from_id
      where a5.tenant_id = p_tenant_id and a5.connection_id = fo.connection_id and a5.from_type = 'crm_email'
        and a5.to_type = 'contact' and a5.to_id = fo.contact and a5.removed_at is null) ids
    join cma.email_message em on em.tenant_id = p_tenant_id and em.id = ids.id
    join cma.integration_connection ic on ic.tenant_id = em.tenant_id and ic.id = em.connection_id
    left join cma.email_thread th
      on th.tenant_id = em.tenant_id and th.connection_id = em.connection_id and th.source_id = em.thread_source_id
    where em.direction = 'out' and em.status = 'sent' and em.source_deleted_at is null
      and em.occurred_at >= fo.t - s.win and em.occurred_at < fo.t
      and case when em.source_kind = 'inbox_message'
               then em.actor_kind not in ('bot', 'ai', 'system', 'integration') and not coalesce(th.is_spam, false)
               else not (lower(coalesce(em.origin, '')) = any (cma.setting_codes(ic.settings, 'email_inbox_copy_origins')))
                    and not (lower(coalesce(em.origin, '')) = any (cma.setting_codes(ic.settings, 'email_automated_origins'))) end
    union all
    -- a CRM call from the order's phone number, any contact
    select fo.id, 'phone_match', c.effective_at, c.source_system || '_owner', c.owner_ref
    from fo
    cross join s
    cross join unnest(fo.phones) ph(h)
    join cl c on c.counterpart_hash = ph.h
    where c.effective_at >= fo.t - s.win and c.effective_at < fo.t
    union all
    -- a telephony call from the order's phone number, any contact
    select fo.id, 'phone_match', tc.started_at, tc.source_system || '_user', tc.user_ref
    from fo
    cross join s
    cross join unnest(fo.phones) ph(h)
    join cma.telephony_call tc on tc.tenant_id = p_tenant_id and tc.counterpart_hash = ph.h
    where tc.source_deleted_at is null and tc.started_at >= fo.t - s.win and tc.started_at < fo.t
  ),
  f as materialized (
    select fo.id,
           coalesce(bool_or(x.touch = 'lead_deal'), false) as f_lead,
           coalesce(bool_or(x.touch = 'conversation'), false) as f_conv,
           coalesce(bool_or(x.touch = 'email'), false) as f_email,
           coalesce(bool_or(x.touch = 'phone_match'), false) as f_phone,
           coalesce(bool_or(x.touch = 'attempt'), false) as f_attempt,
           coalesce((select kc.source_created_at <= fo.t - s.known
                     from cma.crm_contact kc
                     where kc.tenant_id = p_tenant_id and kc.connection_id = fo.connection_id and kc.source_id = fo.contact), false) as f_known,
           min(x.at) as first_at,
           (array_agg(x.sys order by x.at desc, x.touch, x.owner_ref) filter (where x.touch = any (s.assisted)))[1] as c_sys,
           (array_agg(x.owner_ref order by x.at desc, x.touch, x.owner_ref) filter (where x.touch = any (s.assisted)))[1] as c_owner
    from fo
    cross join s
    left join x on x.id = fo.id
    group by fo.id, fo.t, fo.connection_id, fo.contact, s.known
  ),
  l as materialized (
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
  -- the order deals that are no first order carry their kind and order, nothing else; each first order its
  -- own evidence, level, attribution and credited person (a join of the first orders only, by id)
  select k.id, k.connection_id, k.source_system, k.source_id, k.pipeline_id, k.pipeline_label, k.contact, k.t, k.market, k.zone,
         (k.t at time zone k.zone)::date,
         date_trunc('week', (k.t at time zone k.zone)::date::timestamp)::date,
         (k.t at time zone k.zone)::time,
         k.kind, k.order_id, k.order_source_id, k.store_order_kind,
         case when k.order_id is not null then k.order_currency else k.deal_currency end,
         case when k.order_id is not null then k.order_amount else k.deal_amount end,
         cardinality(k.hashes) > 0,
         null::boolean, null::boolean, null::boolean, null::boolean, null::boolean, null::boolean, null::text, null::text,
         null::timestamptz, null::numeric, null::text, null::text, null::uuid
  from k
  where k.kind <> 'first'
  union all
  select fo.id, fo.connection_id, fo.source_system, fo.source_id, fo.pipeline_id, fo.pipeline_label, fo.contact, fo.t, fo.market, fo.zone,
         (fo.t at time zone fo.zone)::date,
         date_trunc('week', (fo.t at time zone fo.zone)::date::timestamp)::date,
         (fo.t at time zone fo.zone)::time,
         fo.kind, fo.order_id, fo.order_source_id, fo.store_order_kind,
         case when fo.order_id is not null then fo.order_currency else fo.deal_currency end,
         case when fo.order_id is not null then fo.order_amount else fo.deal_amount end,
         cardinality(fo.hashes) > 0,
         l.f_lead, l.f_conv, l.f_email, l.f_phone, l.f_attempt, l.f_known,
         l.lv,
         case when l.lv = any (l.assisted) then 'call_center' else 'self_service' end,
         l.first_at,
         case when l.first_at is not null then round((extract(epoch from fo.t - l.first_at) / 86400)::numeric, 2) end,
         l.c_sys, l.c_owner,
         (select xi.user_id from cma.app_user_external_id xi
          where xi.tenant_id = p_tenant_id and xi.system = l.c_sys and xi.external_id = l.c_owner)
  from fo
  join l on l.id = fo.id
$$;

-- As 0008p (74), with the skip of telephony_call_unlinked by its own rule (Not connected): an outbound call
-- without an answer (answered_at empty) and without a current tag, whatever telephony.connected_min_seconds says.
-- 0008p's findings: 0008o's, plus form_answer_not_in_options: per submission and field of a described form, an
-- answer whose field is no choice field of the form or whose value is no option of it, current or
-- retired. 0008p's write keeps no such answer, so it finds only values kept under 0007's rule before
-- the source described the form
create or replace function cma.data_quality_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_start timestamptz;
begin
  select cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone into v_start
  from cma.tenant t where t.id = p_tenant_id;

  return query
  -- lead deals without any contact
  select 'deal_without_contact'::text, d.connection_id, d.record_type, d.source_id, null::text
  from cma.lead_deals_of(p_tenant_id, null, null) d
  where cardinality(d.contacts) = 0
  union all
  -- primary contacts of lead deals without country or language
  select 'deal_contact_incomplete', k.connection_id, 'contact', k.source_id, null
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and (k.country is null or k.language is null)
    and exists (select 1 from cma.lead_deals_of(p_tenant_id, null, null) d
                where d.connection_id = k.connection_id and d.contact_source_id = k.source_id)
  union all
  -- markets and countries written by a source that are no catalog market
  select 'market_not_in_catalog', cr.connection_id, cr.record_type, cr.source_id, cr.market
  from cma.crm_record cr
  where cr.tenant_id = p_tenant_id and cr.source_deleted_at is null and cr.source_created_at >= v_start
    and nullif(btrim(cr.market), '') is not null and cma.market_code_of(p_tenant_id, cr.market) is null
  union all
  select 'market_not_in_catalog', k.connection_id, 'contact', k.source_id, k.country
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and nullif(btrim(k.country), '') is not null and cma.market_code_of(p_tenant_id, k.country) is null
  union all
  -- CRM owners (of records since the start and of calls since the start) without a person
  select 'owner_without_person', o.connection_id, 'owner', o.owner_ref, null
  from (select cr.connection_id, cr.source_system, cr.owner_ref
        from cma.crm_record cr
        where cr.tenant_id = p_tenant_id and cr.source_deleted_at is null and cr.source_created_at >= v_start
          and cr.owner_ref is not null
        union
        select c.connection_id, c.source_system, c.owner_ref
        from cma.crm_call c
        where c.tenant_id = p_tenant_id and c.source_deleted_at is null and c.occurred_at >= v_start
          and c.owner_ref is not null) o
  where not exists (select 1 from cma.app_user_external_id x
                    where x.tenant_id = p_tenant_id and x.system = o.source_system || '_owner' and x.external_id = o.owner_ref)
  union all
  -- telephony users without a person
  select 'telephony_user_without_person', u.connection_id, 'telephony_user', u.user_ref, null
  from (select distinct tc.connection_id, tc.source_system, tc.user_ref
        from cma.telephony_call tc
        where tc.tenant_id = p_tenant_id and tc.source_deleted_at is null and tc.started_at >= v_start
          and tc.user_ref is not null) u
  where not exists (select 1 from cma.app_user_external_id x
                    where x.tenant_id = p_tenant_id and x.system = u.source_system || '_user' and x.external_id = u.user_ref)
  union all
  -- CRM calls without a current contact association
  select 'crm_call_without_contact', c.connection_id, 'crm_call', c.source_id, null
  from cma.crm_call c
  where c.tenant_id = p_tenant_id and c.source_deleted_at is null and c.occurred_at >= v_start
    and not exists (select 1 from cma.crm_association a
                    where a.tenant_id = c.tenant_id and a.connection_id = c.connection_id and a.from_type = 'crm_call'
                      and a.from_id = c.source_id and a.to_type = 'contact' and a.removed_at is null)
  union all
  -- telephony calls older than 24 hours without a current link, once the tenant has CRM calls; an
  -- outbound call not connected (no answer) and without a current tag is skipped when the connection says so
  -- (dq_unlinked_skip = outbound_unanswered_untagged, the default for a telephony connection; 0008o; 0008zc)
  select 'telephony_call_unlinked', tc.connection_id, 'telephony_call', tc.source_id, null
  from cma.telephony_call tc
  join cma.integration_connection ic on ic.tenant_id = tc.tenant_id and ic.id = tc.connection_id
  where tc.tenant_id = p_tenant_id and tc.source_deleted_at is null
    and tc.started_at >= v_start and tc.started_at < now() - interval '24 hours'
    and exists (select 1 from cma.crm_call c where c.tenant_id = p_tenant_id and c.source_deleted_at is null)
    and not exists (select 1 from cma.call_link l
                    where l.tenant_id = tc.tenant_id and l.telephony_call_id = tc.id and l.unlinked_at is null)
    and not (coalesce(ic.settings ->> 'dq_unlinked_skip', case when ic.kind = 'telephony' then 'outbound_unanswered_untagged' end) = 'outbound_unanswered_untagged'
             and tc.direction = 'outbound'
             and tc.answered_at is null
             and not exists (select 1 from cma.telephony_call_tag g
                             where g.tenant_id = tc.tenant_id and g.connection_id = tc.connection_id
                               and g.call_source_id = tc.source_id and g.untagged_at is null))
  union all
  -- commerce customers whose id no contact holds, or several contacts hold
  select case when h.contacts = 0 then 'commerce_unmatched' else 'commerce_ambiguous' end,
         cu.connection_id, 'commerce_customer', cu.source_id, null
  from cma.commerce_customer cu
  cross join lateral (select count(distinct r.contact_id) as contacts
                      from cma.crm_contact_ref r
                      where r.tenant_id = cu.tenant_id and r.system = cu.source_system and r.external_id = cu.source_id) h
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null and h.contacts <> 1
  union all
  -- contacts with both first slots of a ref system taken
  select 'contact_slots_full', k.connection_id, 'contact', k.source_id, r.system
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id and r.slot in (1, 2)
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
  group by k.connection_id, k.source_id, r.system
  having count(distinct r.slot) = 2
  union all
  -- contacts whose country differs from the market of a store their commerce id belongs to
  select distinct 'contact_country_differs', k.connection_id, 'contact', k.source_id,
         cma.market_code_of(p_tenant_id, k.country) || '/' || st.market
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id
  join cma.commerce_customer cu
    on cu.tenant_id = r.tenant_id and cu.source_system = r.system and cu.source_id = r.external_id and cu.source_deleted_at is null
  join cma.commerce_store st on st.tenant_id = cu.tenant_id and st.connection_id = cu.connection_id
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and cma.market_code_of(p_tenant_id, k.country) is distinct from st.market
    and nullif(btrim(k.country), '') is not null
  union all
  -- one commerce customer id in two or more stores
  select 'customer_in_two_stores', null::uuid, 'commerce_customer', cu.source_id, cu.source_system
  from cma.commerce_customer cu
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null
  group by cu.source_system, cu.source_id
  having count(distinct cu.connection_id) > 1
  union all
  -- active pipelines no person has ever written (only the source's refresh)
  select 'pipeline_unreviewed', p.connection_id, 'pipeline', p.source_pipeline_id, p.record_type
  from cma.connection_pipeline p
  where p.tenant_id = p_tenant_id and p.status = 'active'
    and not exists (select 1 from cma.audit_log al
                    join cma.app_user u on u.tenant_id = al.tenant_id and u.id = al.actor_user_id and u.kind = 'person'
                    where al.tenant_id = p.tenant_id and al.table_name = 'connection_pipeline' and al.row_id = p.id::text)
  union all
  -- counted active forms without a market
  select 'form_without_market', f.connection_id, 'form', f.source_form_id, null
  from cma.connection_form f
  where f.tenant_id = p_tenant_id and f.status = 'active' and f.is_counted and f.market is null
  union all
  -- held contacts whose country came from a fallback slot (0008m)
  select 'contact_country_fallback', k.connection_id, 'contact', k.source_id, k.country_source::text
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null and k.country_source > 1
  union all
  -- open tickets without an owner, and without a market, per pipeline, once ticket SLAs are configured (0008o)
  select 'ticket_no_owner', t.connection_id, 'ticket', t.ticket_source_id, t.pipeline_id
  from cma.open_tickets_of(p_tenant_id) t
  where t.owner_ref is null and cma.follow_up_configured_of(p_tenant_id)
  union all
  select 'ticket_no_market', t.connection_id, 'ticket', t.ticket_source_id, t.pipeline_id
  from cma.open_tickets_of(p_tenant_id) t
  where t.market = 'unknown' and cma.follow_up_configured_of(p_tenant_id)
  union all
  -- open tasks whose owner is not linked to a person (0008o)
  select 'crm_task_owner_unlinked', k.connection_id, 'task', k.task_source_id, k.owner_ref
  from cma.open_tasks_of(p_tenant_id) k
  where k.owner_ref is not null and k.owner_user_id is null
  union all
  -- kept form answers no option of their field accounts for, current or retired (0008p): one row per
  -- submission and field of a form the source has described, the field's name as the code
  select 'form_answer_not_in_options', fs.connection_id, 'form_submission', fs.source_id, e.key
  from cma.form_submission fs
  join cma.connection_form f
    on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
   and f.fields_refreshed_at is not null
  cross join lateral jsonb_each(fs.kept_values) e
  left join cma.connection_form_field ff
    on ff.tenant_id = fs.tenant_id and ff.connection_id = fs.connection_id and ff.source_form_id = fs.source_form_id
   and ff.name = e.key
  where fs.tenant_id = p_tenant_id and fs.kept_values <> '{}'::jsonb
    and (ff.name is null or not cma.form_choice_kind(ff.kind)
         or exists (select 1
                    from (select e.value #>> '{}' as v where jsonb_typeof(e.value) = 'string'
                          union all
                          select x from jsonb_array_elements_text(case when jsonb_typeof(e.value) = 'array' then e.value
                                                                       else '[]'::jsonb end) x) a
                    where not (a.v = any (ff.options || ff.retired_options))));

  -- parked write-backs: the outbox arrives with migration 0007c (DESIGN §4.3a); until then the check
  -- finds nothing. Only the columns every outbox row has by design are read: id, connection, status
  if to_regclass('cma.outbox_action') is not null then
    return query execute
      'select ''writeback_parked''::text, o.connection_id, ''outbox_action''::text, o.id::text, null::text
       from cma.outbox_action o
       where o.tenant_id = $1 and o.status = ''needs_review'''
      using p_tenant_id;
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Attempts per deal and Attempts per agent
-- ---------------------------------------------------------------------------------------------
-- A deal's calls carry Connected and Conversation from their linked telephony call; its attempts carry them in place of
-- answered and reached. The return types change, so the functions go first (each named) and are made again

drop function if exists cma.deal_calls_of(uuid, uuid, text, text, text[], timestamptz);


-- As 0008z (94), with Connected and Conversation from the linked telephony call (docs/definitions.md, R1). 0007d's
-- calls of a deal (cma.lead_calls_of's rule: CRM calls of the deal's connection, not deleted, currently associated
-- with the deal or one of its contacts, whose effective start, the linked telephony call's start while the link is
-- current and the telephony call not deleted, else the CRM call's time, is at or after p_not_before); connected
-- when the linked telephony call is Connected (cma.is_connected: outbound and answered, at telephony.connected_min_seconds
-- of talk when that is above 0), a conversation when it is a Conversation (cma.is_conversation); the CRM call's outcome
-- decides neither. With what the attempts read besides: the outcome's catalog label, and the linked telephony call's
-- id, direction, talk time (ended - answered, as cma.calls_of reads it), user and whether its line counts (a line not
-- yet in the catalog counts, as cma.calls_of). The two settings are read once per call of this function
create function cma.deal_calls_of(p_tenant_id uuid, p_connection_id uuid, p_record_type text,
                                             p_source_id text, p_contacts text[], p_not_before timestamptz)
returns table (
  call_id                  uuid,
  call_source_id           text,
  source_system            text,
  direction                text,
  owner_ref                text,
  effective_at             timestamptz,
  is_linked                boolean,
  is_connected             boolean,
  is_conversation          boolean,
  outcome_ref              text,
  outcome_label            text,
  telephony_call_id        uuid,
  telephony_source_system  text,
  telephony_direction      text,
  talk_seconds             integer,
  telephony_user_ref       text,
  line_counted             boolean
)
language sql stable
as $$
  select c.id, c.source_id, c.source_system, c.direction, c.owner_ref,
         coalesce(tc.started_at, c.occurred_at), tc.started_at is not null,
         tc.id is not null and cma.is_connected(tc.direction, tc.answered_at is not null, tc.talk_seconds, s.connected_min),
         tc.id is not null and cma.is_conversation(tc.direction, tc.answered_at is not null, tc.talk_seconds, s.connected_min,
                                                   s.conversation_min, nr.not_reached),
         c.outcome_ref, o.label,
         tc.id, tc.source_system, tc.direction, tc.talk_seconds, tc.user_ref,
         coalesce(n.is_counted, true)
  from cma.crm_call c
  -- the settings once per call of this function (offset 0 keeps the planner from evaluating them per row)
  cross join (select greatest(0, cma.setting_of(p_tenant_id, 'telephony.connected_min_seconds')::integer) as connected_min,
                     greatest(0, cma.setting_of(p_tenant_id, 'calls.conversation_min_talk_seconds')::integer) as conversation_min
              offset 0) s
  left join cma.call_link l
    on l.tenant_id = c.tenant_id and l.crm_call_id = c.id and l.unlinked_at is null
  left join cma.telephony_call tc
    on tc.tenant_id = l.tenant_id and tc.id = l.telephony_call_id and tc.source_deleted_at is null
  left join cma.connection_call_outcome o
    on o.tenant_id = c.tenant_id and o.connection_id = c.connection_id and o.outcome_ref = c.outcome_ref
  left join cma.telephony_number n
    on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
  cross join lateral cma.call_not_reached_of(p_tenant_id, tc.connection_id, tc.source_id) nr
  where c.tenant_id = p_tenant_id
    and c.connection_id = p_connection_id
    and c.source_deleted_at is null
    and coalesce(tc.started_at, c.occurred_at) >= p_not_before
    and exists (select 1 from cma.crm_association a
                where a.tenant_id = c.tenant_id and a.connection_id = c.connection_id
                  and a.from_type = 'crm_call' and a.from_id = c.source_id and a.removed_at is null
                  and ((a.to_type = p_record_type and a.to_id = p_source_id)
                       or (a.to_type = 'contact' and a.to_id = any (p_contacts))))
$$;

-- As 0008z (94): 0007d's signature, read from cma.deal_calls_of, so its connected is Connected (the first connected
-- call of Speed to lead's rows). The planner inlines both, and leaves the line out (no column of it is read here)
create or replace function cma.lead_calls_of(p_tenant_id uuid, p_connection_id uuid, p_record_type text,
                                             p_source_id text, p_contacts text[], p_not_before timestamptz)
returns table (
  call_id         uuid,
  call_source_id  text,
  source_system   text,
  direction       text,
  owner_ref       text,
  effective_at    timestamptz,
  is_linked       boolean,
  is_connected    boolean
)
language sql stable
as $$
  select c.call_id, c.call_source_id, c.source_system, c.direction, c.owner_ref, c.effective_at, c.is_linked, c.is_connected
  from cma.deal_calls_of(p_tenant_id, p_connection_id, p_record_type, p_source_id, p_contacts, p_not_before) c
$$;


drop function if exists cma.deal_attempts_of(uuid, uuid, text, text, text[], timestamptz, timestamptz, text, integer);


-- As 0008z (94), with Connected and Conversation in place of answered and reached (docs/definitions.md). A deal's
-- calls from p_not_before to p_until (cma.deal_calls_of) that are attempts under p_source, numbered in the order of
-- their start (then the CRM call's id), each connected or not and a conversation or not, from the linked telephony
-- call only (R1: a CRM call without one is neither, under either source); and the outbound CRM calls without a
-- linked telephony call (without_aircall: never an attempt under telephony, every one an attempt under crm)
create or replace function cma.deal_attempts_of(p_tenant_id uuid, p_connection_id uuid, p_record_type text, p_source_id text,
                                                p_contacts text[], p_not_before timestamptz, p_until timestamptz, p_source text)
returns table (
  n                        integer,
  call_id                  uuid,
  effective_at             timestamptz,
  connected                boolean,
  talk_seconds             integer,
  has_outcome              boolean,
  outcome_label            text,
  conversation             boolean,
  owner_system             text,
  owner_ref                text,
  telephony_source_system  text,
  telephony_user_ref       text,
  is_attempt               boolean,
  without_aircall          boolean
)
language sql stable
as $$
  select case when y.is_attempt then (row_number() over (partition by y.is_attempt order by y.effective_at, y.call_id))::integer end,
         y.call_id, y.effective_at, y.is_connected, y.talk_seconds, y.outcome_ref is not null, y.outcome_label, y.is_conversation,
         y.source_system, y.owner_ref, y.telephony_source_system, y.telephony_user_ref, y.is_attempt, y.without_aircall
  from (
    select c.*,
           case when p_source = 'crm' then c.direction = 'outbound'
                else c.is_linked and c.telephony_direction = 'outbound' and c.line_counted end as is_attempt,
           c.direction = 'outbound' and not c.is_linked as without_aircall
    from cma.deal_calls_of(p_tenant_id, p_connection_id, p_record_type, p_source_id, p_contacts, p_not_before) c
    where c.effective_at <= p_until
  ) y
  where y.is_attempt or y.without_aircall
$$;

-- 0008z's row type with the conversation columns in place of the reached ones: the old shape and the functions over it
-- go first (each named), so nothing else is dropped; a rerun finds the new shape and drops nothing. The reads that only
-- hold the type in a variable (cma.attempts_per_deal_page_of, cma.attempts_per_person_of) keep their text and find the
-- new type by its name
do $$
begin
  if to_regtype('cma.attempt_deal') is not null
     and not exists (select 1 from pg_attribute a
                     where a.attrelid = (select t.typrelid from pg_type t where t.oid = to_regtype('cma.attempt_deal'))
                       and a.attname = 'conversation_attempts' and not a.attisdropped) then
    drop function if exists cma.attempts_per_deal_of(uuid, timestamptz, timestamptz, timestamptz);
    drop function if exists cma.attempts_rows_of(uuid, date, date, timestamptz);
    drop function if exists cma.attempts_in_period(cma.attempt_deal[], date, date, text, text, text, text, timestamptz, text);
    drop function if exists cma.attempts_figures_from(cma.attempt_deal[]);
    drop function if exists cma.attempts_buckets_from(cma.attempt_deal[], integer);
    drop function if exists cma.attempts_outcomes_from(cma.attempt_deal[]);
    drop function if exists cma.attempts_speed_buckets_from(cma.attempt_deal[], text);
    drop function if exists cma.attempts_since_last_from(cma.attempt_deal[], text);
    drop function if exists cma.attempts_groups_from(cma.attempt_deal[], text);
    drop function if exists cma.attempts_list_from(cma.attempt_deal[], integer);
    drop function if exists cma.attempts_filter_lists_from(cma.attempt_deal[]);
    drop view if exists cma_read.attempts_per_deal;
    drop function if exists cma_read.attempts_per_deal_rows();
    drop type cma.attempt_deal;
  end if;
end
$$;

do $$
begin
  if to_regtype('cma.attempt_deal') is null then
    create type cma.attempt_deal as (
      tenant_id                   uuid,
      deal_id                     uuid,
      connection_id               uuid,
      source_system               text,
      deal_source_id              text,
      record_url                  text,
      pipeline_id                 text,
      pipeline_label              text,
      stage_id                    text,
      stage_label                 text,
      market                      text,
      owner_ref                   text,
      owner_user_id               uuid,
      created_at                  timestamptz,
      business_date               date,
      week_start                  date,
      local_time                  time,
      is_closed                   boolean,
      closed_at                   timestamptz,
      ordered_at                  timestamptz,
      window_end_reason           text,
      outcome                     text,
      attempts                    integer,
      conversation_attempts       integer,
      first_conversation_attempt  integer,
      talk_seconds_total          integer,
      talk_seconds_conversation   integer,
      first_attempt_at            timestamptz,
      speed_to_lead_seconds       integer,
      called_before_next_noon     boolean,
      last_attempt_at             timestamptz,
      business_days_since_last    integer,
      since_last_from             integer,
      since_last_to               integer,
      since_last_bucket           text,
      attempts_without_outcome    integer,
      logged_without_aircall      integer
    );
  end if;
end
$$;
comment on type cma.attempt_deal is
  'One sales deal as cma.attempts_per_deal_of gives it (0008zc): its window and outcome, its attempts, how many were a conversation and the first that was, talk time in all and on the conversations, the first attempt with the speed to lead, the last attempt and, open, the business days since it; the attempts without an outcome and the outbound CRM calls logged without a telephony call';

-- As 0008z (94), with the conversations in place of reached. One row per sales deal created in [p_from, p_to) (null: unbounded), as of p_now (now() for the application; a
-- verifier gives a fixed instant). Each deal's calls are read once (cma.deal_attempts_of); the speed to lead is
-- cma.business_seconds_of's for each attempted deal; the next business noon, which depends only on the market and
-- the local date of the creation, is cma.next_business_noon_of's once per market and date; an open deal's business
-- days since its last attempt are cma.business_days_of's once per market and local date counted from, and the
-- bucket cma.age_bucket_of's once per number of days (as 0008y); the link through cma.record_url; the owner through
-- the linked account <source>_owner
create or replace function cma.attempts_per_deal_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz,
                                                    p_now timestamptz default now())
returns setof cma.attempt_deal
language sql stable
as $$
  with s as materialized (
    select t.timezone as zone,
           greatest(0, cma.setting_of(t.id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min,
           cma.setting_of(t.id, 'attempts.since_last_buckets_business_days') as edges,
           cma.setting_of(t.id, 'attempts.source') as source
    from cma.tenant t where t.id = p_tenant_id
  ),
  d as materialized (
    select * from cma.sales_deals_of(p_tenant_id, p_from, p_to, p_now)
  ),
  r as materialized (
    select d.*, a.*, xo.user_id as owner_user_id,
           -- the local date the business days of an open deal with business hours count from
           case when d.outcome = 'open' and d.market_zone is not null
                then (coalesce(a.last_at, d.created_at) at time zone d.market_zone)::date end as since_day,
           case when d.market_zone is not null then (d.created_at at time zone d.market_zone)::date end as created_day
    from d
    cross join s
    -- the deal's calls, read once: its attempts in the window and the outbound calls logged without a telephony call
    cross join lateral (
      select (count(*) filter (where z.is_attempt))::integer as attempts,
             (count(*) filter (where z.is_attempt and z.conversation))::integer as conversations,
             (min(z.n) filter (where z.is_attempt and z.conversation))::integer as first_conversation,
             coalesce(sum(z.talk_seconds) filter (where z.is_attempt), 0)::integer as talk_total,
             coalesce(sum(z.talk_seconds) filter (where z.is_attempt and z.conversation), 0)::integer as talk_conversation,
             min(z.effective_at) filter (where z.is_attempt) as first_at,
             max(z.effective_at) filter (where z.is_attempt) as last_at,
             (count(*) filter (where z.is_attempt and not z.has_outcome))::integer as no_outcome,
             (count(*) filter (where z.without_aircall))::integer as without_aircall
      from cma.deal_attempts_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts,
                                d.created_at - make_interval(mins => s.pre_min), d.window_end, s.source) z) a
    left join cma.app_user_external_id xo
      on xo.tenant_id = p_tenant_id and xo.system = d.source_system || '_owner' and xo.external_id = d.owner_ref
  ),
  -- the next business noon of each market and local date of a creation (noon of the date stands for it)
  nn as materialized (
    select x.market, x.created_day,
           cma.next_business_noon_of(p_tenant_id, x.market, (x.created_day + time '12:00') at time zone x.market_zone) as noon
    from (select distinct r.market, r.market_zone, r.created_day from r where r.created_day is not null) x
  ),
  -- the business days from each market and local date to p_now (noon of the date stands for it)
  bd as materialized (
    select x.market, x.since_day,
           cma.business_days_of(p_tenant_id, x.market, (x.since_day + time '12:00') at time zone x.market_zone, p_now) as days
    from (select distinct r.market, r.market_zone, r.since_day from r where r.since_day is not null) x
  ),
  -- the bucket of each number of days
  bk as materialized (
    select x.days, b.bucket_from, b.bucket_to
    from (select distinct bd.days from bd where bd.days is not null) x
    cross join s
    cross join lateral cma.age_bucket_of(x.days, s.edges) b
  )
  select p_tenant_id, r.deal_id, r.connection_id, r.source_system, r.source_id,
         cma.record_url(r.connection_id, r.record_type, r.source_id),
         r.pipeline_id, r.pipeline_label, r.stage_id, r.stage_label, r.market, r.owner_ref, r.owner_user_id,
         r.created_at, r.business_date, date_trunc('week', r.business_date)::date, (r.created_at at time zone s.zone)::time,
         r.is_closed, r.closed_at, r.ordered_at, r.window_end_reason, r.outcome,
         r.attempts, r.conversations, r.first_conversation, r.talk_total, r.talk_conversation, r.first_at,
         case when r.first_at is not null then cma.business_seconds_of(p_tenant_id, nullif(r.market, 'unknown'), r.created_at, r.first_at) end,
         case when r.first_at is not null and nn.noon is not null then r.first_at < nn.noon
              when r.first_at is null and nn.noon is not null and p_now >= nn.noon then false end,
         r.last_at, bd.days, bk.bucket_from, bk.bucket_to,
         case when bk.bucket_from is not null
              then case when bk.bucket_to is null then bk.bucket_from || '+' else bk.bucket_from || '–' || bk.bucket_to end end,
         r.no_outcome, r.without_aircall
  from r
  cross join s
  left join nn on nn.market = r.market and nn.created_day = r.created_day
  left join bd on bd.market = r.market and bd.since_day = r.since_day
  left join bk on bk.days = bd.days
$$;


-- As 0008z (94), with the renamed columns. The deals of the business dates [p_from, p_to] (the tenant's zone) in one pass of cma.attempts_per_deal_of, without
-- their record links (the list builds the links of the rows it shows; left unread, the planner does not compute them).
-- The tenant, the bounds and the instant reach the query as literals (one statement, planned once per call with them
-- known), so the definition is inlined and planned for this tenant and span: as a SQL function taking the zone from a
-- subquery it ran as a function scan on a generic plan, and as a PL/pgSQL query with parameters it turned to a generic
-- plan after five calls in a session, each two to two and a half times slower at twice prod's volume (local-records-0008z)
create or replace function cma.attempts_rows_of(p_tenant_id uuid, p_from date, p_to date, p_now timestamptz)
returns cma.attempt_deal[]
language plpgsql stable
as $$
declare
  v_zone text;
  v_rows cma.attempt_deal[];
begin
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  execute format(
    'select coalesce(array_agg(row(x.tenant_id, x.deal_id, x.connection_id, x.source_system, x.deal_source_id, null, x.pipeline_id,
                                   x.pipeline_label, x.stage_id, x.stage_label, x.market, x.owner_ref, x.owner_user_id, x.created_at,
                                   x.business_date, x.week_start, x.local_time, x.is_closed, x.closed_at, x.ordered_at, x.window_end_reason,
                                   x.outcome, x.attempts, x.conversation_attempts, x.first_conversation_attempt, x.talk_seconds_total,
                                   x.talk_seconds_conversation, x.first_attempt_at, x.speed_to_lead_seconds, x.called_before_next_noon,
                                   x.last_attempt_at, x.business_days_since_last, x.since_last_from, x.since_last_to, x.since_last_bucket,
                                   x.attempts_without_outcome, x.logged_without_aircall)::cma.attempt_deal), ''{}'')
     from cma.attempts_per_deal_of(%L::uuid, %L::timestamptz, %L::timestamptz, %L::timestamptz) x',
    p_tenant_id, p_from::timestamp at time zone v_zone, (p_to + 1)::timestamp at time zone v_zone, p_now)
  into v_rows;
  return v_rows;
end
$$;

-- The deals of business dates [p_from, p_to] among deals already read, cut on p_to at p_until's time of day in the
-- tenant's zone (the previous span, like for like: cma.forms_previous_of), narrowed by market, pipeline, whether
-- attempted (none: no attempt yet; some: at least one) and the outcome
create or replace function cma.attempts_in_period(p_rows cma.attempt_deal[], p_from date, p_to date, p_market text, p_pipeline text,
                                                  p_attempted text, p_outcome text, p_until timestamptz, p_zone text)
returns cma.attempt_deal[]
language sql stable
as $$
  select coalesce(array_agg(row(r.*)::cma.attempt_deal), '{}')
  from unnest(p_rows) r
  where r.business_date between p_from and p_to
    and (p_until is null or r.business_date < p_to or r.local_time <= (p_until at time zone p_zone)::time)
    and (p_market is null or r.market = p_market)
    and (p_pipeline is null or r.connection_id::text || ':' || r.pipeline_id = p_pipeline)
    and (coalesce(p_attempted, 'all') = 'all' or (p_attempted = 'none') = (r.attempts = 0))
    and (coalesce(p_outcome, 'all') = 'all' or r.outcome = p_outcome)
$$;

-- As 0008z (94), with the conversations in place of reached. The figures of a set of deals: deals; attempted (at least
-- one attempt); attempts; the average and the median attempts per deal (every deal, never attempted ones as 0);
-- conversation_deals (any attempt a conversation), first_conversation (the first attempt a conversation),
-- conversation_attempts; the median speed to lead over the attempted deals with business hours
-- (speed_deals of them); called before the next noon of those whose answer is known (noon_known); open deals and open
-- deals with no attempt yet; won, lost, ordered, unknown; talk time in all and on the conversations; the attempts
-- without an outcome; the outbound CRM calls logged without a telephony call
create or replace function cma.attempts_figures_from(p_rows cma.attempt_deal[])
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'deals', count(*),
    'attempted', count(*) filter (where r.attempts > 0),
    'attempts', coalesce(sum(r.attempts), 0),
    'avg_attempts', round(avg(r.attempts)::numeric, 2),
    'median_attempts', round((percentile_cont(0.5) within group (order by r.attempts))::numeric, 1),
    'conversation_deals', count(*) filter (where r.conversation_attempts > 0),
    'first_conversation', count(*) filter (where r.first_conversation_attempt = 1),
    'conversation_attempts', coalesce(sum(r.conversation_attempts), 0),
    'speed_deals', count(r.speed_to_lead_seconds),
    'median_speed_seconds', round(percentile_cont(0.5) within group (order by r.speed_to_lead_seconds))::integer,
    'noon_known', count(r.called_before_next_noon),
    'called_before_noon', count(*) filter (where r.called_before_next_noon),
    'open_deals', count(*) filter (where r.outcome = 'open'),
    'open_never_attempted', count(*) filter (where r.outcome = 'open' and r.attempts = 0),
    'won', count(*) filter (where r.outcome = 'won'),
    'lost', count(*) filter (where r.outcome = 'lost'),
    'ordered', count(*) filter (where r.outcome = 'ordered'),
    'unknown', count(*) filter (where r.outcome = 'unknown'),
    'talk_seconds_total', coalesce(sum(r.talk_seconds_total), 0),
    'talk_seconds_conversation', coalesce(sum(r.talk_seconds_conversation), 0),
    'attempts_without_outcome', coalesce(sum(r.attempts_without_outcome), 0),
    'logged_without_aircall', coalesce(sum(r.logged_without_aircall), 0))
  from unnest(coalesce(p_rows, '{}')) r
$$;

-- As 0008z (94). Per attempt bucket 0 to p_max ("p_max+" holds that many or more): the deals with that many attempts,
-- the deals whose first conversation was that attempt (none for 0), and of the decided deals, the won and the lost
create or replace function cma.attempts_buckets_from(p_rows cma.attempt_deal[], p_max integer)
returns jsonb
language sql immutable
as $$
  with r as (
    -- least() passes over a null, so a deal without a conversation gets no first bucket rather than the top one
    select least(x.attempts, p_max) as bucket,
           case when x.first_conversation_attempt is not null then least(x.first_conversation_attempt, p_max) end as first_bucket, x.outcome
    from unnest(coalesce(p_rows, '{}')) x
  )
  select jsonb_agg(jsonb_build_object(
           'bucket', g.b,
           'label', case when g.b = p_max then g.b || '+' else g.b::text end,
           'deals', (select count(*) from r where r.bucket = g.b),
           'first_conversation', (select count(*) from r where r.first_bucket = g.b),
           'won', (select count(*) from r where r.bucket = g.b and r.outcome = 'won'),
           'lost', (select count(*) from r where r.bucket = g.b and r.outcome = 'lost'))
         order by g.b)
  from generate_series(0, p_max) g(b)
$$;

-- As 0008z (94), with the conversations in place of reached. Won against lost (Kira's comparison): of the decided
-- deals, one row for won and one for lost with the deals, the average and median attempts, the median speed to lead
-- (over the attempted deals with business hours), called before the next noon (of those whose answer is known), with
-- at least one conversation, and the average talk time on the conversations of those deals; beside them the deals not
-- decided (open, ordered, unknown), each counted
create or replace function cma.attempts_outcomes_from(p_rows cma.attempt_deal[])
returns jsonb
language sql immutable
as $$
  with r as (select x.* from unnest(coalesce(p_rows, '{}')) x)
  select jsonb_build_object(
    'rows', (select jsonb_agg(jsonb_build_object(
                      'outcome', o.outcome,
                      'deals', (select count(*) from r where r.outcome = o.outcome),
                      'avg_attempts', (select round(avg(r.attempts)::numeric, 2) from r where r.outcome = o.outcome),
                      'median_attempts', (select round((percentile_cont(0.5) within group (order by r.attempts))::numeric, 1) from r where r.outcome = o.outcome),
                      'speed_deals', (select count(r.speed_to_lead_seconds) from r where r.outcome = o.outcome),
                      'median_speed_seconds', (select round(percentile_cont(0.5) within group (order by r.speed_to_lead_seconds))::integer
                                               from r where r.outcome = o.outcome),
                      'noon_known', (select count(r.called_before_next_noon) from r where r.outcome = o.outcome),
                      'called_before_noon', (select count(*) from r where r.outcome = o.outcome and r.called_before_next_noon),
                      'conversation_deals', (select count(*) from r where r.outcome = o.outcome and r.conversation_attempts > 0),
                      'avg_talk_conversation_seconds', (select round(avg(r.talk_seconds_conversation))::integer from r
                                                        where r.outcome = o.outcome and r.conversation_attempts > 0))
                    order by o.ord)
             from (values ('won', 1), ('lost', 2)) o(outcome, ord)),
    'not_decided', (select count(*) from r where r.outcome in ('open', 'ordered', 'unknown')),
    'open', (select count(*) from r where r.outcome = 'open'),
    'ordered', (select count(*) from r where r.outcome = 'ordered'),
    'unknown', (select count(*) from r where r.outcome = 'unknown'))
$$;

-- The win rate by speed to lead: of the decided deals (won or lost), per bucket of business minutes from the creation to
-- the first attempt (the edges '5,15,60,240,1440': 0–5, 5–15, ..., 1440+, as cma.age_bucket_of places a whole number of
-- minutes, rounded up, so a speed at an edge falls in the bucket that ends there), the won and the lost, every bucket
-- listed; the decided deals never attempted (none) and those attempted in a market without business hours (no_hours) apart
create or replace function cma.attempts_speed_buckets_from(p_rows cma.attempt_deal[], p_edges text)
returns jsonb
language sql immutable
as $$
  with e as (
    select x::integer as edge, ord
    from unnest(string_to_array(regexp_replace(coalesce(p_edges, ''), '[[:space:]]', '', 'g'), ',')) with ordinality as u(x, ord)
    where x ~ '^[0-9]+$'
  ),
  b as (
    select coalesce(lag(e.edge) over (order by e.ord), 0) as bfrom, e.edge as bto from e
    union all
    select coalesce(max(e.edge), 0), null from e
  ),
  r as (
    select x.outcome, x.attempts, x.speed_to_lead_seconds, k.bucket_from, k.bucket_to
    from unnest(coalesce(p_rows, '{}')) x
    left join lateral cma.age_bucket_of(ceil(x.speed_to_lead_seconds / 60.0)::integer, p_edges) k on true
    where x.outcome in ('won', 'lost')
  )
  select jsonb_build_object(
    'buckets', coalesce((select jsonb_agg(jsonb_build_object(
                          'from', b.bfrom, 'to', b.bto,
                          'label', case when b.bto is null then b.bfrom || '+' else b.bfrom || '–' || b.bto end,
                          'won', (select count(*) from r where r.bucket_from = b.bfrom and r.bucket_to is not distinct from b.bto and r.outcome = 'won'),
                          'lost', (select count(*) from r where r.bucket_from = b.bfrom and r.bucket_to is not distinct from b.bto and r.outcome = 'lost'))
                        order by b.bfrom, b.bto nulls last) from b), '[]'::jsonb),
    'none', jsonb_build_object('won', (select count(*) from r where r.attempts = 0 and r.outcome = 'won'),
                               'lost', (select count(*) from r where r.attempts = 0 and r.outcome = 'lost')),
    'no_hours', (select count(*) from r where r.attempts > 0 and r.speed_to_lead_seconds is null))
$$;

-- The open deals by the business days since their last attempt, in the buckets of the edges ('1,2,5': 0–1, 1–2, 2–5,
-- 5+, as cma.age_bucket_of places them), every bucket listed; the open deals of an unknown market apart. Open: the
-- outcome open (an ordered deal is not)
create or replace function cma.attempts_since_last_from(p_rows cma.attempt_deal[], p_edges text)
returns jsonb
language sql immutable
as $$
  with e as (
    select x::integer as edge, ord
    from unnest(string_to_array(regexp_replace(coalesce(p_edges, ''), '[[:space:]]', '', 'g'), ',')) with ordinality as u(x, ord)
    where x ~ '^[0-9]+$'
  ),
  b as (
    select coalesce(lag(e.edge) over (order by e.ord), 0) as bfrom, e.edge as bto from e
    union all
    select coalesce(max(e.edge), 0), null from e
  ),
  o as (select x.* from unnest(coalesce(p_rows, '{}')) x where x.outcome = 'open')
  select jsonb_build_object(
    'buckets', coalesce((select jsonb_agg(jsonb_build_object(
                          'from', b.bfrom, 'to', b.bto,
                          'label', case when b.bto is null then b.bfrom || '+' else b.bfrom || '–' || b.bto end,
                          'deals', (select count(*) from o where o.since_last_from = b.bfrom and o.since_last_to is not distinct from b.bto))
                        order by b.bfrom, b.bto nulls last) from b), '[]'::jsonb),
    'no_hours', (select count(*) from o where o.business_days_since_last is null))
$$;

-- The figures per group of one grouping: day (the business date), week (its ISO week's Monday), market, pipeline
-- ('<connection id>:<pipeline id>' with its label); by key, pipelines by label
create or replace function cma.attempts_groups_from(p_rows cma.attempt_deal[], p_group text)
returns jsonb
language sql immutable
as $$
  with r as (
    select row(x.*)::cma.attempt_deal as rec,
           case p_group when 'day' then x.business_date::text when 'week' then x.week_start::text when 'market' then x.market
                        else x.connection_id::text || ':' || x.pipeline_id end as k,
           case p_group when 'pipeline' then x.pipeline_label end as lbl
    from unnest(coalesce(p_rows, '{}')) x
  ),
  g as (
    select r.k, max(r.lbl) as lbl, cma.attempts_figures_from(array_agg(r.rec)) as f
    from r
    group by r.k
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', g.k, 'label', g.lbl) || g.f order by g.lbl nulls first, g.k), '[]'::jsonb)
  from g
$$;

-- The list: the open deals first, the longest since the last attempt (or creation) first, an unknown market's after
-- them; then the decided deals (closed or ordered), the newest end of the window first; the first p_limit with the
-- total. Ids, codes, counts, times and the record link only; deal_id is the CMA's id of the deal, for its attempts
create or replace function cma.attempts_list_from(p_rows cma.attempt_deal[], p_limit integer)
returns jsonb
language sql stable
as $$
  with r as (
    select x.*, x.outcome = 'open' as is_open,
           case x.window_end_reason when 'closed' then x.closed_at when 'ordered' then x.ordered_at end as ended_at
    from unnest(coalesce(p_rows, '{}')) x
  ),
  shown as (
    select r.*,
           row_number() over (order by r.is_open desc,
                                       case when r.is_open then r.business_days_since_last end desc nulls last,
                                       case when r.is_open then coalesce(r.last_attempt_at, r.created_at) end,
                                       case when not r.is_open then coalesce(r.ended_at, r.created_at) end desc,
                                       r.created_at desc, r.deal_source_id) as ord
    from r
  )
  select jsonb_build_object(
    'total', (select count(*) from r),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
               'deal_id', s.deal_id, 'connection_id', s.connection_id, 'deal_source_id', s.deal_source_id,
               'record_url', coalesce(s.record_url, cma.record_url(s.connection_id, 'deal', s.deal_source_id)),
               'pipeline_label', s.pipeline_label, 'stage_label', s.stage_label, 'market', s.market, 'created_at', s.created_at,
               'closed_at', s.closed_at, 'ordered_at', s.ordered_at, 'window_end_reason', s.window_end_reason, 'outcome', s.outcome,
               'attempts', s.attempts, 'conversation_attempts', s.conversation_attempts,
               'first_conversation_attempt', s.first_conversation_attempt,
               'talk_seconds_total', s.talk_seconds_total, 'talk_seconds_conversation', s.talk_seconds_conversation,
               'first_attempt_at', s.first_attempt_at, 'speed_to_lead_seconds', s.speed_to_lead_seconds,
               'called_before_next_noon', s.called_before_next_noon, 'last_attempt_at', s.last_attempt_at,
               'business_days_since_last', s.business_days_since_last, 'since_last_bucket', s.since_last_bucket,
               'logged_without_aircall', s.logged_without_aircall)
             order by s.ord)
             from shown s where s.ord <= p_limit), '[]'::jsonb))
$$;

-- The filter lists from the period's deals without the filters: the markets (unknown last) and the lead pipelines
-- ('<connection id>:<pipeline id>' with the label, by label)
create or replace function cma.attempts_filter_lists_from(p_rows cma.attempt_deal[])
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'markets', coalesce((select jsonb_agg(m.market order by m.market = 'unknown', m.market)
                         from (select distinct x.market from unnest(coalesce(p_rows, '{}')) x) m), '[]'::jsonb),
    'pipelines', coalesce((select jsonb_agg(jsonb_build_object('key', p.k, 'label', p.lbl) order by p.lbl, p.k)
                           from (select x.connection_id::text || ':' || x.pipeline_id as k, max(x.pipeline_label) as lbl
                                 from unnest(coalesce(p_rows, '{}')) x where x.pipeline_id is not null group by 1) p), '[]'::jsonb))
$$;

-- As 0008z (94), with the Conversation threshold in place of reached's. The settings the pages' hints name, as their
-- effective values
create or replace function cma.attempts_settings_of(p_tenant_id uuid)
returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'max_bucket', cma.setting_of(p_tenant_id, 'attempts.max_bucket')::integer,
    'since_last_buckets', cma.setting_of(p_tenant_id, 'attempts.since_last_buckets_business_days'),
    'pre_window_minutes', greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer),
    'list_rows', cma.setting_of(p_tenant_id, 'follow_up.list_rows')::integer,
    'source', cma.setting_of(p_tenant_id, 'attempts.source'),
    'conversation_min_talk_seconds', greatest(0, cma.setting_of(p_tenant_id, 'calls.conversation_min_talk_seconds')::integer),
    'speed_buckets', cma.setting_of(p_tenant_id, 'attempts.speed_buckets_business_minutes'))
$$;

drop function if exists cma.attempts_of_deal(uuid);


-- As 0008z (94), with connected and conversation in place of answered and reached (reached_by is gone: the outcome
-- decides nothing). One sales deal's attempts in time order, as the definition counts them now (reports.view or
-- performance.team; the current tenant only): n, the start, connected, talk time, conversation, the outcome's catalog
-- label, and the
-- agent's name only while the tenant's reports.per_person holds attempts and the caller holds performance.team
-- (null otherwise). Never a call id, a number, a hash or a recording. CMA02 for a deal the tenant does not hold as
-- a sales deal (another tenant's, deleted, of another pipeline, before the intake start)
create function cma.attempts_of_deal(p_deal_id uuid)
returns table (
  n              integer,
  started_at     timestamptz,
  connected      boolean,
  talk_seconds   integer,
  conversation   boolean,
  outcome_label  text,
  agent_name     text
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_user    uuid;
  v_created timestamptz;
  v_deal    record;
  v_pre     integer;
  v_names   boolean;
  v_found   boolean := false;
begin
  v_user := cma.assert_any_permission(array['reports.view', 'performance.team']);
  select r.source_created_at into v_created
  from cma.crm_record r
  where r.tenant_id = v_tenant and r.id = p_deal_id and r.record_type = 'deal';
  if v_created is not null then
    select x.* into v_deal from cma.sales_deals_of(v_tenant, v_created, v_created + interval '1 millisecond', now()) x
    where x.deal_id = p_deal_id;
    v_found := found;
  end if;
  if not v_found then
    raise exception 'no sales deal %', p_deal_id using errcode = 'CMA02';
  end if;
  v_pre := greatest(0, cma.setting_of(v_tenant, 'speed_to_lead.pre_window_minutes')::integer);
  v_names := cma.per_person_on(v_tenant, 'attempts') and cma.has_permission(v_user, 'performance.team');
  return query
    select z.n, z.effective_at, z.connected, z.talk_seconds, z.conversation, z.outcome_label,
           case when v_names then coalesce(
             (select u.display_name from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
              where x.tenant_id = v_tenant and x.system = z.telephony_source_system || '_user' and x.external_id = z.telephony_user_ref limit 1),
             (select u.display_name from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
              where x.tenant_id = v_tenant and x.system = z.owner_system || '_owner' and x.external_id = z.owner_ref limit 1)) end
    from cma.deal_attempts_of(v_tenant, v_deal.connection_id, v_deal.record_type, v_deal.source_id, v_deal.contacts,
                              v_deal.created_at - make_interval(mins => v_pre), v_deal.window_end,
                              cma.setting_of(v_tenant, 'attempts.source')) z
    where z.is_attempt
    order by z.n;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Grants: the application only (functions made again lost theirs; the others keep theirs and get them again)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.set_telephony_tag_meaning(uuid,text,text)',
    'cma.call_not_reached_of(uuid,uuid,text)',
    'cma.connection_catalogs(uuid)',
    'cma.is_connected(text,boolean,integer,integer)',
    'cma.is_conversation(text,boolean,integer,integer,integer,boolean)',
    'cma.calls_of(uuid,timestamptz,timestamptz,text,text)',
    'cma.calls_figures_of(uuid,date,date,text,text,text,timestamptz)',
    'cma.calls_overview_of(uuid,date,date,text,text,text,timestamptz)',
    'cma.calls_overview(date,date,text,text,text)',
    'cma.calls_tag_use_of(uuid,date,date,text,text,text)',
    'cma.calls_per_person_of(uuid,date,date,text,text)',
    'cma.calls_per_person(date,date,text,text)',
    'cma.calls_per_person_tags_of(uuid,date,date,text,text)',
    'cma.crm_call_connected_of(uuid,uuid)',
    'cma.first_orders_of(uuid,timestamptz,timestamptz)',
    'cma.data_quality_of(uuid)',
    'cma.deal_calls_of(uuid,uuid,text,text,text[],timestamptz)',
    'cma.lead_calls_of(uuid,uuid,text,text,text[],timestamptz)',
    'cma.deal_attempts_of(uuid,uuid,text,text,text[],timestamptz,timestamptz,text)',
    'cma.attempts_per_deal_of(uuid,timestamptz,timestamptz,timestamptz)',
    'cma.attempts_rows_of(uuid,date,date,timestamptz)',
    'cma.attempts_in_period(cma.attempt_deal[],date,date,text,text,text,text,timestamptz,text)',
    'cma.attempts_figures_from(cma.attempt_deal[])',
    'cma.attempts_buckets_from(cma.attempt_deal[],integer)',
    'cma.attempts_outcomes_from(cma.attempt_deal[])',
    'cma.attempts_speed_buckets_from(cma.attempt_deal[],text)',
    'cma.attempts_since_last_from(cma.attempt_deal[],text)',
    'cma.attempts_groups_from(cma.attempt_deal[],text)',
    'cma.attempts_list_from(cma.attempt_deal[],integer)',
    'cma.attempts_filter_lists_from(cma.attempt_deal[])',
    'cma.attempts_settings_of(uuid)',
    'cma.attempts_of_deal(uuid)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Reporting views
-- ---------------------------------------------------------------------------------------------
-- The tag catalog with the meaning last
create or replace view cma_read.telephony_tag as
  select tenant_id, connection_id, tag_ref, name, is_counted, status, refreshed_at, meaning
  from cma.telephony_tag
  where cma_read.reader_sees(tenant_id);

drop view if exists cma_read.attempts_per_deal;
drop function if exists cma_read.attempts_per_deal_rows();


-- As 0008z (94), with the conversations in place of reached (the reached columns renamed). Every sales deal since each
-- tenant's intake start, with its window, outcome and attempts as of now, for readers (so
-- Kira's team can set won against lost in BigQuery): over a SECURITY DEFINER function in cma_read (owned by cma_owner,
-- search path pinned, executable by readers only) that reads every tenant the reader sees; ids, codes, counts and times
-- only. The record link is the screens' (it needs the application's tenant). No attempt-level view
create function cma_read.attempts_per_deal_rows()
returns table (tenant_id uuid, deal_id uuid, connection_id uuid, deal_source_id text, pipeline_id text, pipeline_label text,
               stage_id text, market text, owner_user_id uuid, created_at timestamptz, business_date date, is_closed boolean,
               closed_at timestamptz, ordered_at timestamptz, window_end_reason text, outcome text, attempts integer,
               conversation_attempts integer, first_conversation_attempt integer, talk_seconds_total integer,
               talk_seconds_conversation integer,
               first_attempt_at timestamptz, speed_to_lead_seconds integer, called_before_next_noon boolean,
               last_attempt_at timestamptz, business_days_since_last integer, since_last_bucket text,
               attempts_without_outcome integer, logged_without_aircall integer)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label, r.stage_id, r.market, r.owner_user_id,
         r.created_at, r.business_date, r.is_closed, r.closed_at, r.ordered_at, r.window_end_reason, r.outcome, r.attempts,
         r.conversation_attempts, r.first_conversation_attempt, r.talk_seconds_total, r.talk_seconds_conversation, r.first_attempt_at,
         r.speed_to_lead_seconds, r.called_before_next_noon, r.last_attempt_at, r.business_days_since_last, r.since_last_bucket,
         r.attempts_without_outcome, r.logged_without_aircall
  from cma.tenant t
  cross join lateral cma.attempts_per_deal_of(t.id, null, null) r
  where cma_read.reader_sees(t.id)
$$;

do $$
begin
  execute 'revoke execute on function cma_read.attempts_per_deal_rows() from public';
  execute 'grant execute on function cma_read.attempts_per_deal_rows() to cma_readonly';
end
$$;

create or replace view cma_read.attempts_per_deal as
  select * from cma_read.attempts_per_deal_rows();

-- ---------------------------------------------------------------------------------------------
-- 9. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zc', 'Definitions step 1 (docs/definitions.md): tag meanings (cma.telephony_tag.meaning with cma.set_telephony_tag_meaning, configuration only); Connected as answered at any talk time (telephony.connected_min_seconds default 0, a value of 10 moved to 0); Conversation as a connected or answered call with at least calls.conversation_min_talk_seconds of talk (replacing attempts.reached_min_talk_seconds) and no current tag meaning not_reached, through the linked telephony call only (cma.is_connected, cma.is_conversation, cma.call_not_reached_of); Calls and Calls per agent with connected, connected_rate and untagged over every call, talk time over the answered calls, tag use without the untagged row; Email''s not responding and first orders from the linked telephony call; the data-quality skip by its own rule; Attempts per deal with connected and conversation, the reached columns renamed to conversation in cma.attempt_deal and cma_read.attempts_per_deal')
on conflict (version) do nothing;

commit;
reset role;
