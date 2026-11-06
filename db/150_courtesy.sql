-- =============================================================================================
-- 150_courtesy.sql: addition 0009a, Customers → Courtesy (a courtesy call per store order)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 148_installed_base_list.sql (0008zz). Rerunnable, forward-only, additive, in one transaction with a lock timeout. Run as
-- your own IAM login, away from minute 20 (the hourly snapshot job): dev first, then 151_verify_courtesy.sql there, then
-- 81_verify_follow_up_snapshot.sql (dev; its B2 and B11 leave the two courtesy keys out of their comparison since this
-- change, the edit of this PR) and 73_verify_follow_up.sql again; then prod, then seed 02 is not needed: Pulse4all's
-- courtesy.start_date is set by hand (Configuration → Exports or Studio), on purpose not in the seed.
-- The web of main runs unchanged on it: cma.follow_up_summary() gains two columns at the end, which main's web does not
-- read (it maps named columns); nothing else main reads changes. The web of this change reads cma.courtesy_page and the
-- two new columns, so in prod this script runs before that web is merged.
--
-- Why (Martin, 6 November 2026; Decision log): every First or Repeat store order gets a courtesy call from day 10 after it.
-- The CMA counts it from the facts it already mirrors, one fact one source: the store's orders (commerce, 0007b), the
-- order's customer linked to its CRM contact (0008h), the contact's calls through the call link as Attempts per deal
-- attributes them (0008z: the CRM call associated with the contact, its current link, the linked telephony call on a
-- counted line), Attempt and Conversation (0008zc), and the tag meanings courtesy_completed_positive, _neutral and
-- _negative (decided 25 October 2026). HubSpot's courtesy properties are not a source (a repeat order overwrites them);
-- legacy call outcomes do not count (they end before any tenant's start date can sensibly begin).
--
-- Definitions (docs/definitions.md, Courtesy terms):
--   courtesy order    a store order, not a test, not deleted, not cancelled, of an order kind in courtesy.order_kinds,
--                     whose business date (its creation in its market's zone) is on or after courtesy.start_date. Its
--                     market is its store's; its zone the market's (the store's, then the tenant's, when the catalog
--                     lacks one). Its contact is the CRM contact its store customer is linked to; without one it counts
--                     as No contact only and has no state
--   due date          the business date + courtesy.due_days calendar days; due from that date's start in the zone
--   completed call    a call (either direction, counted line, not deleted) on the contact, at or after the order's
--                     creation, carrying a current tag whose meaning is courtesy_completed_positive, _neutral or _negative.
--                     The order's completion is the first such call (its outcome the call's meaning; a call carrying two
--                     completed meanings takes the tag set last); so one completed call completes every courtesy order of
--                     the contact created at or before it and not completed yet
--   attempt           an Attempt on the contact from the start of the due date up to and including the completion
--   conversation      one of those attempts is a Conversation (the column is never named reached, a call word retired in 0008zc)
--   state, as of now  not_due (before the due date, not completed), due_no_attempt, attempted (attempts below
--                     courtesy.alert_attempts, or at least that many with a Conversation), not_reached (at least
--                     courtesy.alert_attempts attempts, none a Conversation: the flag), completed (outcome positive,
--                     neutral or negative); null for No contact
--   order cohort      the courtesy orders of one ISO week or month of their business date, at each age of
--                     courtesy.ages_days (as Cohort age: created_at + n days) the share completed by then
--
-- What it adds
--   settings          courtesy.start_date (empty: not set up, the page says so and shows no count), courtesy.order_kinds
--                     (first,repeat), courtesy.due_days (10; 1 to 60), courtesy.alert_attempts (3; 1 to 20),
--                     courtesy.ages_days (10,14,21,30; one to six increasing, each at most 90); cma.check_tenant_setting()
--                     as 0008zt's with the five
--   reads             cma.courtesy_orders_of(tenant, from, to, now): one row per courtesy order created in [from, to)
--                     (business dates; from and to given: at most 92 days, cma.report_range; null: since the start
--                     date, up to now), row type cma.courtesy_order_row; cma.courtesy_not_reached_of(tenant, now)
--   page              cma.courtesy_page(from, to, period, group, market, segment, state, rows) (reports.view or
--                     performance.team, CMA06): the page in one read (below)
--   follow-up         cma.refresh_follow_up_of keeps courtesy_not_reached and courtesy_alert_attempts in the snapshot's
--                     summary; cma.follow_up_summary() returns them (two columns at the end: dropped and created)
--   readers           cma_read.courtesy_order over cma_read.courtesy_order_rows(): one row per courtesy order of every
--                     tenant the reader sees, without the contact (as cma_read.commerce_customer leaves the link out)
-- No table, and no column of a table: the figures are computed when read; cma.follow_up_snapshot's summary is jsonb.
--
-- Everything is SECURITY INVOKER and executable by the application only; the cma_read function is SECURITY DEFINER, owned
-- by cma_owner, search path pinned, executable by readers only.
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
set local lock_timeout = '5s';
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008zz') then
    raise exception 'addition 0008zz (148_installed_base_list.sql) must run before 0009a';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('courtesy.start_date', 'text', null, '',
     'The first business date whose store orders get a courtesy call, as YYYY-MM-DD; empty: courtesy is not set up and Customers → Courtesy shows no count'),
  ('courtesy.order_kinds', 'text', null, 'first,repeat',
     'The order kinds that get a courtesy call: one to three of first, repeat and renewal, comma-separated'),
  ('courtesy.due_days', 'integer', null, '10',
     'The calendar days after an order''s business date on which its courtesy call falls due, 1 to 60'),
  ('courtesy.alert_attempts', 'integer', null, '3',
     'The attempts after which a courtesy order without a conversation is flagged Not reached, 1 to 20'),
  ('courtesy.ages_days', 'text', null, '10,14,21,30',
     'The ages in days at which Customers → Courtesy follows each order cohort: one to six increasing whole numbers, each at most 90')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0008zt (136), with the five courtesy settings
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
  if new.key in ('email.start_date', 'reviews.history_start_date', 'courtesy.start_date') then
    new.value := btrim(new.value);
  end if;
  if new.key in ('leads.age_buckets_business_days', 'attempts.since_last_buckets_business_days', 'attempts.speed_buckets_business_minutes',
                 'cohorts.lead_ages_days', 'flash.active_subscription_statuses', 'flash.ended_subscription_statuses', 'assets.required_refs',
                 'commerce.required_contact_refs', 'flash.device_holding_statuses', 'courtesy.order_kinds', 'courtesy.ages_days') then
    new.value := regexp_replace(new.value, '[[:space:]]+', '', 'g');
  end if;
  if s.value_type = 'boolean' and new.value not in ('true', 'false') then
    raise exception 'Setting % takes true or false', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'integer' and new.value !~ '^-?[0-9]+$' then
    raise exception 'Setting % takes a whole number', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'date' or (new.key in ('email.start_date', 'reviews.history_start_date', 'courtesy.start_date') and new.value <> '') then
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
  -- reviews (0008ze): the highest rating that is a negative review, a whole star from 1 to 4
  elsif new.key = 'reviews.negative_max_rating'
        and (case when length(new.value) > 1 then true else new.value::integer not between 1 and 4 end) then
    raise exception 'Setting % takes a whole number of stars from 1 to 4', new.key using errcode = 'CMA04';
  -- assets (0008zi): the bundling window, a whole number of days from 0 to 365
  elsif new.key = 'assets.bundle_window_days'
        and (case when length(new.value) > 3 then true else new.value::integer not between 0 and 365 end) then
    raise exception 'Setting % takes a whole number of days from 0 to 365', new.key using errcode = 'CMA04';
  -- lead cohorts (0008zm): one to six increasing ages in days, the largest at most lead_to_order.max_days (an order counts
  -- up to that many days after the deal's creation), against the other setting's effective value; and lead_to_order.max_days
  -- no lower than the largest age, so the two never disagree through a change of either (a reset to a default is a delete
  -- no trigger sees: the report shows an age above lead_to_order.max_days without its ordered figure)
  elsif new.key = 'cohorts.lead_ages_days' then
    if not cma.is_bucket_list(new.value, 6) then
      raise exception 'Setting % takes one to six increasing whole numbers of days, comma-separated, such as 1,7,30,60,90', new.key
        using errcode = 'CMA04';
    end if;
    if (select max(x::integer) from unnest(string_to_array(new.value, ',')) x)
       > cma.setting_of(new.tenant_id, 'lead_to_order.max_days')::numeric then
      raise exception 'Setting % takes ages of at most lead_to_order.max_days (%)', new.key, cma.setting_of(new.tenant_id, 'lead_to_order.max_days')
        using errcode = 'CMA04';
    end if;
  elsif new.key = 'lead_to_order.max_days'
        and new.value::numeric < (select max(x::integer) from unnest(string_to_array(cma.setting_of(new.tenant_id, 'cohorts.lead_ages_days'), ',')) x) then
    raise exception 'Setting % takes at least the largest age of cohorts.lead_ages_days (%)', new.key, cma.setting_of(new.tenant_id, 'cohorts.lead_ages_days')
      using errcode = 'CMA04';
  -- Flash (0008zn)
  -- the active and the ended statuses: paused never (its own measure), and never one status in both lists, against the
  -- other setting's effective value
  -- and (0008zt) the device-holding statuses, none of them ended either, against the other setting's effective value
  elsif new.key in ('flash.active_subscription_statuses', 'flash.ended_subscription_statuses', 'flash.device_holding_statuses') then
    if not cma.flash_list_ok(new.value, '^(active|canceled|expired|failed|merged|never-subscribed)$', 6, false) then
      raise exception 'Setting % takes one to six of active, canceled, expired, failed, merged and never-subscribed (never paused), each once, comma-separated without spaces', new.key
        using errcode = 'CMA04';
    end if;
    if new.key <> 'flash.device_holding_statuses'
       and cma.flash_list_of(new.value) && cma.flash_list_of(cma.setting_of(new.tenant_id,
         case new.key when 'flash.active_subscription_statuses' then 'flash.ended_subscription_statuses' else 'flash.active_subscription_statuses' end)) then
      raise exception 'Setting % takes no status of %', new.key,
        case new.key when 'flash.active_subscription_statuses' then 'flash.ended_subscription_statuses' else 'flash.active_subscription_statuses' end
        using errcode = 'CMA04';
    end if;
    if new.key <> 'flash.active_subscription_statuses'
       and cma.flash_list_of(new.value) && cma.flash_list_of(cma.setting_of(new.tenant_id,
         case new.key when 'flash.device_holding_statuses' then 'flash.ended_subscription_statuses' else 'flash.device_holding_statuses' end)) then
      raise exception 'Setting % takes no status of %', new.key,
        case new.key when 'flash.device_holding_statuses' then 'flash.ended_subscription_statuses' else 'flash.device_holding_statuses' end
        using errcode = 'CMA04';
    end if;
  elsif new.key = 'flash.snapshot_local_time' and new.value = '24:00' then
    raise exception 'Setting % takes a time from 00:00 to 23:59', new.key using errcode = 'CMA04';
  elsif new.key = 'flash.id_list_retention_months'
        and (case when length(new.value) > 3 then true else new.value::integer not between 1 and 240 end) then
    raise exception 'Setting % takes a whole number of months from 1 to 240', new.key using errcode = 'CMA04';
  elsif new.key = 'flash.watch_jump_pct'
        and (case when length(new.value) > 4 then true else new.value::integer not between 1 and 1000 end) then
    raise exception 'Setting % takes a share in percent from 1 to 1000', new.key using errcode = 'CMA04';
  elsif new.key = 'flash.watch_jump_min'
        and (case when length(new.value) > 7 then true else new.value::integer not between 0 and 1000000 end) then
    raise exception 'Setting % takes a whole number from 0 to 1000000', new.key using errcode = 'CMA04';
  elsif new.key = 'flash.file_max_rows'
        and (case when length(new.value) > 5 then true else new.value::integer not between 1 and 50000 end) then
    raise exception 'Setting % takes a whole number of rows from 1 to 50000', new.key using errcode = 'CMA04';
  elsif new.key = 'assets.required_refs' and not cma.flash_list_ok(new.value, '^[a-z][a-z0-9_]{0,39}$', 20, true) then
    raise exception 'Setting % takes names of a device''s named ids (lower case letters, digits and _), each once, comma-separated without spaces, or nothing', new.key
      using errcode = 'CMA04';
  elsif new.key = 'commerce.required_contact_refs' and not cma.flash_list_ok(new.value, '^[a-z0-9_]{1,40}$', 9, true) then
    raise exception 'Setting % takes contact reference systems (lower case letters, digits and _), each once, comma-separated without spaces, or nothing', new.key
      using errcode = 'CMA04';
  -- the watch's floor of a cadence measured from runs (0008zo)
  elsif new.key = 'flash.watch_stale_min_minutes'
        and (case when length(new.value) > 4 then true else new.value::integer not between 1 and 1440 end) then
    raise exception 'Setting % takes a whole number of minutes from 1 to 1440', new.key using errcode = 'CMA04';
  -- Flash's bands and the customer segments (0008zt): never stripped of spaces, so a space is refused, not mended
  elsif new.key = 'flash.device_bands' and not cma.is_bucket_list(new.value, 6) then
    raise exception 'Setting % takes one to six strictly increasing whole numbers of devices from 1, comma-separated without spaces, such as 1,2,3', new.key
      using errcode = 'CMA04';
  elsif new.key = 'flash.subscription_age_months' and not cma.is_bucket_list(new.value, 10) then
    raise exception 'Setting % takes one to ten strictly increasing whole numbers of months from 1, comma-separated without spaces, such as 12,24,36,48,60', new.key
      using errcode = 'CMA04';
  elsif new.key = 'crm.customer_segments'
        and not (new.value = ''
                 or (new.value ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,39}(,[A-Za-z0-9][A-Za-z0-9_-]{0,39}){0,19}$'
                     and (select count(*) = count(distinct lower(x)) from unnest(string_to_array(new.value, ',')) x))) then
    raise exception 'Setting % takes up to twenty values of a contact''s segment property (letters, digits, _ and -, at most 40 each), each once whatever its case, comma-separated without spaces, such as B2B,B2C, or nothing', new.key
      using errcode = 'CMA04';
  -- the statuses' meanings (0008zt): stored in jsonb's own form
  elsif new.key = 'subscription.status_meanings' then
    if not cma.flash_status_meanings_ok(new.value) then
      raise exception 'Setting % takes a JSON object of subscription statuses (active, paused, canceled, expired, failed, merged, never-subscribed), each an object of en and nl texts of 1 to 200 characters without an @, such as {"active": {"en": "...", "nl": "..."}}, or {}', new.key
        using errcode = 'CMA04';
    end if;
    new.value := (new.value::jsonb)::text;
  -- courtesy (0009a): the order kinds that get a courtesy call, the day it falls due, the attempts after which an order
  -- without a conversation is flagged Not reached, and the ages of the order cohorts (each at most 90 days)
  elsif new.key = 'courtesy.order_kinds' and not cma.flash_list_ok(new.value, '^(first|repeat|renewal)$', 3, false) then
    raise exception 'Setting % takes one to three of first, repeat and renewal, each once, comma-separated without spaces, such as first,repeat', new.key
      using errcode = 'CMA04';
  elsif new.key = 'courtesy.due_days'
        and (case when length(new.value) > 2 then true else new.value::integer not between 1 and 60 end) then
    raise exception 'Setting % takes a whole number of days from 1 to 60', new.key using errcode = 'CMA04';
  elsif new.key = 'courtesy.alert_attempts'
        and (case when length(new.value) > 2 then true else new.value::integer not between 1 and 20 end) then
    raise exception 'Setting % takes a whole number of attempts from 1 to 20', new.key using errcode = 'CMA04';
  elsif new.key = 'courtesy.ages_days'
        and (case when not cma.is_bucket_list(new.value, 6) then true
                 else (select max(x::integer) from unnest(string_to_array(new.value, ',')) x) > 90 end) then
    raise exception 'Setting % takes one to six increasing whole numbers of days, each at most 90, comma-separated, such as 10,14,21,30', new.key
      using errcode = 'CMA04';
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The settings as values, and the meanings, written once
-- ---------------------------------------------------------------------------------------------
-- The tenant's start date, null while courtesy.start_date is empty (not set up)
create or replace function cma.courtesy_start_of(p_tenant_id uuid)
returns date
language sql stable
as $$
  select nullif(btrim(cma.setting_of(p_tenant_id, 'courtesy.start_date')), '')::date
$$;

-- The order kinds that get a courtesy call
create or replace function cma.courtesy_kinds_of(p_tenant_id uuid)
returns text[]
language sql stable
as $$
  select cma.flash_list_of(cma.setting_of(p_tenant_id, 'courtesy.order_kinds'))
$$;

-- The ages of the order cohorts, in order
create or replace function cma.courtesy_ages_of(p_tenant_id uuid)
returns integer[]
language sql stable
as $$
  select coalesce(array_agg(u.x::integer order by u.o), '{}')
  from unnest(cma.flash_list_of(cma.setting_of(p_tenant_id, 'courtesy.ages_days'))) with ordinality as u(x, o)
$$;

-- A tag meaning as a courtesy outcome: positive, neutral or negative for the three completed meanings, null for any other.
-- The only place that names them for courtesy; an immutable expression the planner inlines
create or replace function cma.courtesy_outcome_of(p_meaning text)
returns text
language sql immutable
as $$
  select case p_meaning when 'courtesy_completed_positive' then 'positive'
                        when 'courtesy_completed_neutral' then 'neutral'
                        when 'courtesy_completed_negative' then 'negative' end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The courtesy orders
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if to_regtype('cma.courtesy_order_row') is null then
    create type cma.courtesy_order_row as (
      order_id            uuid,
      connection_id       uuid,
      order_source_id     text,
      order_name          text,
      store               text,
      store_name          text,
      market              text,
      zone                text,
      segment             text,
      created_at          timestamptz,
      business_date       date,
      due_date            date,
      due_at              timestamptz,
      has_contact         boolean,
      crm_connection_id   uuid,
      contact_source_id   text,
      attempts            integer,
      conversation        boolean,
      last_attempt_at     timestamptz,
      completed_at        timestamptz,
      completed_date      date,
      completed_time      time,
      completed_call_id   uuid,
      outcome             text,
      completed_by        uuid,
      state               text
    );
  end if;
end
$$;
comment on type cma.courtesy_order_row is
  'One courtesy order as of an instant (0009a): the order, its store, market, zone and segment, its business and due dates, its contact (ids only), its courtesy attempts, whether one was a Conversation, its completion (call, outcome, the person of the call''s user) and its state; docs/definitions.md, Courtesy terms';

-- The courtesy orders of a tenant created on the business dates [p_from, p_to) (each in its market's zone), as of p_now.
-- p_from and p_to given: at most 92 days (cma.report_range); null: from courtesy.start_date, up to any date. None while
-- courtesy.start_date is empty. Calls are attributed to the contact as Attempts per deal attributes them (cma.deal_calls_of:
-- a CRM call of the contact's connection, not deleted, currently associated with the contact, its current call link, the
-- linked telephony call not deleted, with a start, on a counted line), up to p_now. Ids, codes, counts and times only
create or replace function cma.courtesy_orders_of(p_tenant_id uuid, p_from date, p_to date, p_now timestamptz default now())
returns setof cma.courtesy_order_row
language plpgsql stable
rows 500   -- a tenant's courtesy orders of a period (CLAUDE.md, Performance: a set-returning function says its rows)
as $$
declare
  v_start     date := cma.courtesy_start_of(p_tenant_id);
  v_kinds     text[] := cma.courtesy_kinds_of(p_tenant_id);
  v_due       integer := cma.setting_of(p_tenant_id, 'courtesy.due_days')::integer;
  v_alert     integer := cma.setting_of(p_tenant_id, 'courtesy.alert_attempts')::integer;
  v_connected integer := coalesce(cma.setting_of(p_tenant_id, 'telephony.connected_min_seconds')::integer, 0);
  v_conv      integer := coalesce(cma.setting_of(p_tenant_id, 'calls.conversation_min_talk_seconds')::integer, 0);
  v_segments  text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments'));
  v_lower     text[];
  v_zone      text;
  v_from      date;
begin
  if v_start is null then
    return;
  end if;
  if p_from is not null and p_to is not null then
    perform cma.report_range(p_tenant_id, p_from, p_to - 1);
  end if;
  v_from := greatest(v_start, coalesce(p_from, v_start));
  if p_to is not null and p_to <= v_from then
    return;
  end if;
  select array_agg(lower(x) order by o) into v_lower from unnest(v_segments) with ordinality u(x, o);
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  return query
    with ord as materialized (
      -- the orders by their creation instant, a day wider than any zone each side, then by their business date in their
      -- market's zone; with the store customer's contact
      select co.id, co.connection_id, co.source_id, coalesce(co.order_name, co.source_id) as order_name, co.source_created_at,
             coalesce(st.handle, 'unknown') as store, st.name as store_name, coalesce(st.market, 'unknown') as market, z.zone, d.bdate,
             d.bdate + v_due as due_date, ((d.bdate + v_due)::timestamp at time zone z.zone) as due_at,
             cu.crm_connection_id, cu.crm_contact_source_id
      from cma.commerce_order co
      left join cma.commerce_store st on st.tenant_id = co.tenant_id and st.connection_id = co.connection_id
      left join cma.market mk on mk.tenant_id = co.tenant_id and mk.code = st.market
      cross join lateral (select coalesce(mk.time_zone, st.time_zone, v_zone) as zone) z
      cross join lateral (select (co.source_created_at at time zone z.zone)::date as bdate) d
      left join cma.commerce_customer cu
        on cu.tenant_id = co.tenant_id and cu.connection_id = co.connection_id and cu.source_id = co.customer_source_id
       and cu.source_deleted_at is null
      where co.tenant_id = p_tenant_id
        and co.source_created_at >= (v_from::timestamp at time zone 'UTC') - interval '1 day'
        and (p_to is null or co.source_created_at < (p_to::timestamp at time zone 'UTC') + interval '1 day')
        and not co.is_test and co.source_deleted_at is null and co.cancelled_at is null
        and co.order_kind = any (v_kinds)
        and d.bdate >= v_from and (p_to is null or d.bdate < p_to)
    ), k as materialized (
      select distinct ord.crm_connection_id as conn, ord.crm_contact_source_id as contact
      from ord where ord.crm_contact_source_id is not null
    ), c as materialized (
      -- the contacts' calls from the first possible creation up to p_now, each with whether it is an Attempt, a Conversation
      -- and the courtesy outcome of its current tags. Read per contact (the lateral read is kept apart by offset 0), so
      -- each contact's calls come from crm_association_to_idx, never from a scan of every call since the start date
      select k.conn, k.contact, x.*
      from k
      cross join lateral (
        select tc.id as call_id, tc.source_system as tel_system, tc.user_ref, tc.direction, tc.started_at,
               cma.is_conversation(tc.direction, tc.answered_at is not null, tc.talk_seconds, v_connected, v_conv,
                                   (select nr.not_reached from cma.call_not_reached_of(p_tenant_id, tc.connection_id, tc.source_id) nr)) as conversation,
               (select cma.courtesy_outcome_of(tg.meaning)
                from cma.telephony_call_tag ct
                join cma.telephony_tag tg on tg.tenant_id = ct.tenant_id and tg.connection_id = ct.connection_id and tg.tag_ref = ct.tag_ref
                where ct.tenant_id = p_tenant_id and ct.connection_id = tc.connection_id and ct.call_source_id = tc.source_id
                  and ct.untagged_at is null and cma.courtesy_outcome_of(tg.meaning) is not null
                order by ct.tagged_at desc, tg.meaning
                limit 1) as outcome
        from cma.crm_association a
        join cma.crm_call cc
          on cc.tenant_id = p_tenant_id and cc.connection_id = a.connection_id and cc.source_id = a.from_id and cc.source_deleted_at is null
        join cma.call_link l on l.tenant_id = p_tenant_id and l.crm_call_id = cc.id and l.unlinked_at is null
        join cma.telephony_call tc on tc.tenant_id = p_tenant_id and tc.id = l.telephony_call_id and tc.source_deleted_at is null
        left join cma.telephony_number n on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
        where a.tenant_id = p_tenant_id and a.connection_id = k.conn and a.to_type = 'contact' and a.to_id = k.contact
          and a.from_type = 'crm_call' and a.removed_at is null
          and tc.started_at is not null and tc.started_at <= p_now
          and tc.started_at >= (v_from::timestamp at time zone 'UTC') - interval '1 day'
          and tc.direction in ('inbound', 'outbound') and coalesce(n.is_counted, true)
        offset 0
      ) x
    ), j as materialized (
      select ord.id as order_id, ord.source_created_at, ord.due_at, c.*
      from ord join c on c.conn = ord.crm_connection_id and c.contact = ord.crm_contact_source_id
    ), done as (
      -- the completion: the contact's first call with a completed meaning at or after the order's creation
      select distinct on (j.order_id) j.order_id, j.call_id, j.started_at, j.outcome, j.tel_system, j.user_ref
      from j
      where j.outcome is not null and j.started_at >= j.source_created_at
      order by j.order_id, j.started_at, j.call_id
    ), att as (
      -- the courtesy attempts: outbound, from the start of the due date up to and including the completion
      select j.order_id, count(*)::integer as attempts, bool_or(j.conversation) as conversation, max(j.started_at) as last_at
      from j
      left join done d on d.order_id = j.order_id
      where j.direction = 'outbound' and j.started_at >= j.due_at and j.started_at <= coalesce(d.started_at, p_now)
      group by j.order_id
    )
    select ord.id, ord.connection_id, ord.source_id, ord.order_name, ord.store, ord.store_name, ord.market, ord.zone,
           case when ord.crm_contact_source_id is null then 'unknown'
                else cma.flash_segment_of(kc.segment, v_segments, v_lower) end,
           ord.source_created_at, ord.bdate, ord.due_date, ord.due_at,
           ord.crm_contact_source_id is not null, ord.crm_connection_id, ord.crm_contact_source_id,
           case when ord.crm_contact_source_id is not null then coalesce(att.attempts, 0) end,
           case when ord.crm_contact_source_id is not null then coalesce(att.conversation, false) end,
           att.last_at,
           d.started_at, (d.started_at at time zone ord.zone)::date, (d.started_at at time zone ord.zone)::time, d.call_id, d.outcome,
           case when d.call_id is not null then
             (select x.user_id from cma.app_user_external_id x
              where x.tenant_id = p_tenant_id and x.system = d.tel_system || '_user' and x.external_id = d.user_ref) end,
           case when ord.crm_contact_source_id is null then null
                when d.call_id is not null then 'completed'
                when p_now < ord.due_at then 'not_due'
                when coalesce(att.attempts, 0) = 0 then 'due_no_attempt'
                when att.attempts >= v_alert and not att.conversation then 'not_reached'
                else 'attempted' end
    from ord
    left join done d on d.order_id = ord.id
    left join att on att.order_id = ord.id
    left join cma.crm_contact kc
      on kc.tenant_id = p_tenant_id and kc.connection_id = ord.crm_connection_id and kc.source_id = ord.crm_contact_source_id
    order by ord.source_created_at, ord.id;
end
$$;
-- JIT off as the other large reads (132); custom plans always: after five calls on a connection a plpgsql statement turns to
-- its generic plan (CLAUDE.md, Performance), which at three times prod's volume took the page from 1.2 to 1.7 s
alter function cma.courtesy_orders_of(uuid, date, date, timestamptz) set jit = off;
alter function cma.courtesy_orders_of(uuid, date, date, timestamptz) set plan_cache_mode = force_custom_plan;

-- The courtesy orders Not reached as of p_now, over every courtesy order since courtesy.start_date; null while it is empty.
-- The follow-up snapshot keeps it, so Welcome's Needs attention reads it without a read of its own
create or replace function cma.courtesy_not_reached_of(p_tenant_id uuid, p_now timestamptz)
returns integer
language sql stable
as $$
  select case when cma.courtesy_start_of(p_tenant_id) is not null
              then (select count(*)::integer from cma.courtesy_orders_of(p_tenant_id, null, null, p_now) x where x.state = 'not_reached') end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Customers → Courtesy in one read
-- ---------------------------------------------------------------------------------------------
-- The state filter's values: every state, due (the three states of an order due without completion) and no_contact
create or replace function cma.courtesy_state_matches(p_state text, p_filter text)
returns boolean
language sql immutable
as $$
  select case when p_filter is null then true
              when p_filter = 'no_contact' then p_state is null
              when p_filter = 'due' then p_state in ('due_no_attempt', 'attempted', 'not_reached')
              else p_state = p_filter end
$$;

-- The page of an explicit tenant as of p_now, as one JSON object. Two kinds of figure:
--   now     every courtesy order since courtesy.start_date as of p_now, narrowed by market and segment: the orders due
--           without completion, Not reached, No contact and the states (the tiles), and the order list (also by state,
--           the first p_rows with the filtered total; Not reached first, then due without an attempt, attempted, not due,
--           no contact, completed; then by due date)
--   period  the courtesy orders created on the period's business dates [p_from, p_to] and the completions in it: the
--           completed courtesy calls of the period by their completion date (distinct calls, per outcome) and the previous
--           period like for like (cma.forms_previous_of, the last day cut at p_now's time of day in the order's zone); per
--           market and per day, ISO week or month (p_group) the orders with a contact, completed, Not reached and No
--           contact; the order cohorts per ISO week or month (p_period) at the ages of courtesy.ages_days; per person (only
--           with p_per_person) the completed courtesy calls of the period by the person of the completing call's user,
--           by name, the calls without one last
-- Not set up (courtesy.start_date empty): set_up false and every figure null
create or replace function cma.courtesy_page_of(p_tenant_id uuid, p_from date, p_to date, p_period text, p_group text, p_market text,
                                                p_segment text, p_state text, p_rows integer, p_per_person boolean, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_start    date := cma.courtesy_start_of(p_tenant_id);
  v_ages     integer[] := cma.courtesy_ages_of(p_tenant_id);
  v_prev     record;
  v_head     jsonb;
begin
  v_head := jsonb_build_object(
    'from', p_from, 'to', p_to, 'period', p_period, 'group', p_group, 'market', p_market, 'segment', p_segment, 'state', p_state,
    'rows', p_rows, 'set_up', v_start is not null, 'start_date', v_start,
    'has_store', exists (select 1 from cma.commerce_store s where s.tenant_id = p_tenant_id),
    'settings', jsonb_build_object(
      'due_days', cma.setting_of(p_tenant_id, 'courtesy.due_days')::integer,
      'alert_attempts', cma.setting_of(p_tenant_id, 'courtesy.alert_attempts')::integer,
      'ages', to_jsonb(v_ages), 'order_kinds', to_jsonb(cma.courtesy_kinds_of(p_tenant_id))),
    'filter_segments', to_jsonb(cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments')) || array['unknown']));
  if v_start is null then
    return v_head || jsonb_build_object('now', null, 'completed', null, 'previous', null, 'previous_from', null, 'previous_to', null,
      'previous_partial', false, 'markets', '[]'::jsonb, 'groups', '[]'::jsonb, 'cohorts', '[]'::jsonb, 'per_person', null,
      'list', jsonb_build_object('total', 0, 'rows', '[]'::jsonb), 'filter_markets', '[]'::jsonb);
  end if;
  select * into v_prev from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now);
  return v_head || (
    with a as materialized (
      -- every courtesy order since the start date (the now figures), with its period's flags; the columns the page reads
      select x.order_id, x.order_name, x.store, x.store_name, x.market, x.segment, x.zone, x.created_at, x.business_date, x.due_date,
             x.has_contact, x.crm_connection_id, x.contact_source_id, x.attempts, x.last_attempt_at, x.completed_at,
             x.completed_call_id, x.outcome, x.completed_by, x.state,
             x.business_date between p_from and p_to as created_in,
             x.completed_call_id is not null and cma.in_period(x.completed_date, x.completed_time, p_from, p_to, null) as done_in,
             x.completed_call_id is not null
               and cma.in_period(x.completed_date, x.completed_time, v_prev.prev_from, v_prev.prev_to,
                                 case when v_prev.until is not null then (v_prev.until at time zone x.zone)::time end) as done_prev,
             case p_group when 'day' then x.business_date when 'month' then date_trunc('month', x.business_date)::date
                  else date_trunc('week', x.business_date)::date end as group_key,
             case p_period when 'month' then date_trunc('month', x.business_date)::date
                  else date_trunc('week', x.business_date)::date end as cohort_key
      from cma.courtesy_orders_of(p_tenant_id, null, null, p_now) x
    ), f as materialized (
      select * from a
      where (p_market is null or a.market = p_market) and (p_segment is null or a.segment = p_segment)
    ), p as materialized (
      select * from f where f.created_in
    ), l as materialized (
      -- the list's order on the narrow keys alone (the rows' details are joined for the first p_rows only)
      select f.order_id, row_number() over (order by case f.state when 'not_reached' then 1 when 'due_no_attempt' then 2 when 'attempted' then 3
                                                                  when 'not_due' then 4 when 'completed' then 6 else 5 end,
                                                     f.due_date, f.created_at, f.order_id) as n
      from f where cma.courtesy_state_matches(f.state, p_state)
    )
    select jsonb_build_object(
      'now', (select jsonb_build_object(
                'orders', count(*) filter (where f.has_contact),
                'due_open', count(*) filter (where f.state in ('due_no_attempt', 'attempted', 'not_reached')),
                'not_due', count(*) filter (where f.state = 'not_due'),
                'due_no_attempt', count(*) filter (where f.state = 'due_no_attempt'),
                'attempted', count(*) filter (where f.state = 'attempted'),
                'not_reached', count(*) filter (where f.state = 'not_reached'),
                'completed', count(*) filter (where f.state = 'completed'),
                'no_contact', count(*) filter (where not f.has_contact)) from f),
      'completed', (select jsonb_build_object(
                      'calls', count(distinct f.completed_call_id) filter (where f.done_in),
                      'positive', count(distinct f.completed_call_id) filter (where f.done_in and f.outcome = 'positive'),
                      'neutral', count(distinct f.completed_call_id) filter (where f.done_in and f.outcome = 'neutral'),
                      'negative', count(distinct f.completed_call_id) filter (where f.done_in and f.outcome = 'negative')) from f),
      'previous', (select jsonb_build_object(
                     'calls', count(distinct f.completed_call_id) filter (where f.done_prev),
                     'positive', count(distinct f.completed_call_id) filter (where f.done_prev and f.outcome = 'positive'),
                     'neutral', count(distinct f.completed_call_id) filter (where f.done_prev and f.outcome = 'neutral'),
                     'negative', count(distinct f.completed_call_id) filter (where f.done_prev and f.outcome = 'negative')) from f),
      'previous_from', v_prev.prev_from, 'previous_to', v_prev.prev_to, 'previous_partial', v_prev.until is not null,
      'markets', (select coalesce(jsonb_agg(jsonb_build_object('market', m.market, 'name', mk.name, 'orders', m.orders, 'completed', m.completed,
                                                               'not_reached', m.not_reached, 'no_contact', m.no_contact)
                                            order by (m.market = 'unknown'), mk.sort_order, m.market), '[]'::jsonb)
                  from (select p.market, count(*) filter (where p.has_contact) as orders, count(*) filter (where p.state = 'completed') as completed,
                               count(*) filter (where p.state = 'not_reached') as not_reached, count(*) filter (where not p.has_contact) as no_contact
                        from p group by p.market) m
                  left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = m.market),
      'groups', (select jsonb_agg(jsonb_build_object('key', g.key, 'orders', coalesce(t.orders, 0), 'completed', coalesce(t.completed, 0),
                                                     'not_reached', coalesce(t.not_reached, 0), 'no_contact', coalesce(t.no_contact, 0),
                                                     'markets', coalesce(t.markets, '[]'::jsonb))
                                  order by g.key)
                 from (select k::date as key
                       from generate_series(case p_group when 'day' then p_from when 'month' then date_trunc('month', p_from)::date
                                                 else date_trunc('week', p_from)::date end, p_to,
                                            case p_group when 'day' then interval '1 day' when 'month' then interval '1 month'
                                                 else interval '7 days' end) k) g
                 left join (select gm.group_key, sum(gm.orders) as orders, sum(gm.completed) as completed, sum(gm.not_reached) as not_reached,
                                   sum(gm.no_contact) as no_contact,
                                   jsonb_agg(jsonb_build_object('market', gm.market, 'orders', gm.orders, 'completed', gm.completed,
                                                                'not_reached', gm.not_reached, 'no_contact', gm.no_contact)
                                             order by (gm.market = 'unknown'), gm.sort_order, gm.market) as markets
                            from (select p.group_key, p.market, coalesce(mk.sort_order, 2147483647) as sort_order,
                                         count(*) filter (where p.has_contact) as orders, count(*) filter (where p.state = 'completed') as completed,
                                         count(*) filter (where p.state = 'not_reached') as not_reached, count(*) filter (where not p.has_contact) as no_contact
                                  from p
                                  left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = p.market
                                  group by p.group_key, p.market, mk.sort_order) gm
                            group by gm.group_key) t on t.group_key = g.key),
      'cohorts', (select coalesce(jsonb_agg(jsonb_build_object(
                                   'key', c.k, 'label', case when p_period = 'month' then to_char(c.k, 'YYYY-MM') else to_char(c.k, 'IYYY-"W"IW') end,
                                   'start', c.k, 'end', e.last_day, 'partial', c.k < p_from or e.last_day > p_to, 'orders', c.orders,
                                   'ages', (select coalesce(jsonb_agg(jsonb_build_object('age', ag.age, 'mature', m.mature,
                                                                                         'completed', case when m.mature then m.completed end)
                                                                      order by ag.o), '[]'::jsonb)
                                            from unnest(v_ages) with ordinality as ag(age, o)
                                            cross join lateral (
                                              select count(*) > 0 and bool_and(q.created_at + make_interval(days => ag.age) <= p_now) as mature,
                                                     count(*) filter (where q.completed_at <= q.created_at + make_interval(days => ag.age)) as completed
                                              from p q where q.has_contact and q.cohort_key = c.k) m))
                                 order by c.k desc), '[]'::jsonb)
                  from (select p.cohort_key as k, count(*) as orders from p where p.has_contact group by p.cohort_key) c
                  cross join lateral (
                    select case when p_period = 'month' then (c.k + interval '1 month' - interval '1 day')::date else c.k + 6 end as last_day) e),
      'per_person', case when p_per_person then
                      (select coalesce(jsonb_agg(jsonb_build_object('user_id', pp.uid, 'name', u.display_name, 'calls', pp.calls,
                                                                    'positive', pp.positive, 'neutral', pp.neutral, 'negative', pp.negative)
                                                 order by (pp.uid is null), u.display_name, pp.uid), '[]'::jsonb)
                       from (select f.completed_by as uid, count(distinct f.completed_call_id) as calls,
                                    count(distinct f.completed_call_id) filter (where f.outcome = 'positive') as positive,
                                    count(distinct f.completed_call_id) filter (where f.outcome = 'neutral') as neutral,
                                    count(distinct f.completed_call_id) filter (where f.outcome = 'negative') as negative
                             from f where f.done_in group by f.completed_by) pp
                       left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = pp.uid) end,
      'list', jsonb_build_object(
                'total', (select count(*) from l),
                'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                                   'order_id', r.order_id, 'order_name', r.order_name, 'store', r.store,
                                   'store_name', r.store_name, 'market', r.market, 'segment', r.segment, 'created_at', r.created_at,
                                   'business_date', r.business_date, 'due_date', r.due_date,
                                   'days_past_due', case when r.state in ('due_no_attempt', 'attempted', 'not_reached')
                                                         then (p_now at time zone r.zone)::date - r.due_date end,
                                   'attempts', r.attempts, 'last_attempt_at', r.last_attempt_at, 'state', r.state, 'outcome', r.outcome,
                                   'completed_at', r.completed_at,
                                   'record_url', case when r.has_contact then cma.record_url(r.crm_connection_id, 'contact', r.contact_source_id) end)
                                 order by l.n), '[]'::jsonb)
                         from l join f r on r.order_id = l.order_id where l.n <= p_rows)),
      'filter_markets', (select coalesce(jsonb_agg(fm.market order by (fm.market = 'unknown'), fm.sort_order, fm.market), '[]'::jsonb)
                         from (select distinct a.market, coalesce(mk.sort_order, 2147483647) as sort_order
                               from a left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = a.market) fm))
  );
end
$$;
alter function cma.courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz) set jit = off;
alter function cma.courtesy_page_of(uuid, date, date, text, text, text, text, text, integer, boolean, timestamptz) set plan_cache_mode = force_custom_plan;

-- Customers → Courtesy in one read (reports.view or performance.team, CMA06; a period of at most 92 days, cma.report_range).
-- p_period week or month (the order cohorts), p_group day, week or month (per market and period), p_market a market's code
-- or unknown, p_segment a segment code or unknown, p_state one of not_due, due_no_attempt, attempted, not_reached,
-- completed, due or no_contact; anything else CMA04. p_rows defaults to follow_up.list_rows and is held within 1 to 500.
-- Per person only for performance.team (null otherwise)
create or replace function cma.courtesy_page(p_from date, p_to date, p_period text default 'week', p_group text default 'week',
                                             p_market text default null, p_segment text default null, p_state text default null,
                                             p_rows integer default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid;
begin
  v_user := cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  if p_period is null or p_period not in ('week', 'month') then
    raise exception 'period is week or month, not %', coalesce(p_period, 'none') using errcode = 'CMA04';
  end if;
  if p_group is null or p_group not in ('day', 'week', 'month') then
    raise exception 'group by day, week or month, not %', coalesce(p_group, 'none') using errcode = 'CMA04';
  end if;
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'a market filter is a two-letter code or unknown' using errcode = 'CMA04';
  end if;
  if p_segment is not null and p_segment !~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$' then
    raise exception 'a segment filter is a segment''s code or unknown' using errcode = 'CMA04';
  end if;
  if p_state is not null and p_state not in ('not_due', 'due_no_attempt', 'attempted', 'not_reached', 'completed', 'due', 'no_contact') then
    raise exception 'a state filter is not_due, due_no_attempt, attempted, not_reached, completed, due or no_contact' using errcode = 'CMA04';
  end if;
  return cma.courtesy_page_of(v_tenant, p_from, p_to, p_period, p_group, p_market, p_segment, p_state,
                              least(500, greatest(1, coalesce(p_rows, cma.setting_of(v_tenant, 'follow_up.list_rows')::integer))),
                              cma.has_permission(v_user, 'performance.team'), now());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The follow-up snapshot keeps the courtesy flag (0008s)
-- ---------------------------------------------------------------------------------------------
-- As 0008s (80), with courtesy_not_reached and courtesy_alert_attempts in the summary (null while courtesy is not set up)
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
  v_courtesy integer;
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
  -- the courtesy flag (0009a): the courtesy orders Not reached now and the attempts that flag one, both null while
  -- courtesy.start_date is unset, so Welcome's Needs attention reads them with the summary
  v_courtesy := cma.courtesy_not_reached_of(p_tenant_id, now());
  v_summary := v_summary || jsonb_build_object(
    'courtesy_not_reached', v_courtesy,
    'courtesy_alert_attempts', case when v_courtesy is not null then cma.setting_of(p_tenant_id, 'courtesy.alert_attempts')::integer end);
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

-- The counts, when they were computed, and (0009a) the courtesy orders Not reached with the attempts that flag one: two new
-- columns at the end, so the function is dropped and created again
drop function if exists cma.follow_up_summary();
create function cma.follow_up_summary()
returns table(tenant_id uuid, leads_open_not_called integer, leads_past_target integer, tickets_at_risk integer, tickets_breached integer,
              tickets_without_owner integer, tasks_overdue integer, tasks_due_today integer, tasks_unmapped_owner integer, computed_at timestamptz,
              courtesy_not_reached integer, courtesy_alert_attempts integer)
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
                      (s.summary ->> 'tasks_due_today')::integer, (s.summary ->> 'tasks_unmapped_owner')::integer, s.computed_at,
                      (s.summary ->> 'courtesy_not_reached')::integer, (s.summary ->> 'courtesy_alert_attempts')::integer;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Reporting view
-- ---------------------------------------------------------------------------------------------
-- Every courtesy order since each tenant's start date as of now, for readers: ids, codes, dates, times and counts only,
-- never the contact (as cma_read.commerce_customer leaves the link out). Over a SECURITY DEFINER function in cma_read (owned
-- by cma_owner, search path pinned, executable by readers only) that reads every tenant the reader sees, as
-- cma_read.lead_cohort_rows
create or replace function cma_read.courtesy_order_rows()
returns table (tenant_id uuid, order_id uuid, connection_id uuid, order_source_id text, store text, market text, segment text,
               created_at timestamptz, business_date date, due_date date, has_contact boolean, attempts integer, conversation boolean,
               last_attempt_at timestamptz, completed_at timestamptz, outcome text, completed_by uuid, state text)
language sql stable security definer
rows 1000   -- every tenant's courtesy orders since its start date (CLAUDE.md, Performance: a set-returning function says its rows)
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, r.order_id, r.connection_id, r.order_source_id, r.store, r.market, r.segment, r.created_at, r.business_date, r.due_date,
         r.has_contact, r.attempts, r.conversation, r.last_attempt_at, r.completed_at, r.outcome, r.completed_by, r.state
  from cma.tenant t
  cross join lateral cma.courtesy_orders_of(t.id, null, null, now()) r
  where cma_read.reader_sees(t.id)
$$;
revoke execute on function cma_read.courtesy_order_rows() from public;
grant execute on function cma_read.courtesy_order_rows() to cma_readonly;

create or replace view cma_read.courtesy_order as
  select * from cma_read.courtesy_order_rows();
comment on view cma_read.courtesy_order is
  'One row per courtesy order since each tenant''s courtesy.start_date, as of now (0009a): the order, store, market, segment, business and due dates, whether it has a contact (never which), its courtesy attempts, whether one was a Conversation, its completion, outcome, the completing person and its state';

-- ---------------------------------------------------------------------------------------------
-- 7. Grants: the application only (a function made again keeps its grants)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.courtesy_start_of(uuid)', 'cma.courtesy_kinds_of(uuid)', 'cma.courtesy_ages_of(uuid)', 'cma.courtesy_outcome_of(text)',
    'cma.courtesy_orders_of(uuid,date,date,timestamptz)', 'cma.courtesy_not_reached_of(uuid,timestamptz)',
    'cma.courtesy_state_matches(text,text)',
    'cma.courtesy_page_of(uuid,date,date,text,text,text,text,text,integer,boolean,timestamptz)',
    'cma.courtesy_page(date,date,text,text,text,text,text,integer)',
    'cma.refresh_follow_up_of(uuid,boolean)', 'cma.follow_up_summary()'
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
values ('0009a', 'Customers → Courtesy: the settings courtesy.start_date (empty: not set up), courtesy.order_kinds (first,repeat), courtesy.due_days (10), courtesy.alert_attempts (3) and courtesy.ages_days (10,14,21,30), checked by cma.check_tenant_setting(); cma.courtesy_orders_of (per courtesy order: store, market, segment, due date, the courtesy attempts on its contact from the due date, whether one was a Conversation, the first completed call at or after it with its outcome and person, the state as of now; calls attributed as Attempts per deal''s, the completed tag meanings decided on 25 October 2026); cma.courtesy_page (tiles, per market and period, order cohorts, per person for performance.team, the order list with the contact''s record link); the follow-up snapshot keeps the courtesy orders Not reached and cma.follow_up_summary() returns them; cma_read.courtesy_order without the contact')
on conflict (version) do nothing;

commit;
reset role;
