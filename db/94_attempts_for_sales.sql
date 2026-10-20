-- =============================================================================================
-- 94_attempts_for_sales.sql: addition 0008z, attempts per deal for sales, and message withdrawal
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 92_attempts_per_deal.sql (0008y). Rerunnable, forward-only, in one transaction. Run as your own IAM login:
-- dev first, then 95_verify_attempts_for_sales.sql (dev), then 93, 41, 61, 69, 73, 75, 77, 81, 83, 85, 89 and 91
-- again (dev; 91 from the Terminal); then prod, right before the web that reads the new page reads is merged.
-- The web of main (0008y) calls the attempts reads with the scope this addition removes: between this script
-- and the deploy its Attempts per deal and Attempts per agent answer an error, nothing else changes, so prod
-- runs it outside office hours and merges at once (docs/attempts-2026-10/RUNBOOK-0008z.md).
--
-- Brief of 20 October 2026 (Martin; README Decision log, KPIs 1):
--   A  Attempts per deal is rebuilt for sales. The agents must make enough attempts and no sales deal may be
--      missed; Kira compares Closed Won against Closed Lost on attempts and speed to lead. Pulse4all keeps
--      calling customers after a sale (courtesy, OPC, service calls): those are no attempts. Aircall's
--      answered is a technical connection that includes voicemail boxes, not a conversation; a human agent's
--      outbound call carries no voicemail flag, so reached is read from the outcome the agent sets in the CRM,
--      else from the talk time
--   B  An admin deletes a message for everyone: a withdrawal, never a delete (messages keep no-delete and audit)
--
-- What it adds or changes (A)
--   settings           attempts.source: telephony (the default: an outbound telephony call whose CRM call is
--                      associated with the deal or its contacts) or crm (every outbound CRM call, as 0008y);
--                      attempts.reached_min_talk_seconds (30, 0 to 600): an attempt without an outcome is
--                      reached at this much talk time or more; attempts.speed_buckets_business_minutes
--                      ('5,15,60,240,1440'): the buckets of the win rate by speed to lead, one to six increasing
--                      whole numbers (as the other bucket settings, spaces dropped)
--   the calls          cma.deal_calls_of(): 0007d's calls of a deal (cma.lead_calls_of's rule, unchanged) with the
--                      linked telephony call's direction, answer, talk time (ended - answered, no ringing, as
--                      cma.calls_of), user and line, and the outcome's label and connected flag. cma.lead_calls_of
--                      keeps its signature and rows and reads it, so the rule is written once
--   the orders         cma.contact_store_orders_of(): 0007d's store orders of a CRM contact (its commerce ids in
--                      any ref slot, the ref system equal to the order's source system; not a test, not cancelled,
--                      not deleted). cma.lead_to_order_of keeps its signature and rows and reads it
--   the population     cma.sales_deals_of(): the deals of the lead pipelines (cma.counted_deals_of's lead rule; an
--                      order pipeline never), each with its window: from the creation minus
--                      speed_to_lead.pre_window_minutes to the earliest of its close (won or lost), its first order
--                      (below) and now; ordered_at and window_end_reason (closed, ordered, open); the outcome won,
--                      lost, open, ordered (an order another way while the deal was open and not won) or unknown
--   the attempts       cma.deal_attempts_of(): a deal's attempts in its window, numbered, each reached or not and
--                      by what (outcome, talk_time), its talk time and answered flag; and the outbound CRM calls
--                      logged without a telephony call (never an attempt under telephony)
--   the definition     cma.attempts_per_deal_of(tenant, from, to, now): one row per sales deal (the row type
--                      cma.attempt_deal, rebuilt): the window, the outcome, the attempts, reached, the first
--                      reached attempt, talk time in all and in contact, the first attempt and the speed to lead
--                      (0007d's business seconds and the next business noon), the last attempt, the business days
--                      since it (open deals), the attempts without an outcome and the calls logged without
--                      the telephony call
--   reads              cma.attempts_per_deal_page(from, to, group, market, pipeline, attempted, outcome, rows):
--                      the figures and the previous period like for like, won against lost, the win rate by
--                      attempts and by speed to lead, the distribution, reached per attempt, the open deals by
--                      time since the last attempt, the groups, the list; cma.attempts_per_person_page(from, to,
--                      market, pipeline, attempted, outcome); cma.attempts_of_deal(deal): one deal's attempts.
--                      The scope of 0008y is gone (its functions are dropped); the filters attempted (all, none,
--                      some) and outcome (all, open, won, lost, ordered) narrow every figure
--   reporting view     cma_read.attempts_per_deal with the new columns (is_lead, connected and
--                      first_connected_attempt leave it: every row is a sales deal, and reached replaces connected)
-- What it adds (B)
--   message            withdrawn_at and withdrawn_by (both or neither, set once, never cleared); the application
--                      may update those two columns only, and a trigger keeps everything else of a message as it is
--   permission         messages.withdraw, on the default ladder's admin role (new tenants by cma.seed_default_roles,
--                      existing tenants' system admin role here); a tenant's own roles stay as they are
--   functions          cma.withdraw_message(id) (messages.withdraw; any message of the tenant, manual or alert;
--                      a second withdrawal changes nothing); cma.my_messages, my_unread_count, mark_messages_read and
--                      acknowledge_message leave a withdrawn message out, so a delivery not yet made never happens
--                      (the poll is the delivery, README Messaging); cma.message_stats gains withdrawn_at and
--                      withdrawn_by; cma_read.message gains both columns last
--
-- Definitions (one place each; README, Data model: attempts per deal). 0007d's, 0008u's and 0008y's are reused,
-- never copied:
--   deal               a deal of a counted lead pipeline (cma.counted_deals_of with is_lead), never of an order
--                      pipeline (is_order, 0008u), not deleted, created on or after intake.start_date
--   window             from the creation minus speed_to_lead.pre_window_minutes to the earliest of the close (a
--                      closed deal; now when it has no closing time), the first order and now
--   first order        of the deal's contacts (its primary contact and the contacts currently associated with it,
--                      cma.counted_deals_of's), at or after the deal's creation and at or before now: a won deal of
--                      an order pipeline (cma.counted_deals_of's order deals whose stage outcome is won) holding one
--                      of those contacts, at its close; or a store order of one of them
--                      (cma.contact_store_orders_of), at its creation. No lead_to_order.max_days cap
--   attempt            telephony: an outbound telephony call, not deleted, with a start, on a counted line (a line
--                      not yet in the catalog counts, as cma.calls_of), linked to a CRM call of cma.lead_calls_of
--                      (associated with the deal or its contacts), its start in the window; crm: an outbound CRM
--                      call of cma.lead_calls_of with its effective start in the window. In order of the start,
--                      then the CRM call's id
--   logged without     an outbound CRM call in the window without a current link to a telephony call with a start
--   reached            the CRM call's outcome counts as connected (connection_call_outcome.is_connected) when it has
--                      an outcome; else talk time of at least attempts.reached_min_talk_seconds; answered alone
--                      is not reached. reached_by: outcome, talk_time or none
--   talk time          the telephony call's talk_seconds (ended - answered, no ringing); none without one
--   speed to lead      cma.business_seconds_of from the creation to the first attempt (0 for an attempt in the
--                      pre-window), none for an unknown market; called before the next noon as 0007d: the first
--                      attempt before cma.next_business_noon_of the creation, false once that noon passed without one
--   outcome            won (the stage's outcome); else ordered (the window ended at the first order); else lost
--                      (the stage's outcome); else unknown (closed) or open
--   since the last     an open deal's business days in its market from its last attempt, or its creation, to now
--                      (cma.business_days_of, 0008o), bucketed by cma.age_bucket_of; none for an unknown market
--   agent              of one attempt, on cma.attempts_of_deal only: the person behind the telephony user
--                      (<adapter>_user, 0008e), else behind the CRM call's owner (<adapter>_owner); a name only
--                      while reports.per_person holds attempts and the caller holds performance.team
--
-- Everything is SECURITY INVOKER and executable by the application only; the cma_read function of the reader view
-- is SECURITY DEFINER, owned by cma_owner, search path pinned with pg_temp last, executable by readers only. No
-- table and no index: the reads use the indexes 0007d's reads use. The reads return ids, codes, counts, links and
-- times; a person's name only where a per-person page shows one.
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
  if not exists (select 1 from cma.schema_migration where version = '0008y') then
    raise exception 'addition 0008y (92_attempts_per_deal.sql) must run before 0008z';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('attempts.source',                          'text',    array['telephony', 'crm'], 'telephony',
     'What counts as an attempt on a sales deal: telephony (an outbound telephony call whose CRM call is associated with the deal or its contacts) or crm (every outbound CRM call)'),
  ('attempts.reached_min_talk_seconds',        'integer', null, '30',
     'An attempt whose CRM call has no outcome reaches the customer at this many seconds of talk time or more (0 to 600); with an outcome, the outcome decides'),
  ('attempts.speed_buckets_business_minutes',  'text',    null, '5,15,60,240,1440',
     'Buckets of the win rate by speed to lead, in business minutes: one to six increasing whole numbers, comma-separated, such as 5,15,60,240,1440')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0008y, plus the reached talk time and the speed buckets (the source is held to its two values by the catalog)
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
    raise exception 'Setting % takes email, orders and attempts, each at most once, lower case, comma-separated without spaces, or nothing', new.key
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
  elsif new.key = 'attempts.reached_min_talk_seconds'
        and (case when length(new.value) > 3 then true else new.value::integer not between 0 and 600 end) then
    raise exception 'Setting % takes a whole number of seconds from 0 to 600', new.key using errcode = 'CMA04';
  elsif new.key = 'attempts.speed_buckets_business_minutes' and not cma.is_bucket_list(new.value, 6) then
    raise exception 'Setting % takes one to six increasing whole numbers of business minutes, comma-separated, such as 5,15,60,240,1440', new.key using errcode = 'CMA04';
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The calls of a deal, written once
-- ---------------------------------------------------------------------------------------------
-- 0007d's calls of a deal (cma.lead_calls_of's rule, unchanged: CRM calls of the deal's connection, not deleted,
-- currently associated with the deal or one of its contacts, whose effective start, the linked telephony call's
-- start while the link is current and the telephony call not deleted, else the CRM call's time, is at or after
-- p_not_before; connected when the outcome counts as connected or the linked telephony call was answered), with
-- what the attempts read besides: the outcome's catalog label and its own connected flag, and the linked
-- telephony call's id, direction, answer, talk time (ended - answered, as cma.calls_of reads it), user and
-- whether its line counts (a line not yet in the catalog counts, as cma.calls_of)
create or replace function cma.deal_calls_of(p_tenant_id uuid, p_connection_id uuid, p_record_type text,
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
  outcome_ref              text,
  outcome_label            text,
  outcome_connected        boolean,
  telephony_call_id        uuid,
  telephony_source_system  text,
  telephony_direction      text,
  answered                 boolean,
  talk_seconds             integer,
  telephony_user_ref       text,
  line_counted             boolean
)
language sql stable
as $$
  select c.id, c.source_id, c.source_system, c.direction, c.owner_ref,
         coalesce(tc.started_at, c.occurred_at), tc.started_at is not null,
         coalesce(o.is_connected, false) or tc.answered_at is not null,
         c.outcome_ref, o.label, o.is_connected,
         tc.id, tc.source_system, tc.direction, tc.answered_at is not null, tc.talk_seconds, tc.user_ref,
         coalesce(n.is_counted, true)
  from cma.crm_call c
  left join cma.call_link l
    on l.tenant_id = c.tenant_id and l.crm_call_id = c.id and l.unlinked_at is null
  left join cma.telephony_call tc
    on tc.tenant_id = l.tenant_id and tc.id = l.telephony_call_id and tc.source_deleted_at is null
  left join cma.connection_call_outcome o
    on o.tenant_id = c.tenant_id and o.connection_id = c.connection_id and o.outcome_ref = c.outcome_ref
  left join cma.telephony_number n
    on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
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

-- 0007d's signature and rows, now read from cma.deal_calls_of. The planner inlines both, and leaves the line out
-- (no column of it is read here), so Speed to lead's and Follow-up's plans stay as they were
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

-- ---------------------------------------------------------------------------------------------
-- 3. The store orders of a contact, written once
-- ---------------------------------------------------------------------------------------------
-- 0007d's match of a store order to a CRM contact: the commerce ids the contact holds (crm_contact_ref, any slot),
-- the ref system equal to the order's source system; the order not a test, not cancelled, not deleted. Every
-- contact of the tenant with every such order; a reader narrows it by connection, contact and time, and the
-- planner reaches the indexes through it
create or replace function cma.contact_store_orders_of(p_tenant_id uuid)
returns table (
  connection_id        uuid,
  contact_source_id    text,
  order_id             uuid,
  order_connection_id  uuid,
  order_source_id      text,
  created_at           timestamptz,
  order_kind           text,
  currency             text,
  total_amount         numeric
)
language sql stable
as $$
  select k.connection_id, k.source_id, co.id, co.connection_id, co.source_id, co.source_created_at, co.order_kind, co.currency,
         co.total_amount
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id
  join cma.commerce_order co
    on co.tenant_id = k.tenant_id and co.source_system = r.system and co.customer_source_id = r.external_id
  where k.tenant_id = p_tenant_id
    and not co.is_test and co.cancelled_at is null and co.source_deleted_at is null
$$;

-- 0007d's lead to order with the same signature and rows: per lead deal, how many commerce ids its contacts hold,
-- and the first of their store orders (cma.contact_store_orders_of) created at or after the deal and within
-- lead_to_order.max_days
create or replace function cma.lead_to_order_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns setof cma.lead_to_order_row
language sql stable
as $$
  with s as (
    select cma.setting_of(p_tenant_id, 'lead_to_order.max_days')::integer as max_days
  ),
  refs as (
    select d.deal_id, r.system, r.external_id
    from cma.lead_deals_of(p_tenant_id, p_from, p_to) d
    join cma.crm_contact k
      on k.tenant_id = p_tenant_id and k.connection_id = d.connection_id and k.source_id = any (d.contacts)
    join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id
    group by 1, 2, 3
  )
  select p_tenant_id, d.deal_id, d.connection_id, d.source_id, d.pipeline_id, d.pipeline_label, d.business_date,
         d.created_at, d.market,
         (select count(*) from refs where refs.deal_id = d.deal_id)::integer,
         o.order_id, o.order_connection_id, o.order_source_id, o.handle, o.created_at, o.order_kind, o.currency, o.total_amount,
         case when o.order_id is not null then round(extract(epoch from o.created_at - d.created_at) / 86400, 2) end
  from cma.lead_deals_of(p_tenant_id, p_from, p_to) d
  cross join s
  left join lateral (
    select so.order_id, so.order_connection_id, so.order_source_id, st.handle, so.created_at, so.order_kind, so.currency, so.total_amount
    from cma.contact_store_orders_of(p_tenant_id) so
    left join cma.commerce_store st on st.tenant_id = p_tenant_id and st.connection_id = so.order_connection_id
    where so.connection_id = d.connection_id and so.contact_source_id = any (d.contacts)
      and so.created_at >= d.created_at
      and so.created_at <= d.created_at + make_interval(days => s.max_days)
    order by so.created_at, so.order_id
    limit 1) o on true
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The sales deals and their windows
-- ---------------------------------------------------------------------------------------------
-- The deals of the lead pipelines created in [p_from, p_to) (null: unbounded), never of an order pipeline, with
-- 0007d's shape as cma.counted_deals_of gives it, the stage's outcome and label, the market's zone, and the window
-- as of p_now: the first order of the deal's contacts (a won order deal at its close, or a store order at its
-- creation; at or after the deal's creation, at or before p_now), the window's end (the earliest of the close,
-- that order and p_now) and why it ended, and the outcome. cma.counted_deals_of is read once, from p_from without
-- an end, so the period's deals and every later order deal come from the same pass
create or replace function cma.sales_deals_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz, p_now timestamptz)
returns table (
  deal_id            uuid,
  connection_id      uuid,
  source_system      text,
  record_type        text,
  source_id          text,
  pipeline_id        text,
  pipeline_label     text,
  owner_ref          text,
  is_closed          boolean,
  created_at         timestamptz,
  business_date      date,
  market             text,
  market_zone        text,
  contacts           text[],
  stage_id           text,
  stage_label        text,
  closed_at          timestamptz,
  ordered_at         timestamptz,
  window_end         timestamptz,
  window_end_reason  text,
  outcome            text
)
language sql stable
as $$
  with x as materialized (
    select c.* from cma.counted_deals_of(p_tenant_id, p_from, null) c
  ),
  d as materialized (
    select x.*, st.outcome as stage_outcome, st.label as stage_label
    from x
    left join cma.connection_stage st
      on st.tenant_id = p_tenant_id and st.connection_id = x.connection_id and st.record_type = x.record_type
     and st.source_pipeline_id = x.pipeline_id and st.source_stage_id = x.stage_id
    where x.is_lead and not x.is_order and x.created_at < coalesce(p_to, 'infinity'::timestamptz)
  ),
  -- each deal's contacts, one row each
  dk as (
    select d.deal_id, d.connection_id, d.created_at, k.contact
    from d cross join unnest(d.contacts) k(contact)
  ),
  -- the won order deals (0008u) by contact, at their close
  od as materialized (
    select x.connection_id, k.contact, x.created_at, coalesce(x.closed_at, x.created_at) as at
    from x
    join cma.connection_stage st
      on st.tenant_id = p_tenant_id and st.connection_id = x.connection_id and st.record_type = x.record_type
     and st.source_pipeline_id = x.pipeline_id and st.source_stage_id = x.stage_id and st.outcome = 'won'
    cross join unnest(x.contacts) k(contact)
    where x.is_order
  ),
  o1 as (
    select dk.deal_id, min(od.at) as at
    from dk join od on od.connection_id = dk.connection_id and od.contact = dk.contact and od.created_at >= dk.created_at
    where od.at <= p_now
    group by dk.deal_id
  ),
  o2 as (
    select dk.deal_id, min(so.created_at) as at
    from dk
    join cma.contact_store_orders_of(p_tenant_id) so
      on so.connection_id = dk.connection_id and so.contact_source_id = dk.contact and so.created_at >= dk.created_at
    where so.created_at <= p_now
    group by dk.deal_id
  ),
  w as (
    select d.*, least(o1.at, o2.at) as ordered,
           case when d.is_closed then least(coalesce(d.closed_at, p_now), p_now) end as closed_end
    from d
    left join o1 on o1.deal_id = d.deal_id
    left join o2 on o2.deal_id = d.deal_id
  )
  select w.deal_id, w.connection_id, w.source_system, w.record_type, w.source_id, w.pipeline_id, w.pipeline_label, w.owner_ref,
         w.is_closed, w.created_at, w.business_date, w.market, mk.time_zone, w.contacts, w.stage_id, w.stage_label, w.closed_at,
         w.ordered, least(w.closed_end, w.ordered, p_now), e.reason,
         case when w.stage_outcome = 'won' then 'won' when e.reason = 'ordered' then 'ordered' when w.stage_outcome = 'lost' then 'lost'
              when w.is_closed then 'unknown' else 'open' end
  from w
  cross join lateral (
    select case when w.closed_end is not null and (w.ordered is null or w.closed_end <= w.ordered) then 'closed'
                when w.ordered is not null then 'ordered' else 'open' end as reason) e
  left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = w.market
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The attempts of a deal
-- ---------------------------------------------------------------------------------------------
-- A deal's calls from p_not_before to p_until (cma.deal_calls_of) that are attempts under p_source, numbered in
-- the order of their start (then the CRM call's id), each reached or not and by what; and the outbound CRM calls
-- without a linked telephony call (without_aircall: never an attempt under telephony, every one an attempt under
-- crm). Reached: the outcome when the CRM call has one (its catalog flag; an outcome outside the catalog is not
-- connected), else the talk time at p_reached_min or more
create or replace function cma.deal_attempts_of(p_tenant_id uuid, p_connection_id uuid, p_record_type text, p_source_id text,
                                                p_contacts text[], p_not_before timestamptz, p_until timestamptz,
                                                p_source text, p_reached_min integer)
returns table (
  n                        integer,
  call_id                  uuid,
  effective_at             timestamptz,
  answered                 boolean,
  talk_seconds             integer,
  has_outcome              boolean,
  outcome_label            text,
  reached                  boolean,
  reached_by               text,
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
         y.call_id, y.effective_at, y.answered, y.talk_seconds, y.outcome_ref is not null, y.outcome_label, y.reached,
         case when y.reached then case when y.outcome_ref is not null then 'outcome' else 'talk_time' end end,
         y.source_system, y.owner_ref, y.telephony_source_system, y.telephony_user_ref, y.is_attempt, y.without_aircall
  from (
    select c.*,
           case when p_source = 'crm' then c.direction = 'outbound'
                else c.is_linked and c.telephony_direction = 'outbound' and c.line_counted end as is_attempt,
           c.direction = 'outbound' and not c.is_linked as without_aircall,
           case when c.outcome_ref is not null then coalesce(c.outcome_connected, false)
                else coalesce(c.talk_seconds >= p_reached_min, false) end as reached
    from cma.deal_calls_of(p_tenant_id, p_connection_id, p_record_type, p_source_id, p_contacts, p_not_before) c
    where c.effective_at <= p_until
  ) y
  where y.is_attempt or y.without_aircall
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The definition: every sales deal of a period with its attempts
-- ---------------------------------------------------------------------------------------------
-- 0008y's row type, rebuilt: the old shape and the functions over it go first (each named), so nothing else is
-- dropped; a rerun finds the new shape and drops nothing
do $$
begin
  if to_regtype('cma.attempt_deal') is not null
     and not exists (select 1 from pg_attribute a
                     where a.attrelid = (select t.typrelid from pg_type t where t.oid = to_regtype('cma.attempt_deal'))
                       and a.attname = 'window_end_reason' and not a.attisdropped) then
    drop function if exists cma.attempts_per_deal_of(uuid, timestamptz, timestamptz, text, timestamptz);
    drop function if exists cma.attempts_rows_of(uuid, date, date, text, timestamptz);
    drop function if exists cma.attempts_in_period(cma.attempt_deal[], date, date, text, text, timestamptz, text);
    drop function if exists cma.attempts_figures_from(cma.attempt_deal[]);
    drop function if exists cma.attempts_buckets_from(cma.attempt_deal[], integer);
    drop function if exists cma.attempts_since_last_from(cma.attempt_deal[], text);
    drop function if exists cma.attempts_groups_from(cma.attempt_deal[], text);
    drop function if exists cma.attempts_list_from(cma.attempt_deal[], integer);
    drop function if exists cma.attempts_filter_lists_from(cma.attempt_deal[]);
    drop type cma.attempt_deal;
  end if;
end
$$;
-- 0008y's reads with the scope, and the scope's check: their signatures change or they go
drop function if exists cma.attempts_scope_check(text);
drop function if exists cma.attempts_params_check(uuid, date, date, text, text, text);
drop function if exists cma.attempts_per_deal_page_of(uuid, date, date, text, text, text, text, integer, timestamptz);
drop function if exists cma.attempts_per_person_of(uuid, date, date, text, text, text, timestamptz);
drop function if exists cma.attempts_per_deal_page(date, date, text, text, text, text, integer);
drop function if exists cma.attempts_per_person_page(date, date, text, text, text);
-- the reader function's columns change: it and its view are made again below
drop view if exists cma_read.attempts_per_deal;
drop function if exists cma_read.attempts_per_deal_rows();

do $$
begin
  if to_regtype('cma.attempt_deal') is null then
    create type cma.attempt_deal as (
      tenant_id                 uuid,
      deal_id                   uuid,
      connection_id             uuid,
      source_system             text,
      deal_source_id            text,
      record_url                text,
      pipeline_id               text,
      pipeline_label            text,
      stage_id                  text,
      stage_label               text,
      market                    text,
      owner_ref                 text,
      owner_user_id             uuid,
      created_at                timestamptz,
      business_date             date,
      week_start                date,
      local_time                time,
      is_closed                 boolean,
      closed_at                 timestamptz,
      ordered_at                timestamptz,
      window_end_reason         text,
      outcome                   text,
      attempts                  integer,
      reached_attempts          integer,
      first_reached_attempt     integer,
      talk_seconds_total        integer,
      talk_seconds_reached      integer,
      first_attempt_at          timestamptz,
      speed_to_lead_seconds     integer,
      called_before_next_noon   boolean,
      last_attempt_at           timestamptz,
      business_days_since_last  integer,
      since_last_from           integer,
      since_last_to             integer,
      since_last_bucket         text,
      attempts_without_outcome  integer,
      logged_without_aircall    integer
    );
  end if;
end
$$;
comment on type cma.attempt_deal is
  'One sales deal as cma.attempts_per_deal_of gives it (0008z): its window and outcome, its attempts, how many reached the customer and the first that did, talk time, the first attempt with the speed to lead, the last attempt and, open, the business days since it; the attempts without an outcome and the outbound CRM calls logged without a telephony call';

-- One row per sales deal created in [p_from, p_to) (null: unbounded), as of p_now (now() for the application; a
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
           cma.setting_of(t.id, 'attempts.source') as source,
           cma.setting_of(t.id, 'attempts.reached_min_talk_seconds')::integer as reached_min
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
             (count(*) filter (where z.is_attempt and z.reached))::integer as reached,
             (min(z.n) filter (where z.is_attempt and z.reached))::integer as first_reached,
             coalesce(sum(z.talk_seconds) filter (where z.is_attempt), 0)::integer as talk_total,
             coalesce(sum(z.talk_seconds) filter (where z.is_attempt and z.reached), 0)::integer as talk_reached,
             min(z.effective_at) filter (where z.is_attempt) as first_at,
             max(z.effective_at) filter (where z.is_attempt) as last_at,
             (count(*) filter (where z.is_attempt and not z.has_outcome))::integer as no_outcome,
             (count(*) filter (where z.without_aircall))::integer as without_aircall
      from cma.deal_attempts_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts,
                                d.created_at - make_interval(mins => s.pre_min), d.window_end, s.source, s.reached_min) z) a
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
         r.attempts, r.reached, r.first_reached, r.talk_total, r.talk_reached, r.first_at,
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

-- ---------------------------------------------------------------------------------------------
-- 7. The reads of an explicit tenant, from deals read once
-- ---------------------------------------------------------------------------------------------
-- The filters both pages take: a market is a two-letter code or 'unknown'; a pipeline the connection's id and the
-- pipeline's source id, joined by ':' (as 0008y); attempted all, none or some; outcome all, open, won, lost or
-- ordered. Anything else CMA04
create or replace function cma.attempts_choices_check(p_attempted text, p_outcome text)
returns void
language plpgsql immutable
as $$
begin
  if p_attempted is null or p_attempted not in ('all', 'none', 'some') then
    raise exception 'attempted is all, none or some, not %', coalesce(p_attempted, 'none') using errcode = 'CMA04';
  end if;
  if p_outcome is null or p_outcome not in ('all', 'open', 'won', 'lost', 'ordered') then
    raise exception 'outcome is all, open, won, lost or ordered, not %', coalesce(p_outcome, 'none') using errcode = 'CMA04';
  end if;
end
$$;

-- The deals of the business dates [p_from, p_to] (the tenant's zone) in one pass of cma.attempts_per_deal_of, without
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
                                   x.outcome, x.attempts, x.reached_attempts, x.first_reached_attempt, x.talk_seconds_total,
                                   x.talk_seconds_reached, x.first_attempt_at, x.speed_to_lead_seconds, x.called_before_next_noon,
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

-- The figures of a set of deals: deals; attempted (at least one attempt); attempts; the average and the median attempts
-- per deal (every deal, never attempted ones as 0); reached_deals (any attempt reached), first_reached (the first
-- attempt reached), reached_attempts; the median speed to lead over the attempted deals with business hours
-- (speed_deals of them); called before the next noon of those whose answer is known (noon_known); open deals and open
-- deals with no attempt yet; won, lost, ordered, unknown; talk time in all and in contact; the attempts without an
-- outcome; the outbound CRM calls logged without a telephony call
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
    'reached_deals', count(*) filter (where r.reached_attempts > 0),
    'first_reached', count(*) filter (where r.first_reached_attempt = 1),
    'reached_attempts', coalesce(sum(r.reached_attempts), 0),
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
    'talk_seconds_reached', coalesce(sum(r.talk_seconds_reached), 0),
    'attempts_without_outcome', coalesce(sum(r.attempts_without_outcome), 0),
    'logged_without_aircall', coalesce(sum(r.logged_without_aircall), 0))
  from unnest(coalesce(p_rows, '{}')) r
$$;

-- Per attempt bucket 0 to p_max ("p_max+" holds that many or more): the deals with that many attempts, the deals first
-- reached on that attempt (none for 0), and of the decided deals, the won and the lost
create or replace function cma.attempts_buckets_from(p_rows cma.attempt_deal[], p_max integer)
returns jsonb
language sql immutable
as $$
  with r as (
    -- least() passes over a null, so a deal never reached gets no first bucket rather than the top one
    select least(x.attempts, p_max) as bucket,
           case when x.first_reached_attempt is not null then least(x.first_reached_attempt, p_max) end as first_bucket, x.outcome
    from unnest(coalesce(p_rows, '{}')) x
  )
  select jsonb_agg(jsonb_build_object(
           'bucket', g.b,
           'label', case when g.b = p_max then g.b || '+' else g.b::text end,
           'deals', (select count(*) from r where r.bucket = g.b),
           'first_reached', (select count(*) from r where r.first_bucket = g.b),
           'won', (select count(*) from r where r.bucket = g.b and r.outcome = 'won'),
           'lost', (select count(*) from r where r.bucket = g.b and r.outcome = 'lost'))
         order by g.b)
  from generate_series(0, p_max) g(b)
$$;

-- Won against lost (Kira's comparison): of the decided deals, one row for won and one for lost with the deals, the
-- average and median attempts, the median speed to lead (over the attempted deals with business hours), called before
-- the next noon (of those whose answer is known), reached at least once, and the average talk time in contact of the
-- deals reached; beside them the deals not decided (open, ordered, unknown), each counted
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
                      'reached_deals', (select count(*) from r where r.outcome = o.outcome and r.reached_attempts > 0),
                      'avg_talk_reached_seconds', (select round(avg(r.talk_seconds_reached))::integer from r
                                                   where r.outcome = o.outcome and r.reached_attempts > 0))
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
               'attempts', s.attempts, 'reached_attempts', s.reached_attempts, 'first_reached_attempt', s.first_reached_attempt,
               'talk_seconds_total', s.talk_seconds_total, 'talk_seconds_reached', s.talk_seconds_reached,
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

-- The settings the pages' hints name, as their effective values
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
    'reached_min_talk_seconds', cma.setting_of(p_tenant_id, 'attempts.reached_min_talk_seconds')::integer,
    'speed_buckets', cma.setting_of(p_tenant_id, 'attempts.speed_buckets_business_minutes'))
$$;

-- Attempts per deal of an explicit tenant as of p_now, from one pass of cma.attempts_per_deal_of over the previous
-- span's first date to the period's last, as one JSON object:
--   current, previous   the figures of the period's deals and of the previous span's, like for like
--                       (cma.forms_previous_of), both narrowed by every filter
--   buckets             per attempt bucket 0 to attempts.max_bucket: deals, first reached there, won, lost
--   outcomes            won against lost, and the deals not decided
--   speed_buckets       the win rate by speed to lead (attempts.speed_buckets_business_minutes)
--   groups              the figures per p_group (day, week, market, pipeline)
--   since_last          the open deals by business days since the last attempt; no_hours apart
--   list                the deals (open first, the longest since the last attempt first; then decided, the newest
--                       end first), p_rows of them, with the total
--   markets, pipelines  the filter lists, from the period without the filters
--   history_start, settings
create or replace function cma.attempts_per_deal_page_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_market text,
                                                         p_pipeline text, p_attempted text, p_outcome text, p_rows integer,
                                                         p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone   text;
  v_prev   record;
  v_all    cma.attempt_deal[];
  v_cur    cma.attempt_deal[];
begin
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  select * into v_prev from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now);
  -- the one pass: the previous span's first date to the period's last
  v_all := cma.attempts_rows_of(p_tenant_id, least(v_prev.prev_from, p_from), p_to, p_now);
  v_cur := cma.attempts_in_period(v_all, p_from, p_to, p_market, p_pipeline, p_attempted, p_outcome, null, v_zone);
  return jsonb_build_object(
    'current', cma.attempts_figures_from(v_cur),
    'previous', cma.attempts_figures_from(cma.attempts_in_period(v_all, v_prev.prev_from, v_prev.prev_to, p_market, p_pipeline,
                                                                 p_attempted, p_outcome, v_prev.until, v_zone)),
    'buckets', cma.attempts_buckets_from(v_cur, cma.setting_of(p_tenant_id, 'attempts.max_bucket')::integer),
    'outcomes', cma.attempts_outcomes_from(v_cur),
    'speed_buckets', cma.attempts_speed_buckets_from(v_cur, cma.setting_of(p_tenant_id, 'attempts.speed_buckets_business_minutes')),
    'groups', cma.attempts_groups_from(v_cur, p_group),
    'since_last', cma.attempts_since_last_from(v_cur, cma.setting_of(p_tenant_id, 'attempts.since_last_buckets_business_days')),
    'list', cma.attempts_list_from(v_cur, p_rows),
    'history_start', cma.attempts_history_start_of(p_tenant_id),
    'settings', cma.attempts_settings_of(p_tenant_id))
    || cma.attempts_filter_lists_from(cma.attempts_in_period(v_all, p_from, p_to, null, null, 'all', 'all', null, v_zone));
end
$$;

-- Attempts per agent of an explicit tenant as of p_now, from one pass, as one JSON object: per deal owner by name,
-- never ranked, the figures of the deals they own (rows: user_id, display_name and the figures); the deals of an owner
-- id without a person, or without an owner, as one not-linked row with how many owner ids that is, never which (null
-- when none); the total; the filter lists, history_start and settings as the deal page gives them
create or replace function cma.attempts_per_person_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_pipeline text,
                                                      p_attempted text, p_outcome text, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone   text;
  v_all    cma.attempt_deal[];
  v_cur    cma.attempt_deal[];
begin
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  v_all := cma.attempts_rows_of(p_tenant_id, p_from, p_to, p_now);
  v_cur := cma.attempts_in_period(v_all, p_from, p_to, p_market, p_pipeline, p_attempted, p_outcome, null, v_zone);
  return jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', p.uid, 'display_name', p.uname) || p.f order by p.uname, p.uid)
      from (select u.id as uid, u.display_name as uname, cma.attempts_figures_from(array_agg(row(r.*)::cma.attempt_deal)) as f
            from unnest(v_cur) r
            join cma.app_user u on u.tenant_id = p_tenant_id and u.id = r.owner_user_id
            group by u.id, u.display_name) p), '[]'::jsonb),
    'not_linked', (
      select jsonb_build_object('unlinked_owners', count(distinct r.owner_ref)) || cma.attempts_figures_from(array_agg(row(r.*)::cma.attempt_deal))
      from unnest(v_cur) r
      left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = r.owner_user_id
      where u.id is null
      having count(*) > 0),
    'total', cma.attempts_figures_from(v_cur),
    'history_start', cma.attempts_history_start_of(p_tenant_id),
    'settings', cma.attempts_settings_of(p_tenant_id))
    || cma.attempts_filter_lists_from(v_all);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. The application's reads (permission checked, parameters checked, current tenant, row-level security)
-- ---------------------------------------------------------------------------------------------
-- The parameters both pages take: at most 92 days (CMA04); the filters
create or replace function cma.attempts_params_check(p_tenant_id uuid, p_from date, p_to date, p_market text, p_pipeline text,
                                                     p_attempted text, p_outcome text)
returns void
language plpgsql stable
as $$
begin
  perform cma.report_range(p_tenant_id, p_from, p_to);
  perform cma.attempts_filters_check(p_market, p_pipeline);
  perform cma.attempts_choices_check(p_attempted, p_outcome);
end
$$;

-- Reports, Attempts per deal in one read and one pass (reports.view or performance.team): as
-- cma.attempts_per_deal_page_of for the current tenant and now, the list capped by follow_up.list_rows (or p_rows,
-- held within 1 to 500); grouped by day, week, market or pipeline
create or replace function cma.attempts_per_deal_page(p_from date, p_to date, p_group text, p_market text, p_pipeline text,
                                                      p_attempted text default 'all', p_outcome text default 'all',
                                                      p_rows integer default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'week', 'market', 'pipeline') then
    raise exception 'group by day, week, market or pipeline, not %', coalesce(p_group, 'none') using errcode = 'CMA04';
  end if;
  perform cma.attempts_params_check(v_tenant, p_from, p_to, p_market, p_pipeline, p_attempted, p_outcome);
  return cma.attempts_per_deal_page_of(v_tenant, p_from, p_to, p_group, p_market, p_pipeline, p_attempted, p_outcome,
    least(500, greatest(1, coalesce(p_rows, cma.setting_of(v_tenant, 'follow_up.list_rows')::integer))), now());
end
$$;

-- Reports, Attempts per agent in one read and one pass: performance.team, and the tenant's reports.per_person holding
-- attempts (cma.assert_per_person; CMA06 otherwise); as cma.attempts_per_person_of for the current tenant and now
create or replace function cma.attempts_per_person_page(p_from date, p_to date, p_market text, p_pipeline text,
                                                        p_attempted text default 'all', p_outcome text default 'all')
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_per_person('attempts');
  perform cma.attempts_params_check(v_tenant, p_from, p_to, p_market, p_pipeline, p_attempted, p_outcome);
  return cma.attempts_per_person_of(v_tenant, p_from, p_to, p_market, p_pipeline, p_attempted, p_outcome, now());
end
$$;

-- One sales deal's attempts in time order, as the definition counts them now (reports.view or performance.team; the
-- current tenant only): n, the start, answered, talk time, reached and by what, the outcome's catalog label, and the
-- agent's name only while the tenant's reports.per_person holds attempts and the caller holds performance.team
-- (null otherwise). Never a call id, a number, a hash or a recording. CMA02 for a deal the tenant does not hold as
-- a sales deal (another tenant's, deleted, of another pipeline, before the intake start)
create or replace function cma.attempts_of_deal(p_deal_id uuid)
returns table (
  n              integer,
  started_at     timestamptz,
  answered       boolean,
  talk_seconds   integer,
  reached        boolean,
  reached_by     text,
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
    select z.n, z.effective_at, z.answered, z.talk_seconds, z.reached, z.reached_by, z.outcome_label,
           case when v_names then coalesce(
             (select u.display_name from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
              where x.tenant_id = v_tenant and x.system = z.telephony_source_system || '_user' and x.external_id = z.telephony_user_ref limit 1),
             (select u.display_name from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
              where x.tenant_id = v_tenant and x.system = z.owner_system || '_owner' and x.external_id = z.owner_ref limit 1)) end
    from cma.deal_attempts_of(v_tenant, v_deal.connection_id, v_deal.record_type, v_deal.source_id, v_deal.contacts,
                              v_deal.created_at - make_interval(mins => v_pre), v_deal.window_end,
                              cma.setting_of(v_tenant, 'attempts.source'),
                              cma.setting_of(v_tenant, 'attempts.reached_min_talk_seconds')::integer) z
    where z.is_attempt
    order by z.n;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Withdrawing a message (B)
-- ---------------------------------------------------------------------------------------------
alter table cma.message add column if not exists withdrawn_at timestamptz;
alter table cma.message add column if not exists withdrawn_by uuid;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'cma.message'::regclass and conname = 'message_withdrawn_check') then
    alter table cma.message add constraint message_withdrawn_check check ((withdrawn_at is null) = (withdrawn_by is null));
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.message'::regclass and conname = 'message_withdrawn_by_fkey') then
    alter table cma.message add constraint message_withdrawn_by_fkey
      foreign key (tenant_id, withdrawn_by) references cma.app_user (tenant_id, id);
  end if;
end
$$;
comment on table cma.message is 'Messages to CMA users: alerts raised by a rule and announcements sent by a person. References only, never customer data. Never deleted and never changed, except that it is withdrawn once (0008z)';
comment on column cma.message.withdrawn_at is 'When a person holding messages.withdraw withdrew the message for everyone (0008z): recipients no longer see it, a delivery not yet made never happens; null while it stands';
comment on column cma.message.withdrawn_by is 'The person who withdrew the message; set with withdrawn_at, never cleared';

-- A message changes in one way only: it is withdrawn once (withdrawn_at and withdrawn_by from null to a value)
create or replace function cma.check_message_change()
returns trigger
language plpgsql
as $$
begin
  if (to_jsonb(new) - 'withdrawn_at' - 'withdrawn_by') is distinct from (to_jsonb(old) - 'withdrawn_at' - 'withdrawn_by') then
    raise exception 'a message never changes; it can only be withdrawn' using errcode = 'CMA04';
  end if;
  if old.withdrawn_at is not null
     and (new.withdrawn_at is distinct from old.withdrawn_at or new.withdrawn_by is distinct from old.withdrawn_by) then
    raise exception 'message % was withdrawn already', old.id using errcode = 'CMA03';
  end if;
  return new;
end
$$;
revoke execute on function cma.check_message_change() from public;
create or replace trigger check_withdraw_once before update on cma.message
  for each row execute function cma.check_message_change();
grant update (withdrawn_at, withdrawn_by) on cma.message to cma_app;

insert into cma.permission (key, description) values
  ('messages.withdraw', 'Withdraw (delete) any message for everyone, manual or alert; recipients no longer see it')
on conflict (key) do update set description = excluded.description;

-- The default role ladder, as 0004 left it, plus messages.withdraw for the admin
create or replace function cma.seed_default_roles(p_tenant_id uuid)
returns void
language plpgsql
as $$
declare
  r record;
begin
  for r in
    select *
    from (values
      ('agent', 'Agent', array[
         'workday.own', 'roster.view', 'leads.accept', 'performance.own']),
      ('supervisor', 'Supervisor', array[
         'workday.own', 'roster.view', 'leads.accept', 'performance.own',
         'workday.team', 'performance.team', 'monitoring.live', 'messages.send']),
      ('manager', 'Call center manager', array[
         'workday.own', 'roster.view', 'leads.accept', 'performance.own',
         'workday.team', 'performance.team', 'monitoring.live', 'messages.send',
         'roster.manage', 'skills.manage', 'leads.manage', 'quality.manage',
         'reports.view', 'users.manage_agents', 'workday.export']),
      ('admin', 'Administrator', array[
         'workday.own', 'roster.view', 'leads.accept', 'performance.own',
         'workday.team', 'performance.team', 'monitoring.live', 'messages.send',
         'roster.manage', 'skills.manage', 'leads.manage', 'quality.manage',
         'reports.view', 'users.manage_agents', 'workday.export',
         'users.manage_all', 'tenant.configure', 'messages.withdraw']),
      ('analytics', 'Analytics', array[
         'reports.view', 'performance.team', 'monitoring.live', 'quality.manage'])
    ) as v(key, name, perms)
  loop
    insert into cma.app_role (tenant_id, key, name, is_system)
    values (p_tenant_id, r.key, r.name, true)
    on conflict (tenant_id, key) do nothing;

    insert into cma.role_permission (tenant_id, role_id, permission_key)
    select p_tenant_id, ar.id, p
    from cma.app_role ar
    cross join unnest(r.perms) as p
    where ar.tenant_id = p_tenant_id and ar.key = r.key
    on conflict do nothing;
  end loop;
end
$$;
revoke execute on function cma.seed_default_roles(uuid) from public;

-- Existing tenants: only the new permission, only on the default ladder's admin role (as 0003b did for the
-- manager's export). Other changes a tenant made to its own roles stay as they are
insert into cma.role_permission (tenant_id, role_id, permission_key)
select ar.tenant_id, ar.id, 'messages.withdraw'
from cma.app_role ar
where ar.key = 'admin' and ar.is_system
on conflict do nothing;

-- Withdraws a message of the current tenant for everyone (messages.withdraw), manual or alert: recipients no longer
-- see it (cma.my_messages, my_unread_count), a delivery not yet made never happens, the stats mark it, and the audit
-- keeps who and when. Answers when it was withdrawn; a second withdrawal changes nothing and answers the first time.
-- CMA02 for a message the tenant does not have
create or replace function cma.withdraw_message(p_message_id uuid)
returns timestamptz
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid;
  v_at     timestamptz;
begin
  v_user := cma.assert_permission('messages.withdraw');
  select m.withdrawn_at into v_at from cma.message m where m.tenant_id = v_tenant and m.id = p_message_id for update;
  if not found then
    raise exception 'no message %', p_message_id using errcode = 'CMA02';
  end if;
  if v_at is null then
    update cma.message m set withdrawn_at = now(), withdrawn_by = v_user
    where m.tenant_id = v_tenant and m.id = p_message_id
    returning m.withdrawn_at into v_at;
  end if;
  return v_at;
end
$$;

-- As 0008, leaving a withdrawn message out: the caller's messages, newest first, created after p_since when given, at
-- most p_limit (1 to 200), expired and withdrawn ones left out. The first return sets delivered_at; a later poll
-- leaves it, and a withdrawn message is never returned, so never delivered
create or replace function cma.my_messages(p_since timestamptz default null, p_limit integer default 50)
returns table (
  message_id       uuid,
  kind             text,
  urgency          text,
  title            text,
  body             text,
  ref_system       text,
  ref_type         text,
  ref_id           text,
  ref_url          text,
  created_at       timestamptz,
  expires_at       timestamptz,
  delivered_at     timestamptz,
  read_at          timestamptz,
  acknowledged_at  timestamptz
)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid;
  v_ids    uuid[];
begin
  v_user := cma.assert_acting_person();
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'limit is 1 to 200' using errcode = 'CMA04';
  end if;
  select coalesce(array_agg(x.id), '{}') into v_ids
  from (select m.id from cma.message_delivery d
        join cma.message m on m.tenant_id = d.tenant_id and m.id = d.message_id
        where d.tenant_id = v_tenant and d.user_id = v_user
          and (p_since is null or m.created_at > p_since)
          and (m.expires_at is null or m.expires_at > now())
          and m.withdrawn_at is null
        order by m.created_at desc, m.id desc
        limit p_limit) x;
  update cma.message_delivery d set delivered_at = now()
  where d.tenant_id = v_tenant and d.user_id = v_user and d.message_id = any (v_ids) and d.delivered_at is null;
  return query
    select m.id, m.kind, m.urgency, m.title, m.body, m.ref_system, m.ref_type, m.ref_id, m.ref_url, m.created_at, m.expires_at,
           d.delivered_at, d.read_at, d.acknowledged_at
    from cma.message_delivery d
    join cma.message m on m.tenant_id = d.tenant_id and m.id = d.message_id
    where d.tenant_id = v_tenant and d.user_id = v_user and d.message_id = any (v_ids)
    order by m.created_at desc, m.id desc;
end
$$;

create or replace function cma.my_unread_count()
returns integer
language plpgsql stable
as $$
declare
  v_user uuid;
begin
  v_user := cma.assert_acting_person();
  return (select count(*) from cma.message_delivery d
          join cma.message m on m.tenant_id = d.tenant_id and m.id = d.message_id
          where d.tenant_id = cma.current_tenant_id() and d.user_id = v_user and d.read_at is null
            and (m.expires_at is null or m.expires_at > now())
            and m.withdrawn_at is null)::integer;
end
$$;

-- As 0008: marks the caller's own deliveries read (and delivered, if the poll had not returned them yet); ids of other
-- people's deliveries, rows already read and withdrawn messages are left alone. Answers how many changed
create or replace function cma.mark_messages_read(p_message_ids uuid[])
returns integer
language plpgsql
as $$
declare
  v_user uuid;
  v_n    integer;
begin
  v_user := cma.assert_acting_person();
  if p_message_ids is null or cardinality(p_message_ids) > 500 then
    raise exception 'message ids must be an array of at most 500' using errcode = 'CMA04';
  end if;
  update cma.message_delivery d
     set delivered_at = coalesce(d.delivered_at, now()), read_at = now()
   where d.tenant_id = cma.current_tenant_id() and d.user_id = v_user and d.message_id = any (p_message_ids)
     and d.read_at is null
     and not exists (select 1 from cma.message m where m.tenant_id = d.tenant_id and m.id = d.message_id and m.withdrawn_at is not null);
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

-- As 0008: acknowledges one of the caller's own messages; acknowledging also reads it. A second acknowledgement changes
-- nothing. CMA02 when the caller has no delivery of that message, or it was withdrawn
create or replace function cma.acknowledge_message(p_message_id uuid)
returns void
language plpgsql
as $$
declare
  v_user uuid;
begin
  v_user := cma.assert_acting_person();
  if not exists (select 1 from cma.message_delivery d
                 join cma.message m on m.tenant_id = d.tenant_id and m.id = d.message_id
                 where d.tenant_id = cma.current_tenant_id() and d.user_id = v_user and d.message_id = p_message_id
                   and m.withdrawn_at is null) then
    raise exception 'no message % for you', p_message_id using errcode = 'CMA02';
  end if;
  update cma.message_delivery d
     set delivered_at = coalesce(d.delivered_at, now()), read_at = coalesce(d.read_at, now()), acknowledged_at = now()
   where d.tenant_id = cma.current_tenant_id() and d.user_id = v_user and d.message_id = p_message_id
     and d.acknowledged_at is null;
end
$$;

-- As 0008, plus when and by whom a message was withdrawn (null while it stands): its columns change, so it is made again
drop function if exists cma.message_stats(date, date);
create function cma.message_stats(p_from date, p_to date)
returns table (
  message_id              uuid,
  kind                    text,
  urgency                 text,
  title                   text,
  ref_system              text,
  ref_type                text,
  ref_id                  text,
  rule_id                 uuid,
  sender_user_id          uuid,
  created_at              timestamptz,
  recipients              integer,
  delivered               integer,
  read                    integer,
  acknowledged            integer,
  median_seconds_to_read  integer,
  withdrawn_at            timestamptz,
  withdrawn_by            uuid
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_zone   text;
begin
  perform cma.assert_any_permission(array['messages.send', 'performance.team']);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'a range of 1 to 92 days is needed' using errcode = 'CMA04';
  end if;
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;
  return query
    select m.id, m.kind, m.urgency, m.title, m.ref_system, m.ref_type, m.ref_id, m.rule_id, m.sender_user_id, m.created_at,
           count(d.user_id)::integer,
           count(d.delivered_at)::integer,
           count(d.read_at)::integer,
           count(d.acknowledged_at)::integer,
           round(percentile_cont(0.5) within group (order by extract(epoch from d.read_at - m.created_at)))::integer,
           m.withdrawn_at, m.withdrawn_by
    from cma.message m
    left join cma.message_delivery d on d.tenant_id = m.tenant_id and d.message_id = m.id
    where m.tenant_id = v_tenant
      and m.created_at >= (p_from::timestamp at time zone v_zone)
      and m.created_at < ((p_to + 1)::timestamp at time zone v_zone)
    group by m.id
    order by m.created_at, m.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.deal_calls_of(uuid,uuid,text,text,text[],timestamptz)',
    'cma.lead_calls_of(uuid,uuid,text,text,text[],timestamptz)',
    'cma.contact_store_orders_of(uuid)',
    'cma.lead_to_order_of(uuid,timestamptz,timestamptz)',
    'cma.sales_deals_of(uuid,timestamptz,timestamptz,timestamptz)',
    'cma.deal_attempts_of(uuid,uuid,text,text,text[],timestamptz,timestamptz,text,integer)',
    'cma.attempts_per_deal_of(uuid,timestamptz,timestamptz,timestamptz)',
    'cma.attempts_choices_check(text,text)',
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
    'cma.attempts_per_deal_page_of(uuid,date,date,text,text,text,text,text,integer,timestamptz)',
    'cma.attempts_per_person_of(uuid,date,date,text,text,text,text,timestamptz)',
    'cma.attempts_params_check(uuid,date,date,text,text,text,text)',
    'cma.attempts_per_deal_page(date,date,text,text,text,text,text,integer)',
    'cma.attempts_per_person_page(date,date,text,text,text,text)',
    'cma.attempts_of_deal(uuid)',
    'cma.withdraw_message(uuid)',
    'cma.my_messages(timestamptz,integer)',
    'cma.my_unread_count()',
    'cma.mark_messages_read(uuid[])',
    'cma.acknowledge_message(uuid)',
    'cma.message_stats(date,date)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 11. Reporting views
-- ---------------------------------------------------------------------------------------------
-- Every sales deal since each tenant's intake start, with its window, outcome and attempts as of now, for readers (so
-- Kira's team can set won against lost in BigQuery): over a SECURITY DEFINER function in cma_read (owned by cma_owner,
-- search path pinned, executable by readers only) that reads every tenant the reader sees; ids, codes, counts and times
-- only. The record link is the screens' (it needs the application's tenant). No attempt-level view
create or replace function cma_read.attempts_per_deal_rows()
returns table (tenant_id uuid, deal_id uuid, connection_id uuid, deal_source_id text, pipeline_id text, pipeline_label text,
               stage_id text, market text, owner_user_id uuid, created_at timestamptz, business_date date, is_closed boolean,
               closed_at timestamptz, ordered_at timestamptz, window_end_reason text, outcome text, attempts integer,
               reached_attempts integer, first_reached_attempt integer, talk_seconds_total integer, talk_seconds_reached integer,
               first_attempt_at timestamptz, speed_to_lead_seconds integer, called_before_next_noon boolean,
               last_attempt_at timestamptz, business_days_since_last integer, since_last_bucket text,
               attempts_without_outcome integer, logged_without_aircall integer)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label, r.stage_id, r.market, r.owner_user_id,
         r.created_at, r.business_date, r.is_closed, r.closed_at, r.ordered_at, r.window_end_reason, r.outcome, r.attempts,
         r.reached_attempts, r.first_reached_attempt, r.talk_seconds_total, r.talk_seconds_reached, r.first_attempt_at,
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

-- The message view with the withdrawal last (title and body hold references only, as 0008)
create or replace view cma_read.message as
  select id, tenant_id, kind, urgency, title, body, ref_system, ref_type, ref_id, ref_url, rule_id, target,
         sender_user_id, created_at, expires_at, withdrawn_at, withdrawn_by
  from cma.message
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 12. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008z', 'Attempts per deal for sales and message withdrawal: the settings attempts.source, attempts.reached_min_talk_seconds and attempts.speed_buckets_business_minutes; the calls of a deal and the store orders of a contact written once (cma.deal_calls_of under cma.lead_calls_of, cma.contact_store_orders_of under cma.lead_to_order_of); the sales deals with their window to the close or the first order (cma.sales_deals_of); the attempts of a deal with reached by the outcome or the talk time (cma.deal_attempts_of); the definition rebuilt without the scope, the page reads with won against lost, the win rate by speed to lead and the attempted and outcome filters, one deal''s attempts; the reader view''s new columns; messages withdrawn once (withdrawn_at, withdrawn_by), the permission messages.withdraw on the default admin role, cma.withdraw_message, the reads leaving a withdrawn message out, the stats marking it')
on conflict (version) do nothing;

commit;
reset role;
