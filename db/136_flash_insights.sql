-- =============================================================================================
-- 136_flash_insights.sql: addition 0008zt, Flash: device reconciliation, devices per subscription, subscription age,
-- customer segment (brief B29, with its amendment of 5 November 2026: device-holding statuses and status meanings)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: the bands, the segments and the property a segment comes from are
-- tenant settings and connection configuration (Pulse4all's values are seed 02's), statuses are the subscription app's
-- own words and a device's flags the tenant's catalog. Runs unchanged in every database, after 134_hours_reads.sql
-- (0008zs). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login, away from minute
-- 20 (the hourly snapshot job): dev first, then 137_verify_flash_insights.sql there, then 123_verify_flash.sql again
-- (its expected figures follow 0008zt since this change), then 02_seed_pulse4all.sql again (the segment mapping and
-- crm.customer_segments of Pulse4all Subscriptions); then prod, with 137, 123 and 02. The web and the ingest of main run
-- unchanged on it (they read no new column, and a contact item without a segment stores none); the web and the ingest
-- of this change need it: in prod the script runs before either is deployed.
--
-- Why (brief B29, 5 November 2026): four questions Reports → Flash could not answer. Does the asset register agree with
-- the subscription app (which devices in the field sit on a subscription that holds devices, on another status, on a
-- subscription the app does not know, or on none)? How many devices does a subscription carry? How old are the active
-- subscriptions? Which segment are the active customers in? The amendment (Bas, Martin, 5 November 2026): a subscription
-- holds devices in more statuses than the paying ones (Pulse4all: active and failed), so the device figures follow their
-- own statuses, a device on a subscription that holds none is a finding, and each status's meaning for the business line
-- is configuration the hints show. Ids, counts, statuses and codes only; no personal data.
--
-- What it adds
--   settings           flash.device_bands (1,2,3), flash.subscription_age_months (12,24,36,48,60), crm.customer_segments
--                      (empty: no segments), flash.device_holding_statuses (active; one to six statuses, never paused, none
--                      of flash.ended_subscription_statuses, which in turn takes none of them), subscription.status_meanings
--                      ({}: per status an en and nl text, checked by cma.flash_status_meanings_ok, stored as jsonb writes
--                      it); cma.check_tenant_setting() as 0008zo's with their checks (the bands strictly increasing whole
--                      numbers from 1, at most six and ten; up to twenty codes, each once whatever its case, or nothing;
--                      none of these three stripped of spaces, so a space is refused); flash.active_subscription_statuses
--                      stays the paying ones (active customers, active subscriptions)
--   contact segment    cma.connection_field takes the field segment for the entity contact (one slot); cma.crm_contact.segment
--                      (at most 100 characters, no @, no control character), written by cma.ingest_upsert_contacts from the
--                      item's segment as given, trimmed (empty, too long or holding an @: none); a deleted or forgotten
--                      contact holds none (the upsert's deletion clears it, and a trigger clears it on any row marked
--                      deleted, cma.ingest_contact_forget's among them); cma_read.crm_contact is unchanged (its columns
--                      are pinned by 69 and 85; the readers get the segment with a later change if they need it)
--   bands              cma.flash_bounds_of, cma.flash_count_band_of, cma.flash_count_bands_of, cma.flash_age_months_of,
--                      cma.flash_age_band_of, cma.flash_age_bands_of, cma.flash_ratio_of, cma.flash_segment_of: immutable,
--                      inlined by the base sets
--   installed base     dim subscription_status (the linked subscription's status, else not_found, else none; a grouping set
--                      [market, subscription_status] with every measure); measure in_field_on_holding (devices in the field
--                      on a subscription whose status is one of flash.device_holding_statuses), a count the watch reads
--   subscriptions      measures holding_subscriptions (a status of flash.device_holding_statuses), devices_on_holding (their
--                      devices in the field), both counts the watch reads, and devices_per_holding_subscription
--                      (devices_on_holding / holding_subscriptions, 2 decimals, left out of a row without a holding
--                      subscription: a ratio, outside count_measures, so the watch's jump never reads it; an exchange makes
--                      a subscription hold one device more for a while, and no check flags that); dims device_band (a
--                      holding subscription's devices in the field in the bands of flash.device_bands: 0, each value, the
--                      last open-ended, a value followed by a gap a range such as 1-2), a grouping set [market,
--                      device_band] with holding_subscriptions, devices_on_holding and the ratio, and age_band (an active
--                      subscription's age in whole months from its creation in the subscription app up to the business
--                      date: <12, 12-24, ..., 60+, unknown without a creation time), a grouping set [market, age_band] with
--                      active_subscriptions; every band of the settings with its row per market (zeros included); the
--                      list's column devices_in_field (its devices column unchanged)
--   customers          dim segment (the linked contact's segment when crm.customer_segments holds it, matched whatever its
--                      case and named in the setting's spelling, else unknown), a grouping set [market, segment]
--   one code path      cma.flash_overviews(), cma.flash_definition_version() (0008zt for customers, subscriptions and
--                      installed_base), the base sets cma.flash_store_customers_of (new: with the segment; 0008zn's
--                      cma.flash_customers_of reads it with its own columns), cma.flash_subscriptions_of(tenant, date)
--                      (new: with the business date, the devices in the field and the bands; 0008zn's one-argument form
--                      reads it as of today with its own columns) and cma.flash_devices_of (its columns unchanged; the
--                      subscription status not_found or none where it was empty), cma.flash_compute_of, cma.flash_rows_of, cma.flash_document_of (the three
--                      settings: now's, or the snapshot run's) and cma.flash_snapshot_take_at (the run records them): live
--                      and the snapshot stay one computation
--   data quality       active_subscription_without_device reads the device-holding statuses (its key kept);
--                      field_device_on_non_holding_subscription (370): a device in the field on a subscription whose status
--                      neither holds devices nor is ended (Pulse4all: paused, merged, never-subscribed), fixed in the asset
--                      register, with its reader view; field_device_on_ended_subscription unchanged, so no device is listed
--                      twice. cma.data_quality_flash_checks, cma.data_quality_of, cma.data_quality (0008zr's) and
--                      cma.data_quality_fix_in made again; the stored results take them at the next refresh
--   hints              cma.flash_status_settings_of: the active, holding and ended statuses and the meanings, returned by
--                      cma.flash_page (settings, new) and by cma.flash_overview's document (settings) for the hints
-- What it does not change
--   the snapshots already stored (a snapshot keeps its definition_version, 0008zn, and holds none of the new figures);
--   the watch (its jump reads count_measures, the new counts among them, and leaves a measure the day before lacked
--   uncompared); the month end's id lists; no change to the HubSpot app's scopes or webhook subscriptions: a linked
--   contact's segment stays fresh through the sweep's second read and the nightly reconcile (docs/ingest/README.md)
--
-- Everything is SECURITY INVOKER and executable by the application only, as 0008zn's; the take's writer
-- cma.flash_snapshot_take_at stays the owner's alone. No function changes its columns in place: the customers' and the
-- subscriptions' base sets with their new columns have signatures of their own that 0008zn's read, so 122, 125 and this
-- script can each run again in their order. cma.crm_contact gains its column and checks inside the transaction, so its writers wait for
-- the commit (well under a second). SQLSTATEs as before: CMA04 invalid.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zs') then
    raise exception 'addition 0008zs (134_hours_reads.sql) must run before 0008zt';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('flash.device_bands', 'text', null, '1,2,3',
     'The bands of an active subscription''s devices in the field on Reports → Flash (Active subscriptions): one to six strictly increasing whole numbers from 1, comma-separated without spaces. The bands are 0, each value and the last one open-ended (1,2,3: 0, 1, 2, 3+); a value followed by a gap is a range (1,3: 0, 1-2, 3+)'),
  ('flash.subscription_age_months', 'text', null, '12,24,36,48,60',
     'The bands of an active subscription''s age in whole months since its creation in the subscription app, up to the business date, on Reports → Flash (Active subscriptions): one to ten strictly increasing whole numbers from 1, comma-separated without spaces (12,24: <12, 12-24, 24+; unknown without a creation time)'),
  ('flash.device_holding_statuses', 'text', null, 'active',
     'The subscription statuses whose subscription holds devices in the field, on Reports → Flash (the installed base''s in_field_on_holding, the active subscriptions'' holding_subscriptions, devices_on_holding, their ratio and device bands) and in data quality: one to six of active, canceled, expired, failed, merged and never-subscribed (never paused: a paused subscription holds no device), none of flash.ended_subscription_statuses, comma-separated without spaces. flash.active_subscription_statuses stays the paying ones'),
  ('subscription.status_meanings', 'text', null, '{}',
     'What each subscription status means for this business line, shown in Reports → Flash''s hints beside the status in the subscription app''s words: a JSON object of statuses (active, paused, canceled, expired, failed, merged, never-subscribed), each an object of en and nl texts of 1 to 200 characters without an @, such as {"active": {"en": "...", "nl": "..."}}. Empty ({}): the statuses alone'),
  ('crm.customer_segments', 'text', null, '',
     'The values of a contact''s segment property (connection_field segment) that count as customer segments on Reports → Flash (Active customers): up to twenty codes of letters, digits, _ and -, each once whatever its case, comma-separated without spaces; any other value, an empty one and no linked contact are unknown. Empty: no segments, every customer unknown')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0008zo (125_flash_watch_cadence.sql), with the settings of 0008zt: the device bands (one to six strictly increasing
-- whole numbers from 1), the subscription ages in months (one to ten) and the customer segments (up to twenty codes, each
-- once whatever its case, or nothing), none of the three stripped of spaces (a space is refused); the device-holding
-- statuses, checked as their two siblings (spaces removed, paused never) and never one of the ended ones, which in turn
-- take none of them; the statuses' meanings (cma.flash_status_meanings_ok), stored in jsonb's own form

-- The device-holding statuses (flash.device_holding_statuses, 0008zt)
create or replace function cma.flash_holding_statuses_of(p_tenant_id uuid)
returns text[]
language sql stable
as $$
  select cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.device_holding_statuses'))
$$;

-- subscription.status_meanings' form (0008zt): a JSON object whose keys are subscription statuses, each an object of at
-- least one of en and nl, each a text of 1 to 200 characters (not blank) without an @ or a control character
create or replace function cma.flash_status_meanings_ok(p_value text)
returns boolean
language plpgsql immutable
as $$
declare
  j jsonb;
begin
  begin
    j := p_value::jsonb;
  exception when others then
    return false;
  end;
  return j is not null and jsonb_typeof(j) = 'object'
     and not exists (select 1 from jsonb_each(j) e
                     where e.key not in ('active', 'paused', 'canceled', 'expired', 'failed', 'merged', 'never-subscribed')
                        or jsonb_typeof(e.value) <> 'object'
                        or not exists (select 1 from jsonb_object_keys(e.value))
                        or exists (select 1 from jsonb_each(e.value) l
                                   where l.key not in ('en', 'nl') or jsonb_typeof(l.value) <> 'string'
                                      or length(l.value #>> '{}') > 200 or btrim(l.value #>> '{}') = ''
                                      or (l.value #>> '{}') ~ '[@[:cntrl:]]'));
end
$$;

-- The statuses a Flash figure counts and what each means, for the hints (the landing and every overview): the active,
-- the device-holding and the ended statuses, and subscription.status_meanings (0008zt)
create or replace function cma.flash_status_settings_of(p_tenant_id uuid)
returns jsonb
language sql stable
as $$
  select jsonb_build_object('active_subscription_statuses', to_jsonb(cma.flash_active_statuses_of(p_tenant_id)),
                            'device_holding_statuses', to_jsonb(cma.flash_holding_statuses_of(p_tenant_id)),
                            'ended_subscription_statuses', to_jsonb(cma.flash_ended_statuses_of(p_tenant_id)),
                            'status_meanings', coalesce(nullif(cma.setting_of(p_tenant_id, 'subscription.status_meanings'), '')::jsonb, '{}'::jsonb))
$$;

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
  if new.key in ('email.start_date', 'reviews.history_start_date') then
    new.value := btrim(new.value);
  end if;
  if new.key in ('leads.age_buckets_business_days', 'attempts.since_last_buckets_business_days', 'attempts.speed_buckets_business_minutes',
                 'cohorts.lead_ages_days', 'flash.active_subscription_statuses', 'flash.ended_subscription_statuses', 'assets.required_refs',
                 'commerce.required_contact_refs', 'flash.device_holding_statuses') then
    new.value := regexp_replace(new.value, '[[:space:]]+', '', 'g');
  end if;
  if s.value_type = 'boolean' and new.value not in ('true', 'false') then
    raise exception 'Setting % takes true or false', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'integer' and new.value !~ '^-?[0-9]+$' then
    raise exception 'Setting % takes a whole number', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'date' or (new.key in ('email.start_date', 'reviews.history_start_date') and new.value <> '') then
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
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The contact's segment
-- ---------------------------------------------------------------------------------------------
-- As 0008zj (114), with the field segment for a contact (slot 1 only: connection_field_slot_check unchanged)
alter table cma.connection_field drop constraint if exists connection_field_field_check;
alter table cma.connection_field add constraint connection_field_field_check
  check (field = any (array['market', 'language', 'country', 'currency', 'store', 'amount', 'source_channel', 'category', 'ref', 'created_at',
                            'reason', 'serial', 'model', 'status', 'warehouse_ref', 'customer_ref', 'subscription_ref', 'order_ref',
                            'first_shipped_on', 'stock_received_on', 'last_shipped_on', 'warranty_until', 'end_of_life_on', 'expires_on',
                            'segment']));
alter table cma.connection_field drop constraint if exists connection_field_entity_field_check;
alter table cma.connection_field add constraint connection_field_entity_field_check
  check (case when entity = 'contact' then field = any (array['country', 'language', 'currency', 'store', 'ref', 'created_at', 'segment'])
              when entity = 'device' then field = any (array['serial', 'model', 'status', 'country', 'warehouse_ref', 'customer_ref',
                                                             'subscription_ref', 'order_ref', 'first_shipped_on', 'stock_received_on',
                                                             'last_shipped_on', 'warranty_until', 'end_of_life_on', 'ref'])
              when entity = 'device_component' then field = any (array['serial', 'expires_on'])
              when field = 'reason' then entity in ('deal', 'ticket')
              else field = any (array['market', 'language', 'currency', 'amount', 'source_channel', 'category']) end);

-- The contact's segment as the CRM states it (a code such as B2B): at most 100 characters, no @ and no control character
-- (the upsert stores none rather than such a value), none on a contact marked deleted (the upsert's deletion and the
-- privacy deletion's forget alike: the trigger below clears it on any row marked deleted). New and empty, so the checks are
-- validated at once
alter table cma.crm_contact add column if not exists segment text;
comment on column cma.crm_contact.segment is
  'The value of the connection''s mapped segment property (connection_field segment), trimmed, as the CRM states it (0008zt): a code such as B2B, never free text with an @; null when unmapped, empty or deleted. Reports → Flash counts it as a segment only when crm.customer_segments holds it';
alter table cma.crm_contact drop constraint if exists crm_contact_segment_check;
alter table cma.crm_contact add constraint crm_contact_segment_check
  check (length(segment) between 1 and 100 and segment !~ '[@[:cntrl:]]') not valid;
alter table cma.crm_contact validate constraint crm_contact_segment_check;
alter table cma.crm_contact drop constraint if exists crm_contact_segment_deleted_check;
alter table cma.crm_contact add constraint crm_contact_segment_deleted_check
  check (source_deleted_at is null or segment is null) not valid;
alter table cma.crm_contact validate constraint crm_contact_segment_deleted_check;

-- A contact marked deleted loses its segment, whoever marks it (the upsert's deletion, cma.ingest_contact_forget): a
-- trigger function, it runs whoever writes the row, so nobody gets execute on it
create or replace function cma.crm_contact_clear_segment()
returns trigger
language plpgsql
as $$
begin
  new.segment := null;
  return new;
end
$$;
revoke execute on function cma.crm_contact_clear_segment() from public;
create or replace trigger clear_segment before insert or update on cma.crm_contact
  for each row when (new.source_deleted_at is not null and new.segment is not null) execute function cma.crm_contact_clear_segment();

-- As 0008zn (122), with the segment: the item's segment as given, trimmed, stored on the contact (none when empty, over
-- 100 characters or holding an @ or a control character), cleared with the contact's deletion like its country
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
  v_segment  text;
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
                       where tk.tenant_id = v_tenant and tk.connection_id = p_connection_id and tk.contact_source_id = v_src)
       and not exists (select 1 from cma.commerce_customer cu
                       where cu.tenant_id = v_tenant and cu.crm_connection_id = p_connection_id and cu.crm_contact_source_id = v_src) then
      return query select v_src, 'not_held'::text;
      continue;
    end if;

    if v_deleted is not null then
      if v_old.id is null then
        return query select v_src, 'not_held'::text;
      else
        update cma.crm_contact cc
           set country = null, country_source = null, language = null, currency = null, store = null, segment = null, raw = '{}'::jsonb,
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
    -- the segment (0008zt): the mapped property's value as given, trimmed; none when empty, and none for a value no
    -- segment can be (over 100 characters, an @ or a control character), so no address ever lands in it
    v_segment := nullif(btrim(c ->> 'segment'), '');
    if length(v_segment) > 100 or v_segment ~ '[@[:cntrl:]]' then
      v_segment := null;
    end if;
    if v_old.id is null then
      insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, country_source, language, currency,
                                   store, segment, source_updated_at, source_created_at, raw)
      values (v_tenant, p_connection_id, v_system, v_src, v_country, v_csource, nullif(btrim(c ->> 'language'), ''),
              cma.json_currency(c ->> 'currency'), v_store, v_segment, v_updated, v_created, coalesce(c -> 'raw', '{}'::jsonb))
      returning id into v_id;
    else
      v_id := v_old.id;
      update cma.crm_contact cc
         set country = v_country, country_source = v_csource, language = nullif(btrim(c ->> 'language'), ''),
             currency = cma.json_currency(c ->> 'currency'), store = v_store, segment = v_segment,
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
-- 3. Bands, ratio and segment: immutable, so the base sets inline them (no subquery in a scalar body, and no expression
--    that is not immutable itself: a number is cast to text before ||, since integer || text is STABLE and an immutable
--    function holding it is never inlined, but called per row, five times slower at volume)
-- ---------------------------------------------------------------------------------------------
-- A band setting's values as whole numbers in their order (the setting is checked: strictly increasing, from 1)
create or replace function cma.flash_bounds_of(p_value text)
returns integer[]
language sql immutable
as $$
  select coalesce(array(select x::integer from unnest(cma.flash_list_of(p_value)) with ordinality u(x, o) where x ~ '^[0-9]{1,4}$' order by o),
                  '{}'::integer[])
$$;

-- A count's band among strictly increasing bounds (flash.device_bands): 0 for none; below the first bound 1 or 1-<b1 - 1>;
-- from a bound to the next one less one the bound alone when they are one apart, else <bound>-<next - 1>; the last bound
-- open-ended, <last>+ (1,2,3: 0, 1, 2, 3+; 1,3: 0, 1-2, 3+; 2,4: 0, 1, 2-3, 4+). Null without bounds or a count
create or replace function cma.flash_count_band_of(p_n integer, p_bounds integer[])
returns text
language sql immutable
as $$
  select case when p_n is null or coalesce(cardinality(p_bounds), 0) = 0 then null
              when p_n <= 0 then '0'
              when width_bucket(p_n, p_bounds) = 0 then case when p_bounds[1] = 2 then '1' else '1-' || (p_bounds[1] - 1)::text end
              when width_bucket(p_n, p_bounds) = cardinality(p_bounds) then p_bounds[cardinality(p_bounds)]::text || '+'
              when p_bounds[width_bucket(p_n, p_bounds) + 1] = p_bounds[width_bucket(p_n, p_bounds)] + 1
              then p_bounds[width_bucket(p_n, p_bounds)]::text
              else p_bounds[width_bucket(p_n, p_bounds)]::text || '-' || (p_bounds[width_bucket(p_n, p_bounds) + 1] - 1)::text end
$$;

-- Every count band of the bounds, in order (cma.flash_count_band_of's own words)
create or replace function cma.flash_count_bands_of(p_bounds integer[])
returns text[]
language sql immutable
as $$
  select case when coalesce(cardinality(p_bounds), 0) = 0 then '{}'::text[]
              else array(select cma.flash_count_band_of(v, p_bounds)
                         from unnest(array[0] || case when p_bounds[1] > 1 then array[1] else '{}'::integer[] end || p_bounds) with ordinality u(v, o)
                         order by o) end
$$;

-- A subscription's age in whole months from its creation (a date in the tenant's zone) up to a business date, as
-- PostgreSQL's age() counts months (created 5 November 2025: 12 on 5 November 2026, 11 the day before); negative when it
-- was created after the date (a take after midnight), null without a creation time
create or replace function cma.flash_age_months_of(p_created timestamptz, p_zone text, p_on date)
returns integer
language sql immutable
as $$
  select case when p_created is null or p_zone is null or p_on is null then null
              else (extract(year from age(p_on::timestamp, (p_created at time zone p_zone)::date::timestamp)) * 12
                    + extract(month from age(p_on::timestamp, (p_created at time zone p_zone)::date::timestamp)))::integer end
$$;

-- An age's band among strictly increasing bounds in months (flash.subscription_age_months): <b1 below the first,
-- <bound>-<next> from a bound to under the next, <last>+ from the last; unknown without an age (12,24,36,48,60: <12,
-- 12-24, 24-36, 36-48, 48-60, 60+)
create or replace function cma.flash_age_band_of(p_months integer, p_bounds integer[])
returns text
language sql immutable
as $$
  select case when p_months is null then 'unknown'
              when coalesce(cardinality(p_bounds), 0) = 0 then null
              when width_bucket(p_months, p_bounds) = 0 then '<' || p_bounds[1]::text
              when width_bucket(p_months, p_bounds) = cardinality(p_bounds) then p_bounds[cardinality(p_bounds)]::text || '+'
              else p_bounds[width_bucket(p_months, p_bounds)]::text || '-' || p_bounds[width_bucket(p_months, p_bounds) + 1]::text end
$$;

-- Every age band of the bounds, in order, unknown left out (cma.flash_age_band_of's own words)
create or replace function cma.flash_age_bands_of(p_bounds integer[])
returns text[]
language sql immutable
as $$
  select case when coalesce(cardinality(p_bounds), 0) = 0 then '{}'::text[]
              else array(select cma.flash_age_band_of(v, p_bounds) from unnest(array[p_bounds[1] - 1] || p_bounds) with ordinality u(v, o)
                         order by o) end
$$;

-- A ratio of two figures to two decimals; null without a denominator (devices_per_active_subscription: never 0 for none)
create or replace function cma.flash_ratio_of(p_num numeric, p_den numeric)
returns numeric
language sql immutable
as $$
  select case when p_den > 0 then round(coalesce(p_num, 0) / p_den, 2) end
$$;

-- A contact's segment as Flash counts it: the value of crm.customer_segments it equals whatever its case (p_lower: the
-- setting's values in lower case, in its order), in the setting's spelling; unknown for an empty value, one outside the
-- setting and none
create or replace function cma.flash_segment_of(p_value text, p_segments text[], p_lower text[])
returns text
language sql immutable
as $$
  select coalesce(p_segments[array_position(p_lower, lower(btrim(p_value)))], 'unknown')
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The overviews: three gain dims and measures (the rest as 0008zn)
-- ---------------------------------------------------------------------------------------------
-- As 0008zn (122): per overview its order, stock or flow, its source, its dims, its grouping sets, its measures, the
-- measures that count records (the watch's jump reads them; a list can be narrowed to the records behind one), its
-- headline and its list's sort keys. 0008zt: customers' segment and [market, segment]; subscriptions' device_band and
-- age_band with [market, device_band] and [market, age_band], holding_subscriptions and devices_on_holding (counts) and
-- devices_per_holding_subscription (a ratio: no count measure, so the watch never compares it); installed_base's
-- subscription_status with [market, subscription_status] and in_field_on_holding (a count)
create or replace function cma.flash_overviews()
returns table (key text, sort_order integer, kind text, source text, dims text[], sets jsonb, measures text[], count_measures text[],
               headline text, sorts text[])
language sql immutable
as $$
  values
    ('customers', 10, 'stock', 'commerce', array['market', 'store', 'segment'], '[[], ["market"], ["market", "store"], ["market", "segment"]]'::jsonb,
       array['customers_held', 'active_customers', 'paused_customers', 'linked_to_contact', 'with_required_refs'],
       array['customers_held', 'active_customers', 'paused_customers', 'linked_to_contact', 'with_required_refs'], 'active_customers',
       array['lifetime_orders', 'total_spent', 'customer_id', 'store', 'market', 'active_subscriptions', 'devices']),
    ('subscriptions', 20, 'stock', 'subscriptions', array['market', 'store', 'status', 'payment_state', 'device_band', 'age_band'],
       '[[], ["market"], ["market", "store", "status", "payment_state"], ["market", "device_band"], ["market", "age_band"]]'::jsonb,
       array['subscriptions', 'active_subscriptions', 'paused_subscriptions', 'amount_per_cycle', 'holding_subscriptions', 'devices_on_holding',
             'devices_per_holding_subscription'],
       array['subscriptions', 'active_subscriptions', 'paused_subscriptions', 'holding_subscriptions', 'devices_on_holding'], 'active_subscriptions',
       array['subscription_id', 'store', 'market', 'status', 'payment_state', 'amount_per_cycle', 'next_billing_at', 'retry_since', 'devices']),
    ('installed_base', 30, 'stock', 'assets', array['market', 'status', 'model', 'warehouse', 'link', 'subscription_status'],
       '[[], ["market"], ["market", "status", "model", "warehouse", "link"], ["market", "subscription_status"]]'::jsonb,
       array['devices', 'in_field', 'in_stock', 'components_past_due', 'items_due_3m', 'in_field_on_holding'],
       array['devices', 'in_field', 'in_stock', 'components_past_due', 'items_due_3m', 'in_field_on_holding'], 'in_field',
       array['serial', 'model', 'market', 'status', 'warehouse', 'past_due_items', 'next_due_on']),
    ('churn', 40, 'flow', 'subscriptions', array['market', 'store', 'reason'], '[[], ["market"], ["market", "store", "reason"]]'::jsonb,
       array['churned'], array['churned'], 'churned',
       array['churned_at', 'subscription_id', 'store', 'market', 'reason', 'cycles']),
    ('orders', 50, 'flow', 'commerce', array['market', 'store', 'kind', 'sku'],
       '[[], ["market"], ["market", "store", "kind"], ["market", "sku"]]'::jsonb,
       array['orders', 'units', 'amount'], array['orders'], 'orders',
       array['created_at', 'order_number', 'store', 'market', 'kind', 'total']),
    ('payments', 60, 'flow', 'commerce', array['market', 'store', 'kind', 'status'],
       '[[], ["market"], ["market", "store", "kind", "status"]]'::jsonb,
       array['orders', 'amount', 'renewals', 'failed_renewals'], array['orders', 'renewals', 'failed_renewals'], 'failed_renewals',
       array['at', 'kind', 'status', 'amount', 'store', 'market']),
    ('open_deals', 70, 'stock', 'crm', array['market', 'pipeline', 'stage'], '[[], ["market"], ["market", "pipeline", "stage"]]'::jsonb,
       array['open_deals', 'median_age_days', 'oldest_age_days'], array['open_deals'], 'open_deals',
       array['age_days', 'created_at', 'record_id', 'pipeline', 'stage', 'market']),
    ('open_tickets', 80, 'stock', 'crm', array['market', 'queue', 'stage'], '[[], ["market"], ["market", "queue", "stage"]]'::jsonb,
       array['open_tickets', 'median_age_days', 'oldest_age_days'], array['open_tickets'], 'open_tickets',
       array['age_days', 'created_at', 'record_id', 'queue', 'stage', 'market']),
    ('open_tasks', 90, 'stock', 'crm', array['market', 'type', 'status'], '[[], ["market"], ["market", "type", "status"]]'::jsonb,
       array['open_tasks', 'overdue'], array['open_tasks', 'overdue'], 'open_tasks',
       array['due_at', 'task_id', 'type', 'status', 'market']),
    ('reviews', 100, 'flow', 'reviews', array['market', 'rating'], '[[], ["market"], ["market", "rating"]]'::jsonb,
       array['reviews', 'rating_sum', 'negative'], array['reviews', 'negative'], 'reviews',
       array['submitted_at', 'rating', 'market', 'review_id']),
    ('data_quality', 110, 'stock', null, array['check', 'market'], '[[], ["market"], ["check"], ["check", "market"]]'::jsonb,
       array['findings'], array['findings'], 'findings',
       array['object_id', 'check', 'market'])
$$;

-- The definition every figure of an overview follows; a later change of a definition gives a new version, so a
-- snapshot says which one it was computed by
create or replace function cma.flash_definition_version(p_overview text)
returns text
language sql immutable
as $$
  select case when p_overview in ('customers', 'subscriptions', 'installed_base') then '0008zt'
              when p_overview in (select o.key from cma.flash_overviews() o) then '0008zn' end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The base sets of the three overviews
-- ---------------------------------------------------------------------------------------------
-- The customers' and the subscriptions' base sets gain columns, so they get signatures of their own
-- (cma.flash_store_customers_of, cma.flash_subscriptions_of(uuid, date)), and 0008zn's (cma.flash_customers_of(uuid),
-- cma.flash_subscriptions_of(uuid)) read them with 0008zn's columns: one base set per overview, and a function never
-- changes its columns in place, so 122 can run again before this (PostgreSQL refuses a changed column list on create or
-- replace). The month end's id lists and churn's active subscriptions at the period's end keep reading 0008zn's names.
-- The devices' base set keeps its columns: the subscription status is now the linked subscription's, else not_found, else
-- none, and a device is on an active subscription when that status is an active one

-- As 0008zn (122), with the customer segment: store customers the CMA holds (not deleted), each with its store and market
-- (the store's), lifetime orders and total spent as the store states them, the CRM contact it is linked to (0008h) and
-- whether the CMA holds that contact, the contact's references among commerce.required_contact_refs (each system's first
-- slot) and those it lacks in every slot (every one when the contact is not held), its subscriptions in the active statuses
-- and paused (of the subscriptions of its store, not missing), the devices whose customer reference is its id, of its
-- store's market (the register names no store: a customer id is matched within a market, so two stores of one market
-- sharing an id would share its devices; docs/architecture/data-model/0008.md), and its segment (0008zt): the held
-- contact's segment when crm.customer_segments holds it (in the setting's spelling, matched whatever its case), else
-- unknown (an empty value, a value outside the setting, no linked contact, a contact the CMA does not hold)
create or replace function cma.flash_store_customers_of(p_tenant_id uuid)
returns table (customer_id uuid, connection_id uuid, source_id text, store text, market text, lifetime_orders integer, total_spent numeric,
               currency text, crm_connection_id uuid, contact_source_id text, contact_held boolean, refs jsonb, missing_refs text[],
               active_subscriptions integer, paused_subscriptions integer, devices integer, segment text)
language sql stable
as $$
  with s as materialized (
    select cma.flash_active_statuses_of(p_tenant_id) as active,
           cma.flash_list_of(cma.setting_of(p_tenant_id, 'commerce.required_contact_refs')) as refs,
           cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments')) as segments,
           array(select lower(x) from unnest(cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments'))) with ordinality u(x, o)
                 order by o) as segments_lower
  ), st as materialized (
    select x.connection_id, x.handle, x.market from cma.commerce_store x where x.tenant_id = p_tenant_id
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  ), sub as materialized (
    select sm.store_connection_id, sb.customer_source_id,
           count(*) filter (where sb.status = any (s.active))::integer as active,
           count(*) filter (where sb.status = 'paused')::integer as paused
    from cma.subscription sb
    join sm on sm.connection_id = sb.connection_id
    cross join s
    where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null and sb.customer_source_id is not null
    group by 1, 2
  ), dev as materialized (
    select d.customer_ref, d.market, count(*)::integer as n
    from cma.device d
    where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.customer_ref is not null
    group by 1, 2
  ), refs as materialized (
    select x.contact_id, jsonb_object_agg(x.system, x.external_id) as refs
    from (select distinct on (cr.contact_id, cr.system) cr.contact_id, cr.system, cr.external_id
          from cma.crm_contact_ref cr cross join s
          where cr.tenant_id = p_tenant_id and cr.system = any (s.refs)
          order by cr.contact_id, cr.system, cr.slot) x
    group by 1
  )
  select cu.id, cu.connection_id, cu.source_id, coalesce(st.handle, 'unknown'), coalesce(st.market, 'unknown'), cu.orders_count,
         cu.amount_spent, cu.amount_currency, cu.crm_connection_id, cu.crm_contact_source_id, k.id is not null,
         coalesce(r.refs, '{}'::jsonb),
         case when cu.crm_contact_source_id is null then '{}'::text[]
              else array(select x from unnest(s.refs) x where not (coalesce(r.refs, '{}'::jsonb) ? x)) end,
         coalesce(sub.active, 0), coalesce(sub.paused, 0), coalesce(dev.n, 0),
         cma.flash_segment_of(k.segment, s.segments, s.segments_lower)
  from cma.commerce_customer cu
  cross join s
  left join st on st.connection_id = cu.connection_id
  left join cma.crm_contact k
    on k.tenant_id = cu.tenant_id and k.connection_id = cu.crm_connection_id and k.source_id = cu.crm_contact_source_id
   and k.source_deleted_at is null
  left join refs r on r.contact_id = k.id
  left join sub on sub.store_connection_id = cu.connection_id and sub.customer_source_id = cu.source_id
  left join dev on dev.customer_ref = cu.source_id and dev.market = st.market
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null
$$;

-- 0008zn's base set of the customers, its columns as they were: cma.flash_store_customers_of's rows (the month end's id lists)
create or replace function cma.flash_customers_of(p_tenant_id uuid)
returns table (customer_id uuid, connection_id uuid, source_id text, store text, market text, lifetime_orders integer, total_spent numeric,
               currency text, crm_connection_id uuid, contact_source_id text, contact_held boolean, refs jsonb, missing_refs text[],
               active_subscriptions integer, paused_subscriptions integer, devices integer)
language sql stable
as $$
  select x.customer_id, x.connection_id, x.source_id, x.store, x.market, x.lifetime_orders, x.total_spent, x.currency, x.crm_connection_id,
         x.contact_source_id, x.contact_held, x.refs, x.missing_refs, x.active_subscriptions, x.paused_subscriptions, x.devices
  from cma.flash_store_customers_of(p_tenant_id) x
$$;

-- As 0008zn (122), measured against a business date (p_on: the snapshot's date in a take; null, the tenant's today live),
-- with the devices in the field, whether it holds devices, the age band and the device band: subscriptions the latest full
-- read still returns, each
-- with its store and market (its connection's store), its store customer's CRM contact (0008h), status, payment state
-- (0008zl; none for merged and never-subscribed), whether its status is an active one, amount per cycle and currency,
-- interval, next billing, the open failed renewal's first failure and highest attempt, the devices whose subscription
-- reference is its id, of its store's market (every device status: the list's devices, unchanged), and of those the
-- devices in the field (a device status flagged is_in_field: devices_in_field, 0008zt), whether its status is one of
-- flash.device_holding_statuses (is_holding). An active subscription's age band is its age in whole months from its
-- creation in the subscription app (source_created_at, as a date in the tenant's zone) up to the business date
-- (cma.flash_age_months_of) in the bands of flash.subscription_age_months (unknown without a creation time), none for
-- another status; a device-holding subscription's device band its devices in the field in the bands of
-- flash.device_bands, none for another status
create or replace function cma.flash_subscriptions_of(p_tenant_id uuid, p_on date)
returns table (subscription_id uuid, connection_id uuid, source_id text, store text, market text, customer_source_id text,
               crm_connection_id uuid, contact_source_id text, status text, payment_state text, is_active boolean, amount_per_cycle numeric,
               currency text, billing_interval text, billing_interval_count integer, next_billing_at timestamptz, retry_since timestamptz,
               last_attempt integer, devices integer, devices_in_field integer, is_holding boolean, age_band text, device_band text)
language sql stable
as $$
  with s as materialized (
    -- the bands once: their words in order (cma.flash_count_bands_of, cma.flash_age_bands_of) and the steps between them,
    -- so a row's band is one width_bucket into them (a device band's steps start at 1 when its first bound is higher: the
    -- band 1 or 1-<b1 - 1>); a row's age is computed once (an expensive argument used twice is never inlined)
    select x.active, x.holding, x.zone, x.on_date, x.ages, cma.flash_age_bands_of(x.ages) as age_words,
           case when x.device_bands[1] > 1 then array[1] || x.device_bands else x.device_bands end as device_steps,
           cma.flash_count_bands_of(x.device_bands) as device_words
    from (select cma.flash_active_statuses_of(p_tenant_id) as active, cma.flash_holding_statuses_of(p_tenant_id) as holding,
                 cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.device_bands')) as device_bands,
                 cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.subscription_age_months')) as ages,
                 (select t.timezone from cma.tenant t where t.id = p_tenant_id) as zone,
                 coalesce(p_on, cma.tenant_today_of(p_tenant_id)) as on_date) x
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  ), ps as materialized (
    select p.subscription_id, p.payment_state, p.retry_since, p.last_attempt from cma.subscription_payment_state_of(p_tenant_id) p
  ), dev as materialized (
    select d.subscription_ref, d.market, count(*)::integer as n, count(*) filter (where coalesce(ds.is_in_field, false))::integer as n_field
    from cma.device d
    left join cma.device_status ds on ds.tenant_id = d.tenant_id and ds.key = d.device_status_key
    where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.subscription_ref is not null
    group by 1, 2
  )
  select sb.id, sb.connection_id, sb.source_id, coalesce(sm.handle, 'unknown'), coalesce(sm.market, 'unknown'), sb.customer_source_id,
         cu.crm_connection_id, cu.crm_contact_source_id, sb.status, coalesce(ps.payment_state, 'none'), sb.status = any (s.active),
         sb.amount_per_cycle, sb.currency, sb.billing_interval, sb.billing_interval_count, sb.next_billing_at, ps.retry_since, ps.last_attempt,
         coalesce(dev.n, 0), coalesce(dev.n_field, 0), sb.status = any (s.holding),
         -- cma.flash_age_band_of's and cma.flash_count_band_of's words, looked up (unknown: no creation time): the age of an
         -- active subscription, the devices band of one in a device-holding status
         case when sb.status = any (s.active)
              then coalesce(s.age_words[width_bucket(cma.flash_age_months_of(sb.source_created_at, s.zone, s.on_date), s.ages) + 1], 'unknown') end,
         case when sb.status = any (s.holding) then s.device_words[width_bucket(coalesce(dev.n_field, 0), s.device_steps) + 1] end
  from cma.subscription sb
  cross join s
  left join sm on sm.connection_id = sb.connection_id
  left join ps on ps.subscription_id = sb.id
  left join cma.commerce_customer cu
    on cu.tenant_id = sb.tenant_id and cu.connection_id = sm.store_connection_id and cu.source_id = sb.customer_source_id
   and cu.source_deleted_at is null
  left join dev on dev.subscription_ref = sb.source_id and dev.market = sm.market
  where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null
$$;

-- 0008zn's base set of the subscriptions, its columns as they were, as of the tenant's today: cma.flash_subscriptions_of's
-- rows with a business date (the month end's id lists, churn's active subscriptions at the period's end)
create or replace function cma.flash_subscriptions_of(p_tenant_id uuid)
returns table (subscription_id uuid, connection_id uuid, source_id text, store text, market text, customer_source_id text,
               crm_connection_id uuid, contact_source_id text, status text, payment_state text, is_active boolean, amount_per_cycle numeric,
               currency text, billing_interval text, billing_interval_count integer, next_billing_at timestamptz, retry_since timestamptz,
               last_attempt integer, devices integer)
language sql stable
as $$
  select x.subscription_id, x.connection_id, x.source_id, x.store, x.market, x.customer_source_id, x.crm_connection_id, x.contact_source_id,
         x.status, x.payment_state, x.is_active, x.amount_per_cycle, x.currency, x.billing_interval, x.billing_interval_count, x.next_billing_at,
         x.retry_since, x.last_attempt, x.devices
  from cma.flash_subscriptions_of(p_tenant_id, null::date) x
$$;

-- As 0008zn (122), with the device's subscription status (its columns unchanged): devices the asset
-- register still holds (not missing from its latest full snapshot), each with its serial, model, market and device status
-- (unknown when unmapped), the status's flags, its warehouse (none; other for a value a snapshot cannot hold,
-- cma.flash_dim_of), its named ids among assets.required_refs and those it lacks, its customer and subscription
-- references, the subscription link (linked: a subscription of a store of the device's market has the reference as its
-- id; not_found; none: no reference) with that subscription's id, the subscription status (0008zt: the linked
-- subscription's status in the subscription app's words, else not_found, else none: a device is on an active subscription
-- when it is one of flash.active_subscription_statuses, which not_found and none never are; its payment state is the
-- list's, cma.flash_rows_of), and from 0008zi's forecast as of p_today its past-due items, its items due within three months (not past due) and its
-- earliest due date. p_today is the business date the figures are for: the tenant's today live, the snapshot's own date
-- in a take (so an item due on a month's last day is not past due in that month end's snapshot, taken after midnight)
create or replace function cma.flash_devices_of(p_tenant_id uuid, p_today date)
returns table (device_id uuid, connection_id uuid, source_id text, serial text, model text, market text, status text, is_in_field boolean,
               is_in_stock boolean, warehouse text, refs jsonb, missing_refs text[], customer_ref text, subscription_ref text, link text,
               subscription_id uuid, subscription_status text, past_due_items integer, items_due_3m integer, next_due_on date)
language sql stable
as $$
  with s as materialized (
    select cma.flash_list_of(cma.setting_of(p_tenant_id, 'assets.required_refs')) as refs
  ), sub as materialized (
    -- the subscriptions of the stores' subscriptions connections, with the store's market: the register names no
    -- connection, so a device's reference is matched within its own market
    select distinct on (sm.market, x.source_id) sm.market, x.source_id, x.id, x.status
    from cma.subscription x
    join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = x.connection_id
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null
    order by sm.market, x.source_id, x.id
  ), mi as materialized (
    select i.device_id,
           count(*) filter (where i.past_due)::integer as past_due,
           count(*) filter (where not i.past_due and i.due_on >= p_today and i.due_on < (p_today + interval '3 months')::date)::integer as due_3m,
           min(i.due_on) as next_due
    from cma.maintenance_items_of(p_tenant_id, p_today) i
    group by 1
  )
  select d.id, d.connection_id, d.source_id, d.serial, coalesce(d.model_key, 'unknown'), coalesce(d.market, 'unknown'),
         coalesce(d.device_status_key, 'unknown'), coalesce(st.is_in_field, false), coalesce(st.is_in_stock, false),
         cma.flash_dim_of(d.warehouse_ref, 'none'),
         coalesce((select jsonb_object_agg(x, d.external_refs ->> x) from unnest(s.refs) x where d.external_refs ? x), '{}'::jsonb),
         array(select x from unnest(s.refs) x where not (d.external_refs ? x)),
         d.customer_ref, d.subscription_ref,
         case when d.subscription_ref is null then 'none' when sub.source_id is not null then 'linked' else 'not_found' end,
         sub.id,
         case when d.subscription_ref is null then 'none' when sub.source_id is not null then sub.status else 'not_found' end,
         coalesce(mi.past_due, 0), coalesce(mi.due_3m, 0), mi.next_due
  from cma.device d
  cross join s
  left join cma.device_status st on st.tenant_id = d.tenant_id and st.key = d.device_status_key
  left join sub on sub.market = d.market and sub.source_id = d.subscription_ref
  left join mi on mi.device_id = d.id
  where d.tenant_id = p_tenant_id and d.source_deleted_at is null
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The figures: one computation, live and in the snapshot
-- ---------------------------------------------------------------------------------------------
-- As 0008zn (122), with 0008zt's sets and measures. An overview's figures for an explicit tenant: one row per grouping set
-- of the overview (cma.flash_overviews().sets): dims (the set's keys and values: {} for the totals) and measures. Stock
-- overviews read the mirrors as they are (the period is ignored) and measure against p_on, the business date the figures
-- are for: null live (the tenant's today, ages as of now), the snapshot's date in a take (past due and due within three
-- months against that date, overdue tasks due before it, ages as of its end, a subscription's age up to that date), so a
-- snapshot taken after midnight says what its own date said. Flow overviews take the business dates p_from to p_to.
-- Amounts are summed per currency (an object of currency codes); never across currencies. Nothing for an overview whose
-- source the tenant has not set up; the totals row with zeros for a set-up source without records. A measure that does
-- not apply is left out of every row, never 0: the customers' with_required_refs while commerce.required_contact_refs is
-- empty (Decision log, 3 Nov 2026), and devices_per_holding_subscription in a row without a device-holding subscription.
-- The subscriptions' device band rows carry the holding subscriptions, their devices in the field and the ratio, the age
-- band rows the active subscriptions; every band of the settings has its row for each market with a subscription it counts.
-- The snapshot stores exactly these rows (one code path)
create or replace function cma.flash_compute_of(p_tenant_id uuid, p_overview text, p_from date default null, p_to date default null,
                                                p_on date default null)
returns table (dims jsonb, measures jsonb)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_src   text := (select o.source from cma.flash_overviews() o where o.key = p_overview);
  -- today once, a value (a function call passed on would be evaluated per row where the base sets inline it)
  v_today date := cma.tenant_today_of(p_tenant_id);
  v_from  date := coalesce(p_from, v_today);
  v_to    date := coalesce(p_to, p_from, v_today);
  -- the stock figures' date and instant: today and now live; the snapshot's date and its end (the next day's 00:00 in
  -- the tenant's zone) in a take
  v_on    date := coalesce(p_on, v_today);
  v_at    timestamptz := case when p_on is null then now()
                              else ((p_on + 1)::timestamp at time zone (select t.timezone from cma.tenant t where t.id = p_tenant_id)) end;
  -- with_required_refs applies only while a contact reference is required
  v_refs_required boolean := cardinality(cma.flash_list_of(cma.setting_of(p_tenant_id, 'commerce.required_contact_refs'))) > 0;
  -- the bands of the active subscriptions (0008zt): every band of the settings has its row per market, zeros included
  v_device_bands  integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.device_bands'));
  v_ages          integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.subscription_age_months'));
  -- a device is on a device-holding subscription when its subscription status is a holding one (0008zt)
  v_holding       text[] := cma.flash_holding_statuses_of(p_tenant_id);
begin
  perform cma.assert_flash_overview(p_overview);
  if v_src is not null and not coalesce((cma.flash_sources_of(p_tenant_id) -> v_src ->> 'set_up')::boolean, false) then
    return;
  end if;
  if p_overview = 'customers' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.store) = 0 then jsonb_build_object('market', b.market, 'store', b.store)
                  when grouping(b.segment) = 0 then jsonb_build_object('market', b.market, 'segment', b.segment)
                  else jsonb_build_object('market', b.market) end,
             jsonb_build_object('customers_held', count(*),
                                'active_customers', count(*) filter (where b.active_subscriptions > 0),
                                'paused_customers', count(*) filter (where b.active_subscriptions = 0 and b.paused_subscriptions > 0),
                                'linked_to_contact', count(*) filter (where b.contact_source_id is not null))
             || case when v_refs_required
                     then jsonb_build_object('with_required_refs', count(*) filter (where b.contact_source_id is not null and b.contact_held
                                                                                     and cardinality(b.missing_refs) = 0))
                     else '{}'::jsonb end
      from cma.flash_store_customers_of(p_tenant_id) b
      group by grouping sets ((), (b.market), (b.market, b.store), (b.market, b.segment));
  elsif p_overview = 'subscriptions' then
    -- the base set read once (measured against v_on: the age bands), for the totals, per market, the breakdown and the
    -- bands; holding_subscriptions and devices_on_holding count the device-holding subscriptions and their devices in the
    -- field (0008zt), their ratio is left out of a row without a holding subscription (null, never 0); the device bands are
    -- the holding subscriptions', the age bands the active ones'
    return query
      with b as materialized (
        select x.market, x.store, x.status, x.payment_state, x.currency, x.is_active, x.is_holding, x.amount_per_cycle, x.devices_in_field,
               x.age_band, x.device_band
        from cma.flash_subscriptions_of(p_tenant_id, v_on) x
      ), a as (
        select case when grouping(b.market) = 1 then '{}'::jsonb
                    when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                    else jsonb_build_object('market', b.market, 'store', b.store, 'status', b.status, 'payment_state', b.payment_state) end as dims,
               b.currency, count(*) as n, count(*) filter (where b.is_active) as act, count(*) filter (where b.status = 'paused') as paused,
               -- the active subscriptions' amounts only, each for its own billing cycle (Flash overview measures)
               sum(b.amount_per_cycle) filter (where b.is_active) as amount,
               count(*) filter (where b.is_holding) as hold,
               coalesce(sum(b.devices_in_field) filter (where b.is_holding), 0) as dev
        from b
        group by grouping sets ((b.currency), (b.market, b.currency), (b.market, b.store, b.status, b.payment_state, b.currency))
      ), bands as (
        -- the holding subscriptions per market and device band with their devices in the field; the active ones per age band
        select b.market, 'device_band'::text as dim, b.device_band as band, count(*) as n, sum(b.devices_in_field) as dev
        from b where b.is_holding group by 1, 2, 3
        union all
        select b.market, 'age_band', b.age_band, count(*), null from b where b.is_active group by 1, 2, 3
      ), labels as (
        -- every band of the settings for each market with a subscription it counts (unknown only when a subscription has it)
        select m.market, 'device_band'::text as dim, x as band
        from (select distinct b.market from b where b.is_holding) m cross join unnest(cma.flash_count_bands_of(v_device_bands)) x
        union all
        select m.market, 'age_band', x
        from (select distinct b.market from b where b.is_active) m cross join unnest(cma.flash_age_bands_of(v_ages)) x
      )
      select a.dims, jsonb_build_object('subscriptions', sum(a.n), 'active_subscriptions', sum(a.act), 'paused_subscriptions', sum(a.paused),
                                        'amount_per_cycle', coalesce(jsonb_object_agg(a.currency, round(a.amount, 2))
                                                                       filter (where a.currency is not null and a.amount is not null), '{}'::jsonb),
                                        'holding_subscriptions', sum(a.hold), 'devices_on_holding', sum(a.dev))
                     || jsonb_strip_nulls(jsonb_build_object('devices_per_holding_subscription', cma.flash_ratio_of(sum(a.dev), sum(a.hold))))
      from a group by a.dims
      union all
      select jsonb_build_object('market', coalesce(n.market, l.market), coalesce(n.dim, l.dim), coalesce(n.band, l.band)),
             case when coalesce(n.dim, l.dim) = 'age_band' then jsonb_build_object('active_subscriptions', coalesce(n.n, 0))
                  else jsonb_build_object('holding_subscriptions', coalesce(n.n, 0), 'devices_on_holding', coalesce(n.dev, 0))
                       || jsonb_strip_nulls(jsonb_build_object('devices_per_holding_subscription', cma.flash_ratio_of(coalesce(n.dev, 0), coalesce(n.n, 0))))
             end
      from labels l
      full join bands n on n.market = l.market and n.dim = l.dim and n.band = l.band;
    if not found then
      return query select '{}'::jsonb, jsonb_build_object('subscriptions', 0, 'active_subscriptions', 0, 'paused_subscriptions', 0,
                                                          'amount_per_cycle', '{}'::jsonb, 'holding_subscriptions', 0, 'devices_on_holding', 0);
    end if;
  elsif p_overview = 'installed_base' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.status) = 0
                  then jsonb_build_object('market', b.market, 'status', b.status, 'model', b.model, 'warehouse', b.warehouse, 'link', b.link)
                  when grouping(b.subscription_status) = 0 then jsonb_build_object('market', b.market, 'subscription_status', b.subscription_status)
                  else jsonb_build_object('market', b.market) end,
             jsonb_build_object('devices', count(*), 'in_field', count(*) filter (where b.is_in_field),
                                'in_stock', count(*) filter (where b.is_in_stock), 'components_past_due', coalesce(sum(b.past_due_items), 0),
                                'items_due_3m', coalesce(sum(b.items_due_3m), 0),
                                -- devices in the field on a device-holding subscription (0008zt): never one in stock, whatever its reference
                                'in_field_on_holding', count(*) filter (where b.is_in_field and b.subscription_status = any (v_holding)))
      from cma.flash_devices_of(p_tenant_id, v_on) b
      group by grouping sets ((), (b.market), (b.market, b.status, b.model, b.warehouse, b.link), (b.market, b.subscription_status));
  elsif p_overview = 'churn' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'store', b.store, 'reason', b.reason) end,
             jsonb_build_object('churned', count(*))
      from cma.flash_churn_of(p_tenant_id, v_from, v_to) b
      group by grouping sets ((), (b.market), (b.market, b.store, b.reason));
  elsif p_overview = 'orders' then
    return query
      -- orders and amounts from the orders (their lines not read), units from the lines, read once for the units and the
      -- SKU rows alike: an order's units are the sum of its lines' quantities, so the sums per set are the same
      with ol as materialized (
        select l.order_id, l.store, l.market, l.kind, l.sku, l.units from cma.flash_order_lines_of(p_tenant_id, v_from, v_to) l
      ), a as (
        select case when grouping(b.market) = 1 then '{}'::jsonb
                    when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                    else jsonb_build_object('market', b.market, 'store', b.store, 'kind', b.kind) end as dims,
               b.currency, count(*) as n, sum(b.total) as amount
        from cma.flash_orders_of(p_tenant_id, v_from, v_to) b
        group by grouping sets ((b.currency), (b.market, b.currency), (b.market, b.store, b.kind, b.currency))
      ), u as materialized (
        select case when grouping(l.market) = 1 then '{}'::jsonb
                    when grouping(l.store) = 1 then jsonb_build_object('market', l.market)
                    else jsonb_build_object('market', l.market, 'store', l.store, 'kind', l.kind) end as dims,
               sum(l.units) as units
        from ol l
        group by grouping sets ((), (l.market), (l.market, l.store, l.kind))
      )
      select a.dims, jsonb_build_object('orders', sum(a.n), 'units', coalesce((select u.units from u where u.dims = a.dims), 0),
                                        'amount', coalesce(jsonb_object_agg(a.currency, round(a.amount, 2))
                                                             filter (where a.currency is not null and a.amount is not null), '{}'::jsonb))
      from a group by a.dims
      union all
      select jsonb_build_object('market', l.market, 'sku', l.sku), jsonb_build_object('orders', count(distinct l.order_id), 'units', sum(l.units))
      from ol l
      group by l.market, l.sku;
    if not found then
      return query select '{}'::jsonb, jsonb_build_object('orders', 0, 'units', 0, 'amount', '{}'::jsonb);
    end if;
  elsif p_overview = 'payments' then
    return query
      with a as (
        select case when grouping(b.market) = 1 then '{}'::jsonb
                    when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                    else jsonb_build_object('market', b.market, 'store', b.store, 'kind', b.kind, 'status', b.status) end as dims,
               b.currency, count(*) filter (where b.kind = 'order') as orders, sum(b.amount) filter (where b.kind = 'order') as amount,
               count(*) filter (where b.kind = 'renewal' and b.status = 'renewed') as renewals,
               count(*) filter (where b.kind = 'renewal' and b.status = 'renew_failed') as failed
        from cma.flash_payments_of(p_tenant_id, v_from, v_to) b
        group by grouping sets ((b.currency), (b.market, b.currency), (b.market, b.store, b.kind, b.status, b.currency))
      )
      select a.dims, jsonb_build_object('orders', sum(a.orders), 'renewals', sum(a.renewals), 'failed_renewals', sum(a.failed),
                                        'amount', coalesce(jsonb_object_agg(a.currency, round(a.amount, 2))
                                                             filter (where a.currency is not null and a.amount is not null), '{}'::jsonb))
      from a group by a.dims;
    if not found then
      return query select '{}'::jsonb, jsonb_build_object('orders', 0, 'renewals', 0, 'failed_renewals', 0, 'amount', '{}'::jsonb);
    end if;
  elsif p_overview = 'open_deals' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.pipeline) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'pipeline', b.pipeline, 'stage', b.stage) end,
             jsonb_strip_nulls(jsonb_build_object('open_deals', count(*),
                                'median_age_days', round((percentile_cont(0.5) within group (order by b.age_days))::numeric, 1),
                                'oldest_age_days', max(b.age_days)))
      from cma.flash_deals_of(p_tenant_id, v_at) b
      group by grouping sets ((), (b.market), (b.market, b.pipeline, b.stage));
  elsif p_overview = 'open_tickets' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.queue) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'queue', b.queue, 'stage', b.stage) end,
             jsonb_strip_nulls(jsonb_build_object('open_tickets', count(*),
                                'median_age_days', round((percentile_cont(0.5) within group (order by b.age_days))::numeric, 1),
                                'oldest_age_days', max(b.age_days)))
      from cma.flash_tickets_of(p_tenant_id, v_at) b
      group by grouping sets ((), (b.market), (b.market, b.queue, b.stage));
  elsif p_overview = 'open_tasks' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.type) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'type', b.type, 'status', b.status) end,
             jsonb_build_object('open_tasks', count(*), 'overdue', count(*) filter (where b.overdue))
      from cma.flash_tasks_of(p_tenant_id, v_on) b
      group by grouping sets ((), (b.market), (b.market, b.type, b.status));
  elsif p_overview = 'reviews' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.stars) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'rating', b.stars::text) end,
             jsonb_build_object('reviews', count(*), 'rating_sum', coalesce(sum(b.rating), 0), 'negative', count(*) filter (where b.is_negative))
      from cma.flash_reviews_of(p_tenant_id, v_from, v_to) b
      group by grouping sets ((), (b.market), (b.market, b.stars));
  elsif p_overview = 'data_quality' then
    -- counted per check and market first (a few rows), then the grouping sets over those counts
    return query
      select case when grouping(b.check_key) = 1 and grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.check_key) = 1 then jsonb_build_object('market', b.market)
                  when grouping(b.market) = 1 then jsonb_build_object('check', b.check_key)
                  else jsonb_build_object('check', b.check_key, 'market', b.market) end,
             jsonb_build_object('findings', coalesce(sum(b.n), 0))
      from (select f.check_key, f.market, count(*) as n from cma.flash_findings_of(p_tenant_id) f group by 1, 2) b
      group by grouping sets ((), (b.market), (b.check_key), (b.check_key, b.market));
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. The lists
-- ---------------------------------------------------------------------------------------------
-- As 0008zn (122), with 0008zt's filters (customers' segment, subscriptions' device_band and age_band, the installed
-- base's subscription_status), the new count measures' records (in_field_on_holding: the devices in the field on a
-- device-holding subscription; holding_subscriptions; devices_on_holding: the holding subscriptions with a device in the
-- field, whose devices_in_field add up to the figure) and the subscriptions' column devices_in_field. An overview's list, live, for an explicit tenant (no
-- permission checked: cma.flash_rows checks it): the records of the overview's base set after the filters (its dims, and
-- measure: the records one count measure counts), in the order, p_limit from p_offset, each as an object of ids, codes,
-- amounts, times and links; total the count before the limit. Flows over p_from to p_to
create or replace function cma.flash_rows_of(p_tenant_id uuid, p_overview text, p_filters jsonb, p_sort text, p_descending boolean,
                                             p_limit integer, p_offset integer, p_from date, p_to date)
returns jsonb
language plpgsql stable
as $$
declare
  v_order text := cma.flash_order_by(p_overview, p_sort, p_descending);
  v_today date := cma.tenant_today_of(p_tenant_id);
  v_from  date := coalesce(p_from, v_today);
  v_to    date := coalesce(p_to, p_from, v_today);
  v_src   text := (select o.source from cma.flash_overviews() o where o.key = p_overview);
  v_base  text;
  v_where text;
  v_obj   text;
  v_res   jsonb;
begin
  if v_order is null then
    raise exception 'sort % is not a sort key of %', p_sort, p_overview using errcode = 'CMA04';
  end if;
  if v_src is not null and not coalesce((cma.flash_sources_of(p_tenant_id) -> v_src ->> 'set_up')::boolean, false) then
    return jsonb_build_object('total', 0, 'rows', '[]'::jsonb);
  end if;
  case p_overview
    when 'customers' then
      v_base := 'cma.flash_store_customers_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''segment'' is null or x.segment = $1 ->> ''segment'')
                  and case $1 ->> ''measure'' when ''active_customers'' then x.active_subscriptions > 0
                                              when ''paused_customers'' then x.active_subscriptions = 0 and x.paused_subscriptions > 0
                                              when ''linked_to_contact'' then x.contact_source_id is not null
                                              when ''with_required_refs'' then x.contact_source_id is not null and x.contact_held and cardinality(x.missing_refs) = 0
                                              else true end';
      v_obj := 'jsonb_build_object(''customer_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market,
                  ''contact_id'', x.contact_source_id, ''contact_url'', cma.record_url(x.crm_connection_id, ''contact'', x.contact_source_id),
                  ''contact_held'', x.contact_held, ''refs'', x.refs, ''missing_refs'', to_jsonb(x.missing_refs),
                  ''lifetime_orders'', x.lifetime_orders, ''total_spent'', x.total_spent, ''currency'', x.currency,
                  ''active_subscriptions'', x.active_subscriptions, ''paused_subscriptions'', x.paused_subscriptions, ''devices'', x.devices,
                  ''order_ids'', (select coalesce(jsonb_agg(q.n order by q.at desc, q.n), ''[]''::jsonb)
                                 from (select coalesce(o.order_name, o.source_id) as n, o.source_created_at as at from cma.commerce_order o
                                       where o.tenant_id = $2 and o.connection_id = x.connection_id and o.customer_source_id = x.source_id
                                         and o.source_deleted_at is null order by o.source_created_at desc, o.source_id limit 20) q),
                  ''orders_held'', (select count(*) from cma.commerce_order o where o.tenant_id = $2 and o.connection_id = x.connection_id
                                     and o.customer_source_id = x.source_id and o.source_deleted_at is null),
                  ''subscription_ids'', (select coalesce(jsonb_agg(q.source_id order by q.source_id), ''[]''::jsonb)
                                        from (select sb.source_id from cma.subscription sb join sm on sm.connection_id = sb.connection_id
                                              where sb.tenant_id = $2 and sm.store_connection_id = x.connection_id and sb.customer_source_id = x.source_id
                                                and sb.source_deleted_at is null order by sb.source_id limit 20) q))';
    when 'subscriptions' then
      -- measured against the tenant's today (the age bands); devices_on_holding's records are the device-holding
      -- subscriptions with a device in the field, each with its devices_in_field (they add up to the figure)
      v_base := 'cma.flash_subscriptions_of($2, $7)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'') and ($1 ->> ''payment_state'' is null or x.payment_state = $1 ->> ''payment_state'')
                  and ($1 ->> ''device_band'' is null or x.device_band = $1 ->> ''device_band'')
                  and ($1 ->> ''age_band'' is null or x.age_band = $1 ->> ''age_band'')
                  and case $1 ->> ''measure'' when ''active_subscriptions'' then x.is_active when ''paused_subscriptions'' then x.status = ''paused''
                                              when ''holding_subscriptions'' then x.is_holding
                                              when ''devices_on_holding'' then x.is_holding and x.devices_in_field > 0 else true end';
      v_obj := 'jsonb_build_object(''subscription_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market,
                  ''customer_id'', x.customer_source_id, ''contact_id'', x.contact_source_id,
                  ''contact_url'', cma.record_url(x.crm_connection_id, ''contact'', x.contact_source_id), ''status'', x.status,
                  ''payment_state'', x.payment_state, ''amount_per_cycle'', x.amount_per_cycle, ''currency'', x.currency,
                  ''billing_interval'', x.billing_interval, ''billing_interval_count'', x.billing_interval_count, ''next_billing_at'', x.next_billing_at,
                  ''retry_since'', x.retry_since, ''last_attempt'', x.last_attempt, ''devices'', x.devices, ''devices_in_field'', x.devices_in_field)';
    when 'installed_base' then
      -- the linked subscription's payment state for the list (0008zl's derivation, once per read): the figures need none
      v_base := '(select d.*, ps.payment_state as subscription_payment_state
                  from cma.flash_devices_of($2, $7) d
                  left join cma.subscription_payment_state_of($2) ps on ps.subscription_id = d.subscription_id)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and ($1 ->> ''model'' is null or x.model = $1 ->> ''model'') and ($1 ->> ''warehouse'' is null or x.warehouse = $1 ->> ''warehouse'')
                  and ($1 ->> ''link'' is null or x.link = $1 ->> ''link'')
                  and ($1 ->> ''subscription_status'' is null or x.subscription_status = $1 ->> ''subscription_status'')
                  and case $1 ->> ''measure'' when ''in_field'' then x.is_in_field when ''in_stock'' then x.is_in_stock
                                              when ''in_field_on_holding'' then x.is_in_field and x.subscription_status = any ($8)
                                              when ''components_past_due'' then x.past_due_items > 0 when ''items_due_3m'' then x.items_due_3m > 0
                                              else true end';
      v_obj := 'jsonb_build_object(''serial'', x.serial, ''device_id'', x.source_id, ''connection_id'', x.connection_id, ''model'', x.model,
                  ''market'', x.market, ''status'', x.status, ''in_field'', x.is_in_field, ''in_stock'', x.is_in_stock, ''warehouse'', x.warehouse,
                  ''refs'', x.refs, ''missing_refs'', to_jsonb(x.missing_refs), ''customer_id'', x.customer_ref, ''subscription_id'', x.subscription_ref,
                  ''link'', x.link, ''subscription_status'', x.subscription_status, ''subscription_payment_state'', x.subscription_payment_state,
                  ''past_due_items'', x.past_due_items, ''items_due_3m'', x.items_due_3m, ''next_due_on'', x.next_due_on,
                  ''record_url'', cma.record_url(x.connection_id, ''device'', x.source_id))';
    when 'churn' then
      v_base := 'cma.flash_churn_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''reason'' is null or x.reason = $1 ->> ''reason'')';
      v_obj := 'jsonb_build_object(''subscription_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market,
                  ''customer_id'', x.customer_source_id, ''churned_at'', x.churned_at, ''business_date'', x.business_date, ''reason'', x.reason,
                  ''cycles'', x.cycles)';
    when 'orders' then
      v_base := 'cma.flash_orders_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''kind'' is null or x.kind = $1 ->> ''kind'') and ($1 ->> ''sku'' is null or ($1 ->> ''sku'') = any (x.skus))';
      v_obj := 'jsonb_build_object(''order_number'', x.order_number, ''order_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store,
                  ''market'', x.market, ''created_at'', x.created_at, ''business_date'', x.business_date, ''kind'', x.kind,
                  ''financial_status'', x.financial_status, ''fulfillment_status'', x.fulfillment_status, ''skus'', to_jsonb(x.skus),
                  ''units'', x.units, ''total'', x.total, ''currency'', x.currency, ''customer_id'', x.customer_source_id)';
    when 'payments' then
      v_base := 'cma.flash_payments_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''kind'' is null or x.kind = $1 ->> ''kind'') and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and case $1 ->> ''measure'' when ''orders'' then x.kind = ''order''
                                              when ''renewals'' then x.kind = ''renewal'' and x.status = ''renewed''
                                              when ''failed_renewals'' then x.kind = ''renewal'' and x.status = ''renew_failed'' else true end';
      v_obj := 'jsonb_build_object(''kind'', x.kind, ''status'', x.status, ''record_ref'', x.record_ref, ''cycle'', x.cycle, ''source_id'', x.source_id,
                  ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market, ''at'', x.at, ''business_date'', x.business_date,
                  ''amount'', x.amount, ''currency'', x.currency)';
    when 'open_deals' then
      v_base := 'cma.flash_deals_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''pipeline'' is null or x.pipeline = $1 ->> ''pipeline'')
                  and ($1 ->> ''stage'' is null or x.stage = $1 ->> ''stage'')';
      v_obj := 'jsonb_build_object(''record_id'', x.source_id, ''record_url'', cma.record_url(x.connection_id, ''deal'', x.source_id),
                  ''connection_id'', x.connection_id, ''pipeline'', x.pipeline, ''stage'', x.stage, ''market'', x.market, ''owner_ref'', x.owner_ref,
                  ''owner_linked'', x.owner_user_id is not null, ''created_at'', x.created_at, ''age_days'', x.age_days)';
    when 'open_tickets' then
      v_base := 'cma.flash_tickets_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''queue'' is null or x.queue = $1 ->> ''queue'')
                  and ($1 ->> ''stage'' is null or x.stage = $1 ->> ''stage'')';
      v_obj := 'jsonb_build_object(''record_id'', x.source_id, ''record_url'', cma.record_url(x.connection_id, ''ticket'', x.source_id),
                  ''connection_id'', x.connection_id, ''queue'', x.queue, ''stage'', x.stage, ''market'', x.market, ''owner_ref'', x.owner_ref,
                  ''owner_linked'', x.owner_user_id is not null, ''created_at'', x.created_at, ''age_days'', x.age_days)';
    when 'open_tasks' then
      v_base := 'cma.flash_tasks_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''type'' is null or x.type = $1 ->> ''type'')
                  and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and case $1 ->> ''measure'' when ''overdue'' then x.overdue else true end';
      v_obj := 'jsonb_build_object(''task_id'', x.source_id, ''task_url'', cma.record_url(x.connection_id, ''task'', x.source_id),
                  ''connection_id'', x.connection_id, ''type'', x.type, ''status'', x.status, ''market'', x.market, ''owner_ref'', x.owner_ref,
                  ''owner_linked'', x.owner_user_id is not null, ''due_at'', x.due_at, ''overdue'', x.overdue, ''record_type'', x.record_type,
                  ''record_id'', x.record_source_id,
                  ''record_url'', case when x.record_type is not null then cma.record_url(x.connection_id, x.record_type, x.record_source_id) end)';
    when 'reviews' then
      v_base := 'cma.flash_reviews_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''rating'' is null or x.stars::text = $1 ->> ''rating'')
                  and case $1 ->> ''measure'' when ''negative'' then x.is_negative else true end';
      v_obj := 'jsonb_build_object(''review_id'', x.source_id, ''review_url'', cma.record_url(x.connection_id, ''review'', x.source_id),
                  ''connection_id'', x.connection_id, ''channel'', x.channel, ''market'', x.market, ''rating'', x.rating, ''stars'', x.stars,
                  ''negative'', x.is_negative, ''submitted_at'', x.submitted_at, ''business_date'', x.business_date, ''link_level'', x.link_level)';
    when 'data_quality' then
      v_base := 'cma.flash_findings_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''check'' is null or x.check_key = $1 ->> ''check'')';
      v_obj := 'jsonb_build_object(''check'', x.check_key, ''object_type'', x.object_type, ''object_id'', x.object_id, ''connection_id'', x.connection_id,
                  ''value'', x.value, ''market'', x.market, ''fix_in'', x.fix_in, ''fix_adapter'', x.fix_adapter)
                  || cma.flash_finding_links_of($2, x.connection_id, x.object_type, x.object_id)';
  end case;
  execute format(
    'with sm as materialized (select * from cma.flash_subscription_stores_of($2)),
          f as materialized (select x.* from %s x where %s),
          p as materialized (select x.* from f x order by %s limit $3 offset $4),
          n as (select x.*, row_number() over (order by %s) as ord from p x)
     select jsonb_build_object(''total'', (select count(*) from f),
                               ''rows'', coalesce((select jsonb_agg(%s order by x.ord) from n x), ''[]''::jsonb))',
    v_base, v_where, v_order, v_order, v_obj)
    into v_res
    using p_filters, p_tenant_id, p_limit, p_offset, v_from, v_to, v_today, cma.flash_holding_statuses_of(p_tenant_id);
  return v_res;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. The document and the take
-- ---------------------------------------------------------------------------------------------
-- As 0008zn (122), with devices_per_holding_subscription never filled with 0 for a market without a row (a ratio of no
-- holding subscription is none), the settings the bands and segments follow (now's live, the snapshot run's as of a date,
-- null for a run taken before 0008zt), and the device-holding statuses and the statuses' meanings (now's, for the hints). An overview's document for an explicit tenant (no permission checked: the
-- reads check it). Live (p_as_of null): cma.flash_compute_of now, a flow over p_from to p_to (today when absent). A
-- snapshot (p_as_of a date): a stock overview as stored for that date (CMA02 without a succeeded snapshot), a flow summed
-- over the dates of p_from to p_to (as_of alone when absent) that have one (CMA02 when none has), the dates without one
-- listed. The totals are the {} row, or the market's row when p_market is given (zeros when the market has none); the
-- rows every other grouping set's, of that market only when given
create or replace function cma.flash_document_of(p_tenant_id uuid, p_overview text, p_market text, p_as_of date, p_from date, p_to date)
returns jsonb
language plpgsql stable
as $$
declare
  o          record;
  v_today    date := cma.tenant_today_of(p_tenant_id);
  v_from     date;
  v_to       date;
  v_mode     text;
  v_sources  jsonb;
  v_all      jsonb;
  v_dates    date[];
  v_missing  jsonb;
  v_version  text := cma.flash_definition_version(p_overview);
  v_total    jsonb;
  v_totals   jsonb;
  v_rows     jsonb;
  v_extra    jsonb := '{}'::jsonb;
  v_active   jsonb;
  -- the settings the figures followed: now's, or as of a date the snapshot run's (0008zt's three, absent from a run
  -- taken before them, read as null)
  v_run_settings jsonb;
begin
  select * into o from cma.flash_overviews() x where x.key = p_overview;
  if o.kind = 'flow' then
    v_from := coalesce(p_from, p_as_of, v_today);
    v_to := coalesce(p_to, p_as_of, v_today);
  end if;
  if p_as_of is null then
    v_mode := 'live';
    v_sources := cma.flash_sources_of(p_tenant_id);
    select coalesce(jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures) order by c.dims::text), '[]'::jsonb) into v_all
    from cma.flash_compute_of(p_tenant_id, p_overview, v_from, v_to) c;
  else
    v_mode := 'snapshot';
    select array_agg(r.snapshot_date order by r.snapshot_date) into v_dates
    from cma.flash_snapshot_run r
    where r.tenant_id = p_tenant_id and r.status = 'succeeded'
      and r.snapshot_date between coalesce(v_from, p_as_of) and coalesce(v_to, p_as_of);
    if v_dates is null then
      raise exception 'no Flash snapshot for %', case when o.kind = 'flow' then v_from || ' to ' || v_to else p_as_of::text end
        using errcode = 'CMA02';
    end if;
    select r.sources, r.settings into v_sources, v_run_settings from cma.flash_snapshot_run r
    where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date = v_dates[cardinality(v_dates)];
    select coalesce(jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures) order by c.dims::text), '[]'::jsonb) into v_all
    from cma.flash_snapshot_sum_of(p_tenant_id, p_overview, v_dates) c;
    select min(s.definition_version) into v_version from cma.flash_snapshot s
    where s.tenant_id = p_tenant_id and s.overview = p_overview and s.snapshot_date = any (v_dates);
    if o.kind = 'flow' then
      select coalesce(jsonb_agg(g::date order by g), '[]'::jsonb) into v_missing
      from generate_series(v_from, v_to, interval '1 day') g where not (g::date = any (v_dates));
      v_extra := v_extra || jsonb_build_object('days', jsonb_build_object('covered', cardinality(v_dates), 'missing', v_missing));
    end if;
  end if;

  -- the totals: the {} row, or the market's own row (zeros when the market has none); the rows of the other sets
  select r -> 'measures' into v_total from jsonb_array_elements(v_all) r where r -> 'dims' = '{}'::jsonb;
  if p_market is null then
    v_totals := v_total;
  else
    select r -> 'measures' into v_totals from jsonb_array_elements(v_all) r where r -> 'dims' = jsonb_build_object('market', p_market);
    if v_totals is null and v_total is not null then
      select jsonb_object_agg(e.key, case when jsonb_typeof(e.value) = 'object' then '{}'::jsonb else '0'::jsonb end) into v_totals
      from jsonb_each(v_total) e where e.key not in ('median_age_days', 'oldest_age_days', 'devices_per_holding_subscription');
    end if;
  end if;
  select coalesce(jsonb_agg(r order by (r -> 'dims')::text), '[]'::jsonb) into v_rows
  from jsonb_array_elements(v_all) r
  where r -> 'dims' <> '{}'::jsonb and (p_market is null or r -> 'dims' ->> 'market' = p_market);

  if p_overview = 'churn' then
    select coalesce(s.measures -> 'active_subscriptions', null) into v_active from cma.flash_snapshot s
    where s.tenant_id = p_tenant_id and s.overview = 'subscriptions' and s.snapshot_date = v_to
      and s.dims = case when p_market is null then '{}'::jsonb else jsonb_build_object('market', p_market) end;
    if v_active is null and exists (select 1 from cma.flash_snapshot_run r
                                    where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date = v_to) then
      v_active := '0'::jsonb;
    end if;
    if v_active is null and p_as_of is null and v_to >= v_today and (v_sources -> 'subscriptions' ->> 'set_up')::boolean then
      select to_jsonb(count(*)) into v_active from cma.flash_subscriptions_of(p_tenant_id) s
      where s.is_active and (p_market is null or s.market = p_market);
    end if;
    v_extra := v_extra || jsonb_build_object('active_at_end', v_active);
  elsif p_overview = 'data_quality' then
    v_extra := v_extra || jsonb_build_object('history', coalesce((
      select jsonb_agg(jsonb_build_object('date', s.snapshot_date, 'check', s.dims ->> 'check', 'findings', s.measures -> 'findings')
                       order by s.snapshot_date, s.dims ->> 'check')
      from cma.flash_snapshot s
      where s.tenant_id = p_tenant_id and s.overview = 'data_quality'
        and s.snapshot_date in (select r.snapshot_date from cma.flash_snapshot_run r
                                where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date <= coalesce(p_as_of, v_today)
                                order by r.snapshot_date desc limit 30)
        and s.dims ? 'check'
        and s.dims = case when p_market is null then jsonb_build_object('check', s.dims ->> 'check')
                          else jsonb_build_object('check', s.dims ->> 'check', 'market', p_market) end), '[]'::jsonb));
  end if;

  return jsonb_build_object(
    'overview', p_overview, 'kind', o.kind, 'mode', v_mode,
    'as_of', case when v_mode = 'live' then to_jsonb(now()) else to_jsonb(p_as_of) end,
    'from', v_from, 'to', v_to, 'market', p_market,
    'source', o.source,
    'set_up', case when o.source is null then true else coalesce((v_sources -> o.source ->> 'set_up')::boolean, false) end,
    'sources', v_sources,
    'totals', v_totals, 'rows', v_rows,
    'definition_version', v_version, 'headline', o.headline, 'dims', to_jsonb(o.dims), 'sets', o.sets, 'measures', to_jsonb(o.measures),
    'count_measures', to_jsonb(o.count_measures), 'sorts', to_jsonb(o.sorts),
    'labels', cma.flash_labels_of(p_tenant_id, p_overview),
    'settings', jsonb_build_object(
      'active_subscription_statuses', to_jsonb(cma.flash_active_statuses_of(p_tenant_id)),
      'ended_subscription_statuses', to_jsonb(cma.flash_ended_statuses_of(p_tenant_id)),
      'required_contact_refs', to_jsonb(cma.flash_list_of(cma.setting_of(p_tenant_id, 'commerce.required_contact_refs'))),
      'required_device_refs', to_jsonb(cma.flash_list_of(cma.setting_of(p_tenant_id, 'assets.required_refs'))),
      'negative_max_rating', cma.setting_of(p_tenant_id, 'reviews.negative_max_rating')::integer,
      'file_max_rows', cma.setting_of(p_tenant_id, 'flash.file_max_rows')::integer,
      'device_bands', case when p_as_of is null then to_jsonb(cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.device_bands')))
                           when v_run_settings ? 'flash.device_bands' then to_jsonb(cma.flash_bounds_of(v_run_settings ->> 'flash.device_bands')) end,
      'subscription_age_months', case when p_as_of is null then to_jsonb(cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.subscription_age_months')))
                                      when v_run_settings ? 'flash.subscription_age_months'
                                      then to_jsonb(cma.flash_bounds_of(v_run_settings ->> 'flash.subscription_age_months')) end,
      'customer_segments', case when p_as_of is null then to_jsonb(cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments')))
                                when v_run_settings ? 'crm.customer_segments' then to_jsonb(cma.flash_list_of(v_run_settings ->> 'crm.customer_segments')) end)
      -- the statuses the figures count and their meanings, for the hints (now's: cma.flash_status_settings_of)
      || (cma.flash_status_settings_of(p_tenant_id) - 'active_subscription_statuses' - 'ended_subscription_statuses'),
    'first_snapshot_date', (select min(r.snapshot_date) from cma.flash_snapshot_run r where r.tenant_id = p_tenant_id and r.status = 'succeeded'),
    'today', cma.tenant_today_of(p_tenant_id), 'time_zone', (select t.timezone from cma.tenant t where t.id = p_tenant_id))
    || v_extra;
end
$$;

-- As 0008zn (122), with the three settings of 0008zt among those the run records (the bands and segments the figures
-- followed); the owner's alone (section 9). The take of the latest due business date as of p_now, see 0008zn
create or replace function cma.flash_snapshot_take_at(p_tenant_id uuid, p_now timestamptz)
returns jsonb
language plpgsql
as $$
declare
  v_zone     text;
  v_time     time;
  v_date     date;
  v_due      timestamptz;
  v_late     boolean;
  v_run      uuid := uuidv7();
  v_started  timestamptz := clock_timestamp();
  v_counts   jsonb := '{}'::jsonb;
  v_sources  jsonb;
  v_settings jsonb;
  v_missed   integer := 0;
  v_recorded integer := 0;
  v_last     date;
  v_n        integer;
  v_expired  integer := 0;
  v_watch    jsonb := '{}'::jsonb;
  v_werr     text;
  r          record;
  o          record;
begin
  -- the scheduler's own permission first, so a caller without it leaves no run row behind
  perform cma.assert_permission('flash.snapshot');
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a Flash snapshot is taken for the current tenant only' using errcode = 'CMA06';
  end if;
  -- an instant other than now is the owner's alone (123): the application can never write a date that has not ended
  if p_now is null or (p_now is distinct from now() and current_user <> 'cma_owner') then
    raise exception 'a Flash snapshot is taken as of now' using errcode = 'CMA06';
  end if;
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  v_time := cma.setting_of(p_tenant_id, 'flash.snapshot_local_time')::time;
  v_date := cma.flash_due_date_of(v_zone, v_time, p_now);
  v_due := cma.flash_due_at_of(v_zone, v_time, v_date);
  v_late := p_now > v_due + interval '1 hour';
  perform pg_advisory_xact_lock(hashtextextended(p_tenant_id::text || '/flash_snapshot', 0));
  select x.id, x.started_at, x.counts into r from cma.flash_snapshot_run x
  where x.tenant_id = p_tenant_id and x.snapshot_date = v_date and x.status = 'succeeded';
  if found then
    -- taken already: the run's own counts come back, so a job whose first answer was lost reports what it stored
    return jsonb_build_object('taken', false, 'reason', 'taken', 'date', v_date, 'run_id', r.id, 'run_started_at', r.started_at,
                              'stored', r.counts);
  end if;
  if exists (select 1 from cma.flash_snapshot_run x where x.tenant_id = p_tenant_id and x.snapshot_date = v_date and x.status = 'missed') then
    return jsonb_build_object('taken', false, 'reason', 'missed', 'date', v_date);
  end if;
  -- 1. the dates missed before it, recorded once
  select max(x.snapshot_date) into v_last from cma.flash_snapshot_run x
  where x.tenant_id = p_tenant_id and x.status in ('succeeded', 'missed') and x.snapshot_date < v_date;
  if v_last is not null and v_last < v_date - 1 then
    insert into cma.flash_snapshot_run (tenant_id, snapshot_date, due_at, started_at, finished_at, status)
    select p_tenant_id, g.d, cma.flash_due_at_of(v_zone, v_time, g.d), v_started, v_started, 'missed'
    from (select x::date as d from generate_series(v_last + 1, v_date - 1, interval '1 day') x) g;
    get diagnostics v_recorded = row_count;
  end if;
  select max(x.snapshot_date) into v_last from cma.flash_snapshot_run x
  where x.tenant_id = p_tenant_id and x.status = 'succeeded' and x.snapshot_date < v_date;
  v_missed := case when v_last is null then 0 else v_date - v_last - 1 end;
  v_sources := cma.flash_sources_of(p_tenant_id);
  v_settings := jsonb_build_object(
    'flash.active_subscription_statuses', cma.setting_of(p_tenant_id, 'flash.active_subscription_statuses'),
    'flash.ended_subscription_statuses', cma.setting_of(p_tenant_id, 'flash.ended_subscription_statuses'),
    'commerce.required_contact_refs', cma.setting_of(p_tenant_id, 'commerce.required_contact_refs'),
    'assets.required_refs', cma.setting_of(p_tenant_id, 'assets.required_refs'),
    'flash.watch_jump_pct', cma.setting_of(p_tenant_id, 'flash.watch_jump_pct'),
    'flash.watch_jump_min', cma.setting_of(p_tenant_id, 'flash.watch_jump_min'),
    'flash.snapshot_local_time', to_char(v_time, 'HH24:MI'),
    'reviews.negative_max_rating', cma.setting_of(p_tenant_id, 'reviews.negative_max_rating'),
    'flash.device_bands', cma.setting_of(p_tenant_id, 'flash.device_bands'),
    'flash.device_holding_statuses', cma.setting_of(p_tenant_id, 'flash.device_holding_statuses'),
    'flash.subscription_age_months', cma.setting_of(p_tenant_id, 'flash.subscription_age_months'),
    'crm.customer_segments', cma.setting_of(p_tenant_id, 'crm.customer_segments'),
    'timezone', v_zone);
  begin
    -- 2. the figures (stock measured against the date), the id lists, the expiry
    for o in select x.key from cma.flash_overviews() x order by x.sort_order loop
      insert into cma.flash_snapshot (tenant_id, snapshot_date, overview, dims, measures, definition_version, computed_at, run_id)
      select p_tenant_id, v_date, o.key, c.dims, c.measures, cma.flash_definition_version(o.key), now(), v_run
      from cma.flash_compute_of(p_tenant_id, o.key, v_date, v_date, v_date) c;
      get diagnostics v_n = row_count;
      v_counts := v_counts || jsonb_build_object(o.key, v_n);
    end loop;
    if v_date = (date_trunc('month', v_date) + interval '1 month - 1 day')::date then
      v_counts := v_counts || cma.flash_snapshot_ids_write_of(p_tenant_id, v_date, v_run);
    end if;
    v_expired := cma.flash_snapshot_ids_expire_of(p_tenant_id);
    -- 3. the watch, in a subtransaction of its own: its error is recorded, the figures stay
    begin
      v_watch := cma.flash_watch_of(p_tenant_id, v_date, p_now);
    exception when others then
      v_werr := sqlstate;
      v_watch := '{}'::jsonb;
    end;
    -- 4. the run row
    insert into cma.flash_snapshot_run (id, tenant_id, snapshot_date, due_at, started_at, finished_at, status, late, counts, sources, settings,
                                        missed_before, watch_error)
    values (v_run, p_tenant_id, v_date, v_due, v_started, clock_timestamp(), 'succeeded', v_late,
            v_counts || jsonb_build_object('ids_expired', v_expired) || v_watch, v_sources, v_settings, v_missed, v_werr);
  exception when others then
    -- the subtransaction's rows are gone (the missed dates of step 1 stay): the run says failed with the error's code
    -- (never its message, which may hold values)
    insert into cma.flash_snapshot_run (tenant_id, snapshot_date, due_at, started_at, finished_at, status, late, counts, sources, settings,
                                        missed_before, error)
    values (p_tenant_id, v_date, v_due, v_started, clock_timestamp(), 'failed', v_late, '{}'::jsonb, coalesce(v_sources, '{}'::jsonb),
            coalesce(v_settings, '{}'::jsonb), v_missed, sqlstate);
    return jsonb_build_object('taken', false, 'reason', 'failed', 'date', v_date, 'due_at', v_due, 'late', v_late, 'error', sqlstate,
                              'missed_recorded', v_recorded);
  end;
  return jsonb_build_object('taken', true, 'date', v_date, 'run_id', v_run, 'due_at', v_due, 'late', v_late, 'missed_before', v_missed,
                            'missed_recorded', v_recorded, 'duration_ms', round(extract(epoch from clock_timestamp() - v_started) * 1000))
         || v_counts || v_watch || jsonb_build_object('ids_expired', v_expired)
         || case when v_werr is not null then jsonb_build_object('watch_error', v_werr) else '{}'::jsonb end;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Data quality: the holding subscriptions without a device, the devices in the field on a subscription that holds none
-- ---------------------------------------------------------------------------------------------
-- As 0008zn's (122), with active_subscription_without_device reading the device-holding statuses (the key kept) and the
-- seventh check, field_device_on_non_holding_subscription (0008zt)
create or replace function cma.data_quality_flash_checks()
returns table (check_key text, sort_order integer, description text)
language sql immutable
as $$
  values
    ('customer_required_ref_missing',            310, 'Store customers with an order whose CRM contact lacks a required reference, with the references missing'),
    ('device_required_ref_missing',              320, 'Devices lacking a required named id, with the ids missing'),
    ('subscription_customer_unmatched',          330, 'Subscriptions whose customer id no customer of their store holds'),
    ('active_subscription_without_device',       340, 'Subscriptions in a device-holding status (flash.device_holding_statuses) that no device''s subscription reference names'),
    ('device_subscription_ref_unknown',          350, 'Devices in the field whose subscription reference names no subscription the CMA holds'),
    ('field_device_on_ended_subscription',       360, 'Devices in the field linked to a subscription in an ended status (flash.ended_subscription_statuses), with its status'),
    ('field_device_on_non_holding_subscription', 370, 'Devices in the field linked to a subscription in a status that is neither device-holding nor ended (flash.device_holding_statuses, flash.ended_subscription_statuses), with its status')
$$;

-- As 0008zn (122), with the two checks of 0008zt: subscriptions in a device-holding status without a device (the key
-- active_subscription_without_device kept), and devices in the field on a subscription whose status neither holds devices
-- nor is ended (an ended one is field_device_on_ended_subscription's, so no device is listed twice). Every other check as
-- before; the stored results (0008zr) take them at the next refresh
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
  -- (since 0008zn the contacts per id counted once by a join, no read per customer; the same rows)
  select case when coalesce(h.contacts, 0) = 0 then 'commerce_unmatched' else 'commerce_ambiguous' end,
         cu.connection_id, 'commerce_customer', cu.source_id, null
  from cma.commerce_customer cu
  left join (select r.system, r.external_id, count(distinct r.contact_id) as contacts
             from cma.crm_contact_ref r where r.tenant_id = p_tenant_id group by 1, 2) h
    on h.system = cu.source_system and h.external_id = cu.source_id
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null and coalesce(h.contacts, 0) <> 1
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
                    where not (a.v = any (ff.options || ff.retired_options))))
  union all
  -- review channels the source holds without a market (0008ze), with how many reviews the CMA holds of each
  select 'review_channel_unmapped', ch.connection_id, 'review_channel', ch.source_id,
         (select count(*) from cma.review r where r.tenant_id = ch.tenant_id and r.review_channel_id = ch.id)::text
  from cma.review_channel ch
  where ch.tenant_id = p_tenant_id and ch.source_deleted_at is null and ch.market is null
  union all
  -- active markets without a counted review channel, once the tenant has a reviews connection (0008ze)
  select 'market_without_review_channel', null::uuid, 'market', m.code, null::text
  from cma.market m
  where m.tenant_id = p_tenant_id and m.status = 'active' and cma.reviews_set_up_of(p_tenant_id)
    and not exists (select 1 from cma.review_channel ch
                    where ch.tenant_id = m.tenant_id and ch.market = m.code and ch.is_counted and ch.source_deleted_at is null)
  union all
  -- devices without a serial number (0008zi), of devices the register still holds
  select 'device_serial_missing', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.serial is null
  union all
  -- devices whose serial number another device of the tenant holds too (0008zi); the value is the serial
  select 'device_serial_duplicate', dv.connection_id, 'device', dv.source_id, dv.serial
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.serial is not null
    and exists (select 1 from cma.device o
                where o.tenant_id = dv.tenant_id and o.serial = dv.serial and o.id <> dv.id and o.source_deleted_at is null)
  union all
  -- devices whose model, status or country maps to no catalog row (0008zi); the value is the register's label
  select 'device_model_unmapped', dv.connection_id, 'device', dv.source_id, dv.raw ->> 'model'
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.model_key is null
  union all
  select 'device_status_unmapped', dv.connection_id, 'device', dv.source_id, dv.raw ->> 'status'
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.device_status_key is null
  union all
  select 'device_market_unmapped', dv.connection_id, 'device', dv.source_id, dv.raw ->> 'country'
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.market is null
  union all
  -- devices whose register customer reference is no id (0008zi): the reference is never stored, so no value
  select 'device_customer_ref_invalid', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.customer_ref_invalid
  union all
  -- due items of tracked devices without a due date (basis unknown, 0008zi); the value is the component kind
  select 'component_due_unknown', i.connection_id, 'device', i.source_id, i.component_key
  from cma.maintenance_items_of(p_tenant_id, cma.tenant_today_of(p_tenant_id)) i
  where i.basis = 'unknown'
  union all
  -- devices in a status in the field without a subscription reference (0008zi)
  select 'field_device_without_subscription_ref', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is null
  union all
  -- store customers with an order linked to a CRM contact that lacks a reference of commerce.required_contact_refs in
  -- every slot (0008zn); the value the references missing, comma-separated; contact_deleted when the CRM deleted the
  -- contact the link names (fixed in the CRM: the link or the contact); contact_not_held while the CMA does not hold the
  -- contact (its references are unknown until the contact is read)
  select 'customer_required_ref_missing', cu.connection_id, 'commerce_customer', cu.source_id,
         case when k.id is null then 'contact_not_held'
              when k.source_deleted_at is not null then 'contact_deleted'
              else array_to_string(array(select x from unnest(rq.refs) x
                                         where not exists (select 1 from cma.crm_contact_ref cr
                                                           where cr.tenant_id = k.tenant_id and cr.contact_id = k.id and cr.system = x)), ',') end
  from cma.commerce_customer cu
  cross join (select cma.flash_list_of(cma.setting_of(p_tenant_id, 'commerce.required_contact_refs')) as refs offset 0) rq
  left join cma.crm_contact k
    on k.tenant_id = cu.tenant_id and k.connection_id = cu.crm_connection_id and k.source_id = cu.crm_contact_source_id
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null and cu.crm_contact_source_id is not null
    and coalesce(cu.orders_count, 0) >= 1 and cardinality(rq.refs) > 0
    and (k.id is null or k.source_deleted_at is not null
         or exists (select 1 from unnest(rq.refs) x
                    where not exists (select 1 from cma.crm_contact_ref cr
                                      where cr.tenant_id = k.tenant_id and cr.contact_id = k.id and cr.system = x)))
  union all
  -- devices the register still holds lacking a named id of assets.required_refs (0008zn); the value the ids missing
  select 'device_required_ref_missing', dv.connection_id, 'device', dv.source_id,
         array_to_string(array(select x from unnest(rq.refs) x where not (dv.external_refs ? x)), ',')
  from cma.device dv
  cross join (select cma.flash_list_of(cma.setting_of(p_tenant_id, 'assets.required_refs')) as refs offset 0) rq
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and cardinality(rq.refs) > 0
    and exists (select 1 from unnest(rq.refs) x where not (dv.external_refs ? x))
  union all
  -- subscriptions the latest full read still returns whose customer id no customer of their store holds (0008zn)
  select 'subscription_customer_unmatched', sb.connection_id, 'subscription', sb.source_id, null::text
  from cma.subscription sb
  -- the mapping fenced (offset 0): inlined, the planner guesses its few rows wrong and probes the customers per row
  join (select x.connection_id, x.store_connection_id from cma.flash_subscription_stores_of(p_tenant_id) x offset 0) sm
    on sm.connection_id = sb.connection_id
  left join (select cu.connection_id, cu.source_id from cma.commerce_customer cu
             where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null) cu
    on cu.connection_id = sm.store_connection_id and cu.source_id = sb.customer_source_id
  where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null and sb.customer_source_id is not null and cu.source_id is null
  union all
  -- subscriptions in a device-holding status (flash.device_holding_statuses since 0008zt; the key keeps 0008zn's word) of
  -- a store whose market the register holds devices of, that no device of that market the register still holds names by
  -- its subscription reference, once the tenant has an asset register set up; the value the status. A market without any
  -- device in the register (one it does not cover yet) gives no finding
  select 'active_subscription_without_device', sb.connection_id, 'subscription', sb.source_id, sb.status
  from cma.subscription sb
  join (select x.connection_id, x.market from cma.flash_subscription_stores_of(p_tenant_id) x offset 0) sm on sm.connection_id = sb.connection_id
  left join (select distinct d.market, d.subscription_ref from cma.device d
             where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.subscription_ref is not null) dr
    on dr.subscription_ref = sb.source_id and dr.market = sm.market
  where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null and dr.subscription_ref is null
    and sb.status = any (cma.flash_holding_statuses_of(p_tenant_id)) and cma.assets_set_up_of(p_tenant_id)
    -- the register's markets, once (a set, never a read per subscription)
    and sm.market in (select distinct d.market from cma.device d where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.market is not null)
  union all
  -- devices in a status in the field, of a market whose store's subscriptions the CMA reads, whose subscription
  -- reference names no subscription the CMA holds of that market (0008zn)
  select 'device_subscription_ref_unknown', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  -- the subscriptions the CMA holds per market of their store, once (a set joined, never a read per device)
  left join (select distinct sm.market, sb.source_id
             from cma.subscription sb
             join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = sb.connection_id
             where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null) held
    on held.market = dv.market and held.source_id = dv.subscription_ref
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
    and dv.market in (select sm.market from cma.flash_subscription_stores_of(p_tenant_id) sm)
    and held.source_id is null
  union all
  -- devices in a status in the field linked to a subscription of their market in a status of
  -- flash.ended_subscription_statuses (0008zn); the value the subscription's status (the first by status when two
  -- subscriptions of the market share the id)
  select 'field_device_on_ended_subscription', dv.connection_id, 'device', dv.source_id, sb.status
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  join (select sm.market, x.source_id, min(x.status) as status
        from cma.subscription x
        join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = x.connection_id
        where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.status = any (cma.flash_ended_statuses_of(p_tenant_id))
        group by 1, 2) sb on sb.source_id = dv.subscription_ref and sb.market = dv.market
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
  union all
  -- devices in a status in the field linked to a subscription of their market whose status is neither a device-holding
  -- one nor an ended one (0008zt: for Pulse4all paused, merged and never-subscribed; an ended one is the check above, so
  -- no device is listed twice); the value the subscription's status (the device's own subscription, as the installed base
  -- links it: the first by id when two subscriptions of the market share the id)
  select 'field_device_on_non_holding_subscription', dv.connection_id, 'device', dv.source_id, sb.status
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  join (select distinct on (sm.market, x.source_id) sm.market, x.source_id, x.status
        from cma.subscription x
        join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = x.connection_id
        where x.tenant_id = p_tenant_id and x.source_deleted_at is null
        order by sm.market, x.source_id, x.id) sb on sb.source_id = dv.subscription_ref and sb.market = dv.market
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
    and not (sb.status = any (cma.flash_holding_statuses_of(p_tenant_id))) and not (sb.status = any (cma.flash_ended_statuses_of(p_tenant_id)));

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


-- As 0008zr's (132), with the seventh Flash check listed once the subscriptions and the register are set up
create or replace function cma.data_quality()
returns table (check_key text, description text, total integer)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'tenant.configure']);
  perform cma.data_quality_snapshot_of(v_tenant);
  return query
    with q as materialized (select f.check_key, count(*)::integer as n from cma.data_quality_finding f where f.tenant_id = v_tenant group by 1),
    c as (
      select dc.check_key, dc.sort_order, dc.description from cma.data_quality_checks() dc
      union all
      select ac.check_key, ac.sort_order, ac.description from cma.data_quality_added_checks() ac
      where ac.check_key = 'contact_country_fallback'
        and (exists (select 1 from cma.connection_field cf
                     where cf.tenant_id = v_tenant and cf.entity = 'contact' and cf.field = 'country' and cf.slot > 1)
             or exists (select 1 from q where q.check_key = ac.check_key))
      union all
      select fc.check_key, fc.sort_order, fc.description from cma.data_quality_follow_up_checks() fc
      where (fc.check_key in ('ticket_no_owner', 'ticket_no_market')
             and (cma.follow_up_configured_of(v_tenant) or exists (select 1 from q where q.check_key = fc.check_key)))
         or (fc.check_key = 'crm_task_owner_unlinked'
             and (exists (select 1 from cma.crm_task k where k.tenant_id = v_tenant) or exists (select 1 from q where q.check_key = fc.check_key)))
      union all
      select xc.check_key, xc.sort_order, xc.description from cma.data_quality_forms_checks() xc
      where exists (select 1 from q where q.check_key = xc.check_key)
         or exists (select 1 from cma.connection_form f
                    where f.tenant_id = v_tenant and f.fields_refreshed_at is not null and cardinality(f.kept_fields) > 0)
      union all
      select rc.check_key, rc.sort_order, rc.description from cma.data_quality_reviews_checks() rc
      where cma.reviews_set_up_of(v_tenant) or exists (select 1 from q where q.check_key = rc.check_key)
      union all
      select sc.check_key, sc.sort_order, sc.description from cma.data_quality_assets_checks() sc
      where cma.assets_set_up_of(v_tenant) or exists (select 1 from q where q.check_key = sc.check_key)
      union all
      select fc.check_key, fc.sort_order, fc.description from cma.data_quality_flash_checks() fc
      cross join (select cma.flash_sources_of(v_tenant) as src offset 0) s
      where exists (select 1 from q where q.check_key = fc.check_key)
         or (fc.check_key = 'customer_required_ref_missing' and (s.src -> 'commerce' ->> 'set_up')::boolean
             and cardinality(cma.flash_list_of(cma.setting_of(v_tenant, 'commerce.required_contact_refs'))) > 0)
         or (fc.check_key = 'device_required_ref_missing' and (s.src -> 'assets' ->> 'set_up')::boolean
             and cardinality(cma.flash_list_of(cma.setting_of(v_tenant, 'assets.required_refs'))) > 0)
         or (fc.check_key = 'subscription_customer_unmatched' and (s.src -> 'subscriptions' ->> 'set_up')::boolean)
         or (fc.check_key in ('active_subscription_without_device', 'device_subscription_ref_unknown', 'field_device_on_ended_subscription',
                              'field_device_on_non_holding_subscription')
             and (s.src -> 'subscriptions' ->> 'set_up')::boolean and (s.src -> 'assets' ->> 'set_up')::boolean)
    )
    select c.check_key, c.description,
           case when c.check_key = 'writeback_parked' and to_regclass('cma.outbox_action') is null then null
                else coalesce((select q.n from q where q.check_key = c.check_key), 0) end
    from c
    order by c.sort_order;
end
$$;


-- As 0008zn's (122), with the seventh check fixed in the asset register (the device's status or reference)
create or replace function cma.data_quality_fix_in(p_check_key text, p_value text)
returns text
language sql immutable
as $$
  select case
    -- a contact not held yet is the CMA's to read; a deleted contact or a missing reference is the CRM's to fix
    when p_check_key = 'customer_required_ref_missing' then case when p_value = 'contact_not_held' then 'cma' else 'crm' end
    when p_check_key in ('deal_without_contact', 'deal_contact_incomplete', 'crm_call_without_contact', 'commerce_unmatched',
                         'commerce_ambiguous', 'contact_slots_full', 'contact_country_differs', 'contact_country_fallback',
                         'ticket_no_owner', 'ticket_no_market', 'telephony_call_unlinked') then 'crm'
    when p_check_key in ('customer_in_two_stores', 'subscription_customer_unmatched') then 'commerce'
    when p_check_key in ('device_serial_missing', 'device_serial_duplicate', 'device_model_unmapped', 'device_status_unmapped',
                         'device_market_unmapped', 'device_customer_ref_invalid', 'component_due_unknown',
                         'field_device_without_subscription_ref', 'device_required_ref_missing', 'active_subscription_without_device',
                         'device_subscription_ref_unknown', 'field_device_on_ended_subscription', 'field_device_on_non_holding_subscription') then 'assets'
    else 'cma' end
$$;


-- The seventh check's reader view, as 0008zn's six (ids and codes only)
create or replace view cma_read.dq_field_device_on_non_holding_subscription as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'field_device_on_non_holding_subscription';

-- ---------------------------------------------------------------------------------------------
-- 10. The landing: the statuses and their meanings for the cards' hints
-- ---------------------------------------------------------------------------------------------
-- As 0008zn (122), with settings: the active, the device-holding and the ended statuses and subscription.status_meanings
-- (cma.flash_status_settings_of), as cma.flash_overview's document gives them, so the landing's cards explain their
-- figures with the tenant's own words
create or replace function cma.flash_page(p_market text default null, p_as_of date default null, p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_today    date;
  v_from     date;
  v_to       date;
  v_len      integer;
  v_sources  jsonb;
  v_cards    jsonb := '[]'::jsonb;
  o          record;
  v_value    jsonb;
  v_prev     jsonb;
  v_prev_on  date;
  v_dates    date[];
  v_set_up   boolean;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  v_today := cma.tenant_today_of(v_tenant);
  perform cma.assert_flash_params(p_market, p_as_of, p_from, p_to, v_today);
  v_from := coalesce(p_from, p_as_of, v_today);
  v_to := coalesce(p_to, p_as_of, v_today);
  v_len := v_to - v_from + 1;
  if p_as_of is null then
    v_sources := cma.flash_sources_of(v_tenant);
  else
    select r.sources into v_sources from cma.flash_snapshot_run r
    where r.tenant_id = v_tenant and r.snapshot_date = p_as_of and r.status = 'succeeded';
    if v_sources is null then
      return jsonb_build_object('mode', 'snapshot', 'as_of', p_as_of, 'market', p_market, 'snapshot_missing', true,
        'nearest_before', (select max(r.snapshot_date) from cma.flash_snapshot_run r
                           where r.tenant_id = v_tenant and r.status = 'succeeded' and r.snapshot_date < p_as_of),
        'nearest_after', (select min(r.snapshot_date) from cma.flash_snapshot_run r
                          where r.tenant_id = v_tenant and r.status = 'succeeded' and r.snapshot_date > p_as_of),
        'first_snapshot_date', (select min(r.snapshot_date) from cma.flash_snapshot_run r where r.tenant_id = v_tenant and r.status = 'succeeded'),
        'overviews', '[]'::jsonb, 'watch', '[]'::jsonb, 'markets', '[]'::jsonb,
        'today', cma.tenant_today_of(v_tenant), 'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant),
        'settings', cma.flash_status_settings_of(v_tenant));
    end if;
  end if;
  for o in select * from cma.flash_overviews() x order by x.sort_order loop
    v_set_up := o.source is null or coalesce((v_sources -> o.source ->> 'set_up')::boolean, false);
    v_value := null; v_prev := null; v_prev_on := null;
    if v_set_up then
      if p_as_of is not null then
        select array_agg(r.snapshot_date) into v_dates from cma.flash_snapshot_run r
        where r.tenant_id = v_tenant and r.status = 'succeeded'
          and r.snapshot_date between case when o.kind = 'flow' then v_from else p_as_of end and case when o.kind = 'flow' then v_to else p_as_of end;
        v_value := cma.flash_stored_headline_of(v_tenant, o.key, p_market, v_dates);
      end if;
      if o.kind = 'stock' then
        select max(r.snapshot_date) into v_prev_on from cma.flash_snapshot_run r
        where r.tenant_id = v_tenant and r.status = 'succeeded' and r.snapshot_date < coalesce(p_as_of, v_today);
        if v_prev_on is not null then
          v_prev := cma.flash_stored_headline_of(v_tenant, o.key, p_market, array[v_prev_on]);
        end if;
      else
        select array_agg(r.snapshot_date) into v_dates from cma.flash_snapshot_run r
        where r.tenant_id = v_tenant and r.status = 'succeeded' and r.snapshot_date between v_from - v_len and v_from - 1;
        if coalesce(cardinality(v_dates), 0) = v_len then
          v_prev_on := v_from - 1;
          v_prev := cma.flash_stored_headline_of(v_tenant, o.key, p_market, v_dates);
        end if;
      end if;
    end if;
    v_cards := v_cards || jsonb_build_array(jsonb_build_object(
      'key', o.key, 'kind', o.kind, 'source', o.source, 'set_up', v_set_up, 'headline', o.headline, 'value', v_value,
      'previous', v_prev, 'previous_on', v_prev_on, 'definition_version', cma.flash_definition_version(o.key)));
  end loop;
  return jsonb_build_object(
    'mode', case when p_as_of is null then 'live' else 'snapshot' end,
    'as_of', case when p_as_of is null then to_jsonb(now()) else to_jsonb(p_as_of) end,
    'from', v_from, 'to', v_to, 'market', p_market, 'snapshot_missing', false,
    'sources', v_sources, 'overviews', v_cards,
    'markets', (select coalesce(jsonb_agg(jsonb_build_object('code', m.code, 'name', m.name) order by m.sort_order, m.code), '[]'::jsonb)
                from cma.market m where m.tenant_id = v_tenant and m.status = 'active'),
    'watch', (select coalesce(jsonb_agg(jsonb_build_object('kind', f.kind, 'overview', f.overview, 'dims', f.dims, 'measure', f.measure,
                                                           'value', f.value, 'previous', f.previous, 'threshold', f.threshold, 'detail', f.detail,
                                                           'snapshot_date', f.snapshot_date)
                                        order by f.snapshot_date desc, f.kind, f.overview, f.dims::text), '[]'::jsonb)
              from cma.flash_watch_finding f where f.tenant_id = v_tenant and f.state = 'open'),
    'first_snapshot_date', (select min(r.snapshot_date) from cma.flash_snapshot_run r where r.tenant_id = v_tenant and r.status = 'succeeded'),
    'last_snapshot_date', (select max(r.snapshot_date) from cma.flash_snapshot_run r where r.tenant_id = v_tenant and r.status = 'succeeded'),
    'today', cma.tenant_today_of(v_tenant), 'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant),
    'settings', cma.flash_status_settings_of(v_tenant));
end
$$;


-- ---------------------------------------------------------------------------------------------
-- 11. Grants and JIT: as 0008zn's (a function made again keeps its grants, not its settings; a dropped one keeps neither)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.flash_bounds_of(text)', 'cma.flash_count_band_of(integer,integer[])', 'cma.flash_count_bands_of(integer[])',
    'cma.flash_age_months_of(timestamptz,text,date)', 'cma.flash_age_band_of(integer,integer[])', 'cma.flash_age_bands_of(integer[])',
    'cma.flash_ratio_of(numeric,numeric)', 'cma.flash_segment_of(text,text[],text[])',
    'cma.flash_holding_statuses_of(uuid)', 'cma.flash_status_meanings_ok(text)', 'cma.flash_status_settings_of(uuid)',
    'cma.flash_overviews()', 'cma.flash_definition_version(text)',
    'cma.data_quality_flash_checks()', 'cma.data_quality_of(uuid)', 'cma.data_quality()', 'cma.data_quality_fix_in(text,text)',
    'cma.flash_page(text,date,date,date)',
    'cma.flash_store_customers_of(uuid)', 'cma.flash_customers_of(uuid)', 'cma.flash_subscriptions_of(uuid,date)', 'cma.flash_subscriptions_of(uuid)',
    'cma.flash_devices_of(uuid,date)',
    'cma.flash_compute_of(uuid,text,date,date,date)', 'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)',
    'cma.flash_document_of(uuid,text,text,date,date,date)', 'cma.ingest_upsert_contacts(uuid,jsonb)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- the take's writer: the owner's alone (the take runs it with the owner's rights)
  execute 'revoke execute on function cma.flash_snapshot_take_at(uuid,timestamptz) from public, cma_app';
  -- JIT off for the large reads and the take, as 0008zn (section 14 of 122)
  foreach f in array array[
    'cma.flash_compute_of(uuid,text,date,date,date)', 'cma.flash_document_of(uuid,text,text,date,date,date)',
    'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)', 'cma.flash_snapshot_take_at(uuid,timestamptz)',
    'cma.data_quality_of(uuid)'
  ] loop
    execute format('alter function %s set jit = off', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 12. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zt', 'Flash insights (brief B29 and its amendment): the installed base''s subscription_status (the linked subscription''s status, else not_found, else none) and in_field_on_holding; the device-holding subscriptions (flash.device_holding_statuses: holding_subscriptions, devices_on_holding, the list''s devices_in_field) and devices_per_holding_subscription (a ratio, two decimals, none without a holding subscription, never in the watch''s jump), device_band (flash.device_bands, of the holding subscriptions) and age_band (flash.subscription_age_months: whole months from the subscription app''s creation up to the business date, of the active ones) with every band''s row per market; data quality''s active_subscription_without_device on the holding statuses and field_device_on_non_holding_subscription; subscription.status_meanings and the statuses in cma.flash_page''s and the document''s settings; the customers'' segment from the linked contact''s mapped property (connection_field segment, cma.crm_contact.segment) when crm.customer_segments holds it, else unknown; the settings checked, none stripped of spaces; the three overviews'' definition 0008zt, live and in the snapshot one computation')
on conflict (version) do nothing;

commit;
reset role;
