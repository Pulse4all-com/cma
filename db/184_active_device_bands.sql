-- =============================================================================================
-- 184_active_device_bands.sql: addition 0009r, Customers → Active: the active customers by the devices they hold
-- (Devices per active customer), in bands, and one meaning of Devices on the page
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 178_job_reads.sql (0009o). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your
-- own IAM login: dev first, then 185_verify_active_device_bands.sql there (normal, then provoked), then the verifies
-- that read what this script re-creates:
--   173_verify_active_customers.sql and 175_verify_active_refresh_quiet.sql (both edited by this change: where 0009r is
--     recorded 173 expects the page's Devices as this script defines them and the list's new signatures, and 175
--     leaves the customers' devices and the stored documents out of its comparisons with 172's refresh; 185 compares
--     those with 174's);
--   177_verify_active_attribution_present.sql (not edited: it reads the refresh and the customers this script
--     re-creates; the channels, the tiles and its budgets are unchanged by the devices);
--   cma.check_tenant_setting() by name: 73_verify_follow_up.sql, 101_verify_definitions_calls.sql,
--     113_verify_assets.sql, 121_verify_lead_cohorts.sql, 123_verify_flash.sql, 137_verify_flash_insights.sql; through
--     its trigger: 27_verify_configuration.sql and 14_verify_tenant_settings.sql;
--   131_time_all.sql part b (its Active rows; edited: one row for the list under a band, a guard on 0009r).
-- Prod: this script and 185 before the merge of its pull request. Main's web runs unchanged on it: it calls
-- cma.active_rows and cma.active_file_record without the band, which still resolves, and reads documents that hold one
-- more part.
--
-- Why (Martin, 12 November 2026, brief B36; Decision log, 12 Nov 2026, "Customers → Active shows the active customers by
-- the devices they hold ..." and "Definitions: Devices per active customer ..."):
--   D1. Devices per active customer: the devices in the field on a customer's holding subscriptions (the asset
--       register's devices whose subscription reference is a holding subscription of the customer, in a status that
--       counts as in the field: what Flash counts as devices on holding subscriptions), per Active customer. A customer
--       with holding subscriptions and no such device is in band 0, never left out.
--       One meaning on the page (Martin, 12 November 2026): until now the page's Devices (the list's column, the
--       markets' Devices and Devices per customer, the comparison's row) counted the register's devices that carry the
--       customer's id, in any status (Flash's customer figure). From this script on they are this term: the take's
--       cma.active_customer.devices holds it. The stored base keeps Flash's figure (cma.active_base.customer_devices),
--       which no read of the page uses any more.
--   D2. The bands are the tenant setting customers.device_bands (default 1,2,3,6,11: 0, 1, 2, 3-5, 6-10, 11+).
--       "Customers with n or more devices" takes its n from the bands (Martin, 12 November 2026): the third bound, or
--       the last one of a shorter list, so the figure always adds up with the bars.
--   D3. The page's below-the-fold document gains the part device_customers; the markets and the comparison gain the
--       share of customers from n devices on (devices_from_share); the customer list takes a band as a filter.
--   D4. Everything is read from the stored take; no new source read (the devices in the field per subscription are in
--       cma.active_base since 0009l). No table, view or column is added or changed.
--
-- What it adds
--   setting    customers.device_bands (1,2,3,6,11): one to eight increasing whole numbers from 1, each at most 1000.
--              A customers.* setting marks the take stale by 0009l's rule (cma.active_setting_marks_stale)
-- What it re-creates (each from its latest definition, with its -- based on: line)
--   cma.check_tenant_setting()                      172: the new setting's check; stripped of spaces as the other lists
--   cma.active_customers_of(tenant, now, channel)   172: devices is the new term (the fresh computation 173 and 185
--                                                    compare the take with)
--   cma.active_refresh_of(tenant, force, now)       174: the customers' rows store the new term; JIT off repeated
--   cma.active_rest_body_of(tenant, filters, now)   172: the part device_customers, devices_from_share; JIT off repeated
--   cma.active_rows_of(..., band)                   172: one more argument, the band (dropped and created; JIT off repeated)
--   cma.active_rows(..., band)                      172: one more argument with a default (dropped and created): a band of
--                                                    the tenant's setting or CMA04
--   cma.active_file_record(..., band)               172: one more argument with a default (dropped and created): the
--                                                    audit row names the band
-- What it does once: every stored take is marked stale, so the next run of the job computes it again whatever its
-- inputs' markers say (0009m's quiet run would otherwise keep documents without the new part and customers' rows with
-- the earlier Devices until a marker moves or the business date turns). Until that run the page shows the earlier take.
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
  if not exists (select 1 from cma.schema_migration where version = '0009o') then
    raise exception 'addition 0009o (178_job_reads.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The setting and its check
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('customers.device_bands', 'text', null, '1,2,3,6,11',
     'The bounds of the bands of Devices per active customer on Customers → Active: one to eight increasing whole numbers from 1, each at most 1000 (1,2,3,6,11 reads 0, 1, 2, 3-5, 6-10, 11+); the third bound is the count from which the page counts "customers with n or more devices"')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0009l (172), with customers.device_bands: stripped of spaces as the other lists of whole numbers, then checked
-- based on: 172_active_customers.sql
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
                 'commerce.required_contact_refs', 'flash.device_holding_statuses', 'courtesy.order_kinds', 'courtesy.ages_days',
                 'customers.cohort_ages_months', 'customers.age_months', 'customers.device_bands') then
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
  -- courtesy (0009a): the order kinds that get a courtesy call, the day it falls due, the attempts since due after which an order
  -- without a conversation is flagged Not reached, and the ages of the order cohorts (each at most 90 days)
  elsif new.key = 'courtesy.order_kinds' and not cma.flash_list_ok(new.value, '^(first|repeat|renewal)$', 3, false) then
    raise exception 'Setting % takes one to three of first, repeat and renewal, each once, comma-separated without spaces, such as first,repeat', new.key
      using errcode = 'CMA04';
  elsif new.key = 'courtesy.due_days'
        and (case when length(new.value) > 2 then true else new.value::integer not between 1 and 60 end) then
    raise exception 'Setting % takes a whole number of days from 1 to 60', new.key using errcode = 'CMA04';
  elsif new.key = 'courtesy.alert_attempts'
        and (case when length(new.value) > 2 then true else new.value::integer not between 1 and 20 end) then
    raise exception 'Setting % takes a whole number of attempts since due from 1 to 20', new.key using errcode = 'CMA04';
  elsif new.key = 'courtesy.ages_days'
        and (case when not cma.is_bucket_list(new.value, 6) then true
                 else (select max(x::integer) from unnest(string_to_array(new.value, ',')) x) > 90 end) then
    raise exception 'Setting % takes one to six increasing whole numbers of days, each at most 90, comma-separated, such as 10,14,21,30', new.key
      using errcode = 'CMA04';
  -- Customers → Active (0009l): the ages of the customer cohorts (each at most 120 months), the Customer age bands, the months
  -- of history the page shows at most, and the indicative euro rates (stored in jsonb's own form)
  elsif new.key = 'customers.cohort_ages_months'
        and (case when not cma.is_bucket_list(new.value, 8) then true
                 else (select max(x::integer) from unnest(string_to_array(new.value, ',')) x) > 120 end) then
    raise exception 'Setting % takes one to eight increasing whole numbers of months, each at most 120, comma-separated, such as 3,6,12,24,36', new.key
      using errcode = 'CMA04';
  elsif new.key = 'customers.age_months' and not cma.is_bucket_list(new.value, 10) then
    raise exception 'Setting % takes one to ten increasing whole numbers of months from 1, comma-separated, such as 12,24,36,48,60', new.key
      using errcode = 'CMA04';
  elsif new.key = 'customers.device_bands'
        and (case when not cma.is_bucket_list(new.value, 8) then true
                  else (select max(x::integer) from unnest(string_to_array(new.value, ',')) x) > 1000 end) then
    raise exception 'Setting % takes one to eight increasing whole numbers of devices from 1, each at most 1000, comma-separated, such as 1,2,3,6,11', new.key
      using errcode = 'CMA04';
  elsif new.key = 'customers.history_months'
        and (case when length(new.value) > 3 then true else new.value::integer not between 12 and 120 end) then
    raise exception 'Setting % takes a whole number of months from 12 to 120', new.key using errcode = 'CMA04';
  elsif new.key in ('customers.refresh_minutes', 'customers.history_notice_minutes')
        and (case when length(new.value) > 4 then true else new.value::integer not between 1 and 1440 end) then
    raise exception 'Setting % takes a whole number of minutes from 1 to 1440', new.key using errcode = 'CMA04';
  elsif new.key = 'reports.fx_eur_rates' then
    if not cma.active_fx_ok(new.value) then
      raise exception 'Setting % takes a JSON object of currency codes (three capitals) with the euros one unit is worth (a number above 0) and the date they are of, such as {"as_of": "2026-11-01", "GBP": 1.15}, or {}', new.key
        using errcode = 'CMA04';
    end if;
    new.value := (new.value::jsonb)::text;
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Devices per active customer in the fresh computation and in the take
-- ---------------------------------------------------------------------------------------------
-- The store customers of the base, one row each, as 172's; devices is now Devices per active customer: the devices in
-- the field (cma.active_base_of's devices_in_field) summed over the customer's holding subscriptions
-- based on: 172_active_customers.sql
create or replace function cma.active_customers_of(p_tenant_id uuid, p_now timestamptz, p_with_channel boolean)
returns table (customer_id uuid, connection_id uuid, source_id text, store text, market text, segment text, customer_start timestamptz,
               age_months integer, is_active boolean, holding_subscriptions integer, devices integer, channel text, level text,
               unknown_reason text, first_order_at timestamptz)
language sql stable
rows 10000
as $$
  select distinct on (b.customer_id) b.customer_id, b.customer_connection_id, b.customer_source_id, b.store, b.market, b.segment,
         b.customer_start,
         cma.flash_age_months_of(b.customer_start, (select t.timezone from cma.tenant t where t.id = p_tenant_id),
                                 (p_now at time zone (select t.timezone from cma.tenant t where t.id = p_tenant_id))::date),
         b.customer_holding > 0, b.customer_holding,
         coalesce((sum(b.devices_in_field) filter (where b.is_holding) over (partition by b.customer_id))::integer, 0),
         b.channel, b.level, b.unknown_reason, b.first_order_at
  from cma.active_base_of(p_tenant_id, p_now, p_with_channel,
                          case when p_with_channel then (select h.history_start from cma.first_orders_history_start_of(p_tenant_id) h) end, false) b
  where b.customer_id is not null
  order by b.customer_id
$$;

-- The refresh, as 174's; the customers' rows store the same term
-- based on: 174_active_refresh_quiet.sql
create or replace function cma.active_refresh_of(p_tenant_id uuid, p_force boolean default false, p_now timestamptz default null)
returns jsonb
language plpgsql
as $$
declare
  v_now    timestamptz := coalesce(p_now, clock_timestamp());
  v_t0     timestamptz := clock_timestamp();
  v_zone   text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_today  date;
  v_month  date;
  v_prev   date;
  v_year   date;
  v_ages   integer[];
  v_segments text[];
  v_every  integer := cma.setting_of(p_tenant_id, 'customers.refresh_minutes')::integer;
  v_set_up boolean;
  v_attr   date;
  v_take   cma.active_take;
  v_found  boolean;
  v_all    boolean;
  v_key    text;
  n_base   integer := 0;
  n_gone   integer := 0;
  n_cust   integer := 0;
  n_hist   integer := 0;
  n_docs   integer := 0;
  v_churn  jsonb;
  n_subs   integer;
  n_active integer;
  v_inputs text;
  n_stats  integer := 0;
begin
  if p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a take is refreshed for the current tenant only' using errcode = 'CMA04';
  end if;
  select * into v_take from cma.active_take t where t.tenant_id = p_tenant_id;
  v_found := found;
  -- a statement, not an expression (as the reads' heads): its plan is made again when the role changes
  select coalesce(cma.flash_source_set_up_of(p_tenant_id, 'commerce'), false) and coalesce(cma.flash_source_set_up_of(p_tenant_id, 'subscriptions'), false)
  into v_set_up;
  if not v_set_up then
    -- nothing to take: a tenant whose sources are not set up holds no rows (the page says Not set up, never zeros).
    -- Under the refresh's lock, so a refresh running beside it cannot leave rows without a take
    if v_found then
      if not pg_try_advisory_xact_lock(cma.active_take_lock_key(p_tenant_id)) then
        return jsonb_build_object('refreshed', false, 'reason', 'running');
      end if;
      delete from cma.active_document x where x.tenant_id = p_tenant_id;
      delete from cma.active_cohort x where x.tenant_id = p_tenant_id;
      delete from cma.active_month x where x.tenant_id = p_tenant_id;
      delete from cma.active_spell x where x.tenant_id = p_tenant_id;
      delete from cma.active_customer x where x.tenant_id = p_tenant_id;
      delete from cma.active_base x where x.tenant_id = p_tenant_id;
      delete from cma.active_take x where x.tenant_id = p_tenant_id;
    end if;
    return jsonb_build_object('refreshed', false, 'reason', 'not_set_up');
  end if;
  if not p_force and v_found and not v_take.stale and v_now - v_take.computed_at < make_interval(mins => v_every) then
    return jsonb_build_object('refreshed', false, 'reason', 'fresh');
  end if;
  if not pg_try_advisory_xact_lock(cma.active_take_lock_key(p_tenant_id)) then
    return jsonb_build_object('refreshed', false, 'reason', 'running');
  end if;
  -- under the lock: the take as it is now (a refresh that committed meanwhile is seen), and after it the settings the
  -- stored rows follow, so every mark counted in this take's row is of a setting read below
  select * into v_take from cma.active_take t where t.tenant_id = p_tenant_id;
  v_found := found;
  v_ages := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'customers.cohort_ages_months'));
  v_segments := cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments'));
  v_today := (v_now at time zone v_zone)::date;
  v_month := date_trunc('month', v_today)::date;
  v_prev := (v_month - interval '1 month')::date;
  v_year := (v_month - interval '13 months')::date;
  -- everything is written again when asked, on a first take, after a settings change and on a new business date
  v_all := p_force or not v_found or v_take.stale or v_take.business_date is distinct from v_today;

  -- 0. the quiet run (0009m): the inputs' change markers, read before anything is computed (a row that changes after
  --    this read gives the next run another key). The same key as the take's, on the same business date, with no
  --    setting saved since and no force: nothing the take is computed from changed, so the take stands as it is and
  --    only its moment moves. What the markers do not hold (the CRM's deals, calls and emails behind the acquisition
  --    channel, the courtesy calls) is read again at the next change of a marker and at every new business date
  v_inputs := cma.active_inputs_key_of(p_tenant_id);
  if not v_all and v_take.inputs_key is not distinct from v_inputs then
    update cma.active_take t
    set computed_at = v_now, duration_ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer
    where t.tenant_id = p_tenant_id;
    return jsonb_build_object('refreshed', true, 'unchanged', true, 'tables_analyzed', 0, 'base_rows', 0, 'customer_rows', 0, 'history_rows', 0,
                              'document_rows', 0, 'rows', 0,
                              'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
  end if;
  v_attr := (select h.history_start from cma.first_orders_history_start_of(p_tenant_id) h);

  -- 1. the base, row by row: a row that reads the same is not written again; a subscription no longer in it goes
  with n as materialized (
    select * from cma.active_base_of(p_tenant_id, v_now, true, v_attr, true)
  ), chg as materialized (
    -- only the rows that read differently from the stored ones reach the upsert: an upsert locks the row it meets
    -- before it compares, so a quiet refresh would lock and dirty every row it leaves as it is
    select n.subscription_id, n.connection_id, n.source_id, n.store, n.market, n.status, n.is_holding, n.is_paying,
           n.payment_state, n.currency, n.monthly_amount, n.billing, n.devices_in_field, n.started_at, n.ended_at,
           n.in_history, n.left_out, n.customer_id, n.customer_connection_id, n.customer_source_id, n.segment,
           n.crm_connection_id, n.contact_source_id, n.customer_start, n.customer_holding, n.customer_devices, n.clv,
           n.clv_currency, n.channel, n.level, n.unknown_reason, n.first_order_at, n.device_models
    from n
    except
    select a.subscription_id, a.connection_id, a.source_id, a.store, a.market, a.status, a.is_holding, a.is_paying,
           a.payment_state, a.currency, a.monthly_amount, a.billing, a.devices_in_field, a.started_at, a.ended_at,
           a.in_history, a.left_out, a.customer_id, a.customer_connection_id, a.customer_source_id, a.segment,
           a.crm_connection_id, a.contact_source_id, a.customer_start, a.customer_holding, a.customer_devices, a.clv,
           a.clv_currency, a.channel, a.level, a.unknown_reason, a.first_order_at, a.device_models
    from cma.active_base a where a.tenant_id = p_tenant_id
  ), up as (
    insert into cma.active_base as a (tenant_id, subscription_id, connection_id, source_id, store, market, status, is_holding, is_paying,
           payment_state, currency, monthly_amount, billing, devices_in_field, started_at, ended_at,
           in_history, left_out, customer_id, customer_connection_id, customer_source_id, segment,
           crm_connection_id, contact_source_id, customer_start, customer_holding, customer_devices, clv,
           clv_currency, channel, level, unknown_reason, first_order_at, device_models)
    select p_tenant_id, n.* from chg n
    on conflict (tenant_id, subscription_id) do update
      set (connection_id, source_id, store, market, status, is_holding, is_paying, payment_state, currency,
           monthly_amount, billing, devices_in_field, started_at, ended_at, in_history, left_out, customer_id,
           customer_connection_id, customer_source_id, segment, crm_connection_id, contact_source_id, customer_start,
           customer_holding, customer_devices, clv, clv_currency, channel, level, unknown_reason, first_order_at, device_models)
        = (excluded.connection_id, excluded.source_id, excluded.store, excluded.market, excluded.status,
           excluded.is_holding, excluded.is_paying, excluded.payment_state, excluded.currency, excluded.monthly_amount,
           excluded.billing, excluded.devices_in_field, excluded.started_at, excluded.ended_at, excluded.in_history,
           excluded.left_out, excluded.customer_id, excluded.customer_connection_id, excluded.customer_source_id,
           excluded.segment, excluded.crm_connection_id, excluded.contact_source_id, excluded.customer_start,
           excluded.customer_holding, excluded.customer_devices, excluded.clv, excluded.clv_currency, excluded.channel,
           excluded.level, excluded.unknown_reason, excluded.first_order_at, excluded.device_models)
      where (a.*) is distinct from (excluded.*)
    returning 1
  ), gone as (
    delete from cma.active_base a
    where a.tenant_id = p_tenant_id and not exists (select 1 from n where n.subscription_id = a.subscription_id)
    returning 1
  )
  select (select count(*) from up), (select count(*) from gone) into n_base, n_gone;
  -- the take's tables just changed in size (a first take, a tenant's first fill): their statistics follow at once, so
  -- no plan made for a handful of rows is run over thousands (0009m; cma.active_take_analyze)
  if n_base + n_gone > 0 then n_stats := n_stats + cma.active_take_analyze(p_tenant_id); end if;

  -- 2. the customers, row by row, from the base just stored: one row per store customer with the list's columns (a
  --    customer's Monthly recurring amount in its largest currency, the others beside it)
  with b as materialized (
    select * from cma.active_base x where x.tenant_id = p_tenant_id and x.customer_id is not null
  ), amt as (
    select q.customer_id, q.currency, q.amount, row_number() over (partition by q.customer_id order by q.amount desc, q.currency) as rn
    from (select b.customer_id, b.currency, sum(b.monthly_amount) as amount
          from b where b.is_holding and b.is_paying and b.currency is not null and b.monthly_amount is not null group by 1, 2) q
  ), oth as (
    select o.customer_id, jsonb_object_agg(o.currency, round(o.amount, 2)) as j from amt o where o.rn > 1 group by 1
  ), n as materialized (
    select distinct on (b.customer_id) b.customer_id, b.customer_connection_id as connection_id, b.customer_source_id as source_id, b.store,
           b.market, b.segment, b.channel, b.level, b.unknown_reason, b.first_order_at, b.customer_start,
           cma.flash_age_months_of(b.customer_start, v_zone, v_today) as age_months,
           coalesce(b.customer_holding, 0) > 0 as is_active, coalesce(b.customer_holding, 0) as holding,
           -- Devices per active customer (0009r): the devices in the field on the customer's holding subscriptions
           coalesce((sum(b.devices_in_field) filter (where b.is_holding) over (partition by b.customer_id))::integer, 0) as devices,
           b.clv, b.clv_currency, b.crm_connection_id, b.contact_source_id, a.currency, a.amount, coalesce(oth.j, '{}'::jsonb) as other_amounts
    from b
    left join amt a on a.customer_id = b.customer_id and a.rn = 1
    left join oth on oth.customer_id = b.customer_id
    order by b.customer_id
  ), chg as materialized (
    select n.customer_id, n.connection_id, n.source_id, n.store, n.market, n.segment, n.channel, n.level, n.unknown_reason,
           n.first_order_at, n.customer_start, n.age_months, n.is_active, n.holding, n.devices, n.clv, n.clv_currency,
           n.crm_connection_id, n.contact_source_id, n.currency, n.amount, n.other_amounts
    from n
    except
    select a.customer_id, a.connection_id, a.source_id, a.store, a.market, a.segment, a.channel, a.level, a.unknown_reason,
           a.first_order_at, a.customer_start, a.age_months, a.is_active, a.holding, a.devices, a.clv, a.clv_currency,
           a.crm_connection_id, a.contact_source_id, a.currency, a.amount, a.other_amounts
    from cma.active_customer a where a.tenant_id = p_tenant_id
  ), up as (
    insert into cma.active_customer as a (tenant_id, customer_id, connection_id, source_id, store, market, segment, channel, level, unknown_reason,
           first_order_at, customer_start, age_months, is_active, holding, devices, clv, clv_currency,
           crm_connection_id, contact_source_id, currency, amount, other_amounts)
    select p_tenant_id, n.* from chg n
    on conflict (tenant_id, customer_id) do update
      set (connection_id, source_id, store, market, segment, channel, level, unknown_reason, first_order_at,
           customer_start, age_months, is_active, holding, devices, clv, clv_currency, crm_connection_id,
           contact_source_id, currency, amount, other_amounts)
        = (excluded.connection_id, excluded.source_id, excluded.store, excluded.market, excluded.segment,
           excluded.channel, excluded.level, excluded.unknown_reason, excluded.first_order_at, excluded.customer_start,
           excluded.age_months, excluded.is_active, excluded.holding, excluded.devices, excluded.clv,
           excluded.clv_currency, excluded.crm_connection_id, excluded.contact_source_id, excluded.currency,
           excluded.amount, excluded.other_amounts)
      where (a.*) is distinct from (excluded.*)
    returning 1
  ), gone as (
    delete from cma.active_customer a
    where a.tenant_id = p_tenant_id and not exists (select 1 from n where n.customer_id = a.customer_id)
    returning 1
  )
  select (select count(*) from up) + (select count(*) from gone) into n_cust;
  if n_cust > 0 then n_stats := n_stats + cma.active_take_analyze(p_tenant_id); end if;

  -- 3. the history (the spells, the month ends, the cohorts): only when what it is computed from changed. Its key is a
  --    digest of the base's columns it reads, with the zone and the cohort ages
  select md5(coalesce(string_agg(md5(concat_ws('|', x.subscription_id, x.customer_id, x.market, x.segment, x.channel, x.started_at, x.ended_at,
                                           x.in_history, x.customer_start, x.currency, x.monthly_amount, x.is_holding, x.is_paying)),
                                 '' order by x.subscription_id), '') || '|' || v_zone || '|' || array_to_string(v_ages, ','))
  into v_key
  from cma.active_base x where x.tenant_id = p_tenant_id;
  if v_all or v_key is distinct from v_take.history_key then
    delete from cma.active_cohort x where x.tenant_id = p_tenant_id;
    delete from cma.active_month x where x.tenant_id = p_tenant_id;
    delete from cma.active_spell x where x.tenant_id = p_tenant_id;

    insert into cma.active_spell (tenant_id, customer_id, market, segment, channel, customer_start, customer_start_on, spell_start, spell_end, len, ended)
    select p_tenant_id, c.customer_id, c.market, c.segment, c.channel, c.customer_start, (c.customer_start at time zone v_zone)::date, x.spell_start, x.spell_end,
           greatest(0, cma.flash_age_months_of(x.spell_start, v_zone, coalesce((x.spell_end at time zone v_zone)::date, v_today))),
           x.spell_end is not null
    from (select array_agg(b.customer_id::text) as k, array_agg(b.started_at) as s, array_agg(b.ended_at) as e
          from cma.active_base b where b.tenant_id = p_tenant_id and b.customer_id is not null and b.in_history) a
    cross join lateral cma.active_spells_from(a.k, a.s, a.e) x
    join cma.active_customer c on c.tenant_id = p_tenant_id and c.customer_id = x.key::uuid;
    get diagnostics n_hist = row_count;

    -- the customers per month end (from the spells), the subscriptions and the amounts (from the base's intervals)
    insert into cma.active_month (tenant_id, kind, month, market, segment, channel, currency, inflow, outflow, at_end)
    select p_tenant_id, 'customers', x.month, x.d1, x.d2, x.d3, '', x.inflow, x.outflow, x.at_end
    from (select array_agg(sp.market) as a, array_agg(sp.segment) as b, array_agg(sp.channel) as c, array_agg(1::numeric) as w,
                 array_agg(sp.spell_start) as s, array_agg(sp.spell_end) as e
          from cma.active_spell sp where sp.tenant_id = p_tenant_id) a
    cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, v_zone, v_now) x
    union all
    select p_tenant_id, 'subscriptions', x.month, x.d1, x.d2, x.d3, '', x.inflow, x.outflow, x.at_end
    from (select array_agg(b.market) as a, array_agg(b.segment) as b, array_agg(b.channel) as c, array_agg(1::numeric) as w,
                 array_agg(b.started_at) as s, array_agg(b.ended_at) as e
          from cma.active_base b where b.tenant_id = p_tenant_id and b.in_history) a
    cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, v_zone, v_now) x
    union all
    -- the Monthly recurring amount: the subscriptions holding then at their amount today; one that holds today without
    -- paying is left out throughout. The currency rides with the channel through the cube's third dimension
    select p_tenant_id, 'amount', x.month, x.d1, x.d2, split_part(x.d3, '~', 1), split_part(x.d3, '~', 2), x.inflow, x.outflow, x.at_end
    from (select array_agg(b.market) as a, array_agg(b.segment) as b, array_agg(b.channel || '~' || b.currency) as c, array_agg(b.monthly_amount) as w,
                 array_agg(b.started_at) as s, array_agg(b.ended_at) as e
          from cma.active_base b
          where b.tenant_id = p_tenant_id and b.in_history and b.currency is not null and b.monthly_amount is not null
            and (not b.is_holding or b.is_paying)) a
    cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, v_zone, v_now) x
    union all
    -- the customers with a subscription in a currency at the two month ends a change line compares with
    select p_tenant_id, 'currency_customers', q.m, q.market, q.segment, q.channel, q.currency, 0, 0, count(*)
    from (select distinct x.m, b.market, b.segment, b.channel, b.currency, b.customer_id
          from cma.active_base b
          cross join (values (v_prev, v_month::timestamp at time zone v_zone),
                             (v_year, (v_year + interval '1 month')::timestamp at time zone v_zone)) x(m, at)
          where b.tenant_id = p_tenant_id and b.customer_id is not null and b.in_history and b.currency is not null
            and b.started_at < x.at and (b.ended_at is null or b.ended_at >= x.at)) q
    group by q.m, q.market, q.segment, q.channel, q.currency
    union all
    -- Flash's Churn (subscription) over the last 30 business dates (the unit economics' one figure, the markets' column):
    -- a churned subscription under its store's market and the base's segment and channel of it
    select p_tenant_id, 'churned_30d', v_month, x.market, coalesce(b.segment, 'unknown'), coalesce(b.channel, 'unknown'), '', 0, 0, count(*)
    from cma.flash_churn_of(p_tenant_id, v_today - 29, v_today) x
    left join cma.active_base b on b.tenant_id = p_tenant_id and b.subscription_id = x.subscription_id
    group by x.market, coalesce(b.segment, 'unknown'), coalesce(b.channel, 'unknown');

    insert into cma.active_cohort (tenant_id, period, cohort, market, segment, channel, age_months, started, still_active, mature)
    select p_tenant_id, g.period, x.cohort, x.d1, x.d2, x.d3, x.age_months, x.started, x.still_active, x.mature
    from (select array_agg(sp.customer_id::text) as k, array_agg(sp.market) as a, array_agg(sp.segment) as b, array_agg(sp.channel) as c,
                 array_agg(sp.customer_start) as cs, array_agg(sp.spell_start) as s, array_agg(sp.spell_end) as e
          from cma.active_spell sp where sp.tenant_id = p_tenant_id) a
    cross join (values ('month'), ('quarter')) g(period)
    cross join lateral cma.active_cohort_cube_from(a.k, a.a, a.b, a.c, a.cs, a.s, a.e, v_ages, g.period, v_zone, v_now) x;
    -- the history's tables were written again: the documents below read them
    n_stats := n_stats + cma.active_take_analyze(p_tenant_id);
  else
    -- the history stays as it was last written: its month ends and cohorts are of that moment (no row they are computed
    -- from changed since; a cohort's maturity is of that moment too, at most a business date old). Flash's churn count
    -- reads the subscriptions' events, which the key does not hold: it is written again at every refresh, where it
    -- reads differently
    select coalesce(jsonb_agg(jsonb_build_object('market', q.market, 'segment', q.segment, 'channel', q.channel, 'n', q.n)), '[]'::jsonb)
    into v_churn
    from (select x.market, coalesce(b.segment, 'unknown') as segment, coalesce(b.channel, 'unknown') as channel, count(*) as n
          from cma.flash_churn_of(p_tenant_id, v_today - 29, v_today) x
          left join cma.active_base b on b.tenant_id = p_tenant_id and b.subscription_id = x.subscription_id
          group by 1, 2, 3) q;
    delete from cma.active_month a
    where a.tenant_id = p_tenant_id and a.kind = 'churned_30d'
      and not exists (select 1 from jsonb_to_recordset(v_churn) n(market text, segment text, channel text, n numeric)
                      where a.month = v_month and n.market = a.market and n.segment = a.segment and n.channel = a.channel);
    insert into cma.active_month as a (tenant_id, kind, month, market, segment, channel, currency, inflow, outflow, at_end)
    select p_tenant_id, 'churned_30d', v_month, n.market, n.segment, n.channel, '', 0, 0, n.n
    from jsonb_to_recordset(v_churn) n(market text, segment text, channel text, n numeric)
    where not exists (select 1 from cma.active_month o
                      where o.tenant_id = p_tenant_id and o.kind = 'churned_30d' and o.month = v_month and o.market = n.market
                        and o.segment = n.segment and o.channel = n.channel and o.currency = '' and o.at_end = n.n)
    on conflict (tenant_id, kind, month, market, segment, channel, currency) do update set at_end = excluded.at_end;
  end if;

  select count(*) filter (where b.is_holding), count(distinct b.customer_id) filter (where coalesce(b.customer_holding, 0) > 0)
  into n_subs, n_active
  from cma.active_base b where b.tenant_id = p_tenant_id;
  -- a first take: its row is there before the documents are computed (they ask whether there is a take). An existing
  -- take's row is left alone until the documents are computed, so a settings save that marks the take stale does not
  -- wait for them
  insert into cma.active_take (tenant_id, computed_at, business_date, duration_ms, history_key, customers, subscriptions, attribution_start, stale, stale_since, inputs_key)
  values (p_tenant_id, v_now, v_today, 0, v_key, n_active, n_subs, v_attr, false, null, v_inputs)
  on conflict (tenant_id) do nothing;

  -- 4. the documents (decision D16), from the rows just stored and as of this take: above the fold and below it,
  --    without a filter and under each single market, segment and acquisition channel. Computed at
  --    every refresh (they also read catalogs and the clock's month), written only where one reads differently
  with f(m, s, c) as (
    select null::text, null::text, null::text
    union all
    select q.market, null, null
    from (select st.market from cma.commerce_store st where st.tenant_id = p_tenant_id
          union select x.market from cma.active_customer x where x.tenant_id = p_tenant_id
          union select x.market from cma.active_base x where x.tenant_id = p_tenant_id) q
    where q.market is not null and q.market <> ''
    union all
    select null, x.segment, null from (select distinct u as segment from unnest(v_segments || array['unknown']) u) x where x.segment <> ''
    union all
    select null, null, x.channel from unnest(array['indirect', 'direct', 'unknown']) x(channel)
  ), n as materialized (
    select 'top'::text as part, coalesce(f.m, '') as market, coalesce(f.s, '') as segment, coalesce(f.c, '') as channel,
           cma.active_top_body_of(p_tenant_id, f.m, f.s, f.c, v_now, true) as doc
    from f
    union all
    select 'rest', coalesce(f.m, ''), coalesce(f.s, ''), coalesce(f.c, ''), cma.active_rest_body_of(p_tenant_id, f.m, f.s, f.c, v_now)
    from f
  ), chg as materialized (
    -- only a document that reads differently is written (and its row locked)
    select n.part, n.market, n.segment, n.channel, n.doc from n
    where not exists (select 1 from cma.active_document a
                      where a.tenant_id = p_tenant_id and a.part = n.part and a.market = n.market and a.segment = n.segment and a.channel = n.channel
                        and a.doc = n.doc)
  ), up as (
    insert into cma.active_document as a (tenant_id, part, market, segment, channel, doc)
    select p_tenant_id, n.part, n.market, n.segment, n.channel, n.doc from chg n
    on conflict (tenant_id, part, market, segment, channel) do update set doc = excluded.doc
    returning 1
  ), gone as (
    delete from cma.active_document a
    where a.tenant_id = p_tenant_id
      and not exists (select 1 from n where n.part = a.part and n.market = a.market and n.segment = a.segment and n.channel = a.channel)
    returning 1
  )
  select (select count(*) from up) + (select count(*) from gone) into n_docs;
  -- the documents' table too (on a first take it was empty at every analyze above)
  if n_docs > 0 then n_stats := n_stats + cma.active_take_analyze(p_tenant_id); end if;
  -- the take's row, last: its moment, and the mark cleared only when no setting was saved since this refresh read the
  -- take (the row is the one committed now: a settings transaction still open is waited for)
  update cma.active_take t
  set computed_at = v_now, business_date = v_today, duration_ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer,
      history_key = v_key, customers = n_active, subscriptions = n_subs, attribution_start = v_attr, inputs_key = v_inputs,
      stale = t.stale_marks is distinct from coalesce(v_take.stale_marks, 0),
      stale_since = case when t.stale_marks is distinct from coalesce(v_take.stale_marks, 0) then t.stale_since end
  where t.tenant_id = p_tenant_id;

  return jsonb_build_object('refreshed', true, 'unchanged', false, 'tables_analyzed', n_stats, 'base_rows', n_base + n_gone, 'customer_rows', n_cust, 'history_rows', n_hist,
                            'document_rows', n_docs, 'rows', n_base + n_gone + n_cust + n_hist + n_docs,
                            'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
end
$$;
alter function cma.active_refresh_of(uuid, boolean, timestamptz) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 3. The below-the-fold document: the part device_customers
-- ---------------------------------------------------------------------------------------------
-- based on: 172_active_customers.sql
create or replace function cma.active_rest_body_of(p_tenant_id uuid, p_market text, p_segment text, p_channel text, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone         text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_today        date;
  v_month        date;
  v_first        date;
  v_bands        integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'customers.age_months'));
  v_fx           jsonb := cma.active_fx_of(p_tenant_id);
  v_segments     text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments'));
  v_device_bands integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.device_bands'));
  -- the bands of Devices per active customer (0009r) and, from them, the count from which a customer holds "several":
  -- the third bound, or the last one of a shorter list (as the ages of "More than" follow customers.age_months)
  v_dev_bounds   integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'customers.device_bands'));
  v_dev_from     integer;
  v_doc          jsonb;
begin
  v_today := (p_now at time zone v_zone)::date;
  v_month := date_trunc('month', v_today)::date;
  v_first := (v_month - make_interval(months => cma.setting_of(p_tenant_id, 'customers.history_months')::integer))::date;
  v_dev_from := v_dev_bounds[least(3, cardinality(v_dev_bounds))];

  with b0 as (
    -- the stored base (cma.active_base, the refresh's)
    select * from cma.active_base x where x.tenant_id = p_tenant_id
  ), b as materialized (
    select * from b0 x
    where (p_market is null or x.market = p_market) and (p_segment is null or x.segment = p_segment)
      and (p_channel is null or x.channel = p_channel)
  ), c as materialized (
    -- the store customers, one row each, as the refresh stored them (the age as of the take's business date)
    select x.customer_id, x.market, x.segment, x.channel, x.unknown_reason, x.customer_start, x.is_active, x.holding, x.devices,
           x.clv, x.clv_currency, x.age_months as age
    from cma.active_customer x
    where x.tenant_id = p_tenant_id and (p_market is null or x.market = p_market) and (p_segment is null or x.segment = p_segment)
      and (p_channel is null or x.channel = p_channel)
  ), sp as materialized (
    -- their active spells, with the length in whole months as of the take
    select x.customer_id, x.market, x.segment, x.channel, x.customer_start, x.customer_start_on, x.spell_start, x.spell_end, x.len, x.ended
    from cma.active_spell x
    where x.tenant_id = p_tenant_id and (p_market is null or x.market = p_market) and (p_segment is null or x.segment = p_segment)
      and (p_channel is null or x.channel = p_channel)
  ), mcell as materialized (
    -- the stored month ends under the filters; each series below starts with its own first month, as a series computed
    -- from the filtered rows alone would
    select x.kind, x.month, x.market, x.segment, x.channel, x.currency, x.inflow, x.outflow, x.at_end
    from cma.active_month x
    where x.tenant_id = p_tenant_id and (p_market is null or x.market = p_market) and (p_segment is null or x.segment = p_segment)
      and (p_channel is null or x.channel = p_channel)
  ), mc as materialized (
    -- the customers per month end, by market, segment and channel
    select x.month, x.market, x.segment, x.channel, x.inflow, x.outflow, x.at_end
    from mcell x
    where x.kind = 'customers' and x.month >= (select min(y.month) from mcell y where y.kind = 'customers' and y.inflow <> 0)
  ), ma as materialized (
    -- the Monthly recurring amount per month end and currency
    select x.month, x.currency, sum(x.at_end) as at_end
    from mcell x
    where x.kind = 'amount' and x.month >= (select min(y.month) from mcell y where y.kind = 'amount' and (y.inflow <> 0 or y.at_end <> 0))
    group by 1, 2
  ), mt as materialized (
    select mc.month, sum(mc.at_end) as customers, sum(mc.inflow) as inflow, sum(mc.outflow) as outflow from mc group by 1
  ), mchan as (
    select q.month, jsonb_object_agg(q.channel, q.n) as j
    from (select mc.month, mc.channel, sum(mc.inflow) as n from mc group by 1, 2) q group by 1
  ), mam as (
    select ma.month, jsonb_object_agg(ma.currency, round(ma.at_end, 2)) as j,
           bool_and(ma.currency = 'EUR' or coalesce(jsonb_typeof(v_fx -> ma.currency) = 'number', false)) as fx_ok,
           round(sum(cma.active_eur_of(ma.at_end, ma.currency, v_fx)), 2) as eur
    from ma group by 1
  ), g_c as materialized (
    select case when grouping(c.market) = 0 then 'market' when grouping(c.segment) = 0 then 'segment' else 'all' end as dim,
           coalesce(c.market, c.segment, '*') as key,
           count(*) as customers, sum(c.devices) as devices, sum(c.holding) as holding,
           percentile_cont(0.5) within group (order by c.age) as median_age,
           count(*) filter (where c.channel = 'indirect') as indirect, count(*) filter (where c.channel = 'direct') as direct,
           count(*) filter (where c.channel = 'unknown') as unknown_channel,
           count(*) filter (where c.age >= v_bands[1]) as over1, count(*) filter (where c.age >= v_bands[2]) as over2,
           count(*) filter (where c.age >= v_bands[3]) as over3,
           count(*) filter (where c.devices >= v_dev_from) as dev_from
    from c where c.is_active
    group by grouping sets ((c.market), (c.segment), ())
  ), g_seg as (
    select q.dim, q.key, jsonb_object_agg(q.segment, q.n) as j
    from (select case when grouping(c.market) = 0 then 'market' else 'all' end as dim, coalesce(c.market, '*') as key, c.segment, count(*) as n
          from c where c.is_active group by grouping sets ((c.market, c.segment), (c.segment))) q
    group by 1, 2
  ), g_clv as (
    select q.dim, q.key,
           jsonb_object_agg(q.currency, jsonb_build_object('average', q.average, 'median', q.median, 'per_month', q.per_month, 'customers', q.n)) as j
    from (select case when grouping(c.market) = 0 then 'market' when grouping(c.segment) = 0 then 'segment' else 'all' end as dim,
                 coalesce(c.market, c.segment, '*') as key, c.clv_currency as currency, count(*) as n, round(avg(c.clv), 2) as average,
                 round((percentile_cont(0.5) within group (order by c.clv))::numeric, 2) as median,
                 round(avg(c.clv / greatest(c.age, 1)), 2) as per_month
          from c where c.is_active and c.clv is not null and c.clv_currency is not null
          group by grouping sets ((c.market, c.clv_currency), (c.segment, c.clv_currency), (c.clv_currency))) q
    group by 1, 2
  ), g_sub as (
    select case when grouping(b.market) = 0 then 'market' when grouping(b.segment) = 0 then 'segment' else 'all' end as dim,
           coalesce(b.market, b.segment, '*') as key, count(*) as subscriptions
    from b where b.is_holding
    group by grouping sets ((b.market), (b.segment), ())
  ), g_amt0 as materialized (
    select case when grouping(b.market) = 0 then 'market' when grouping(b.segment) = 0 then 'segment' else 'all' end as dim,
           coalesce(b.market, b.segment, '*') as key, b.currency, sum(b.monthly_amount) filter (where b.is_paying) as amount,
           count(distinct b.customer_id) as customers
    from b where b.is_holding and b.currency is not null
    group by grouping sets ((b.market, b.currency), (b.segment, b.currency), (b.currency))
  ), g_amt as (
    select q.dim, q.key,
           jsonb_object_agg(q.currency, jsonb_build_object('amount', round(coalesce(q.amount, 0), 2), 'customers', q.customers,
                                                           'average', case when q.customers > 0 then round(coalesce(q.amount, 0) / q.customers, 2) end)) as j
    from g_amt0 q group by 1, 2
  ), g_km as materialized (
    select case when grouping(sp.segment) = 0 then 'segment' when grouping(sp.channel) = 0 then 'channel' else 'all' end as dim,
           coalesce(sp.segment, sp.channel, '*') as key, cma.active_km_json(array_agg(sp.len), array_agg(sp.ended)) as j
    from sp
    group by grouping sets ((sp.segment), (sp.channel), ())
  ), g_30 as (
    select case when grouping(sp.market) = 0 then 'market' else 'all' end as dim, coalesce(sp.market, '*') as key,
           count(*) filter (where sp.spell_start > p_now - interval '30 days' and sp.spell_start <= p_now)
           - count(*) filter (where sp.spell_end > p_now - interval '30 days' and sp.spell_end <= p_now) as net
    from sp group by grouping sets ((sp.market), ())
  ), ch as materialized (
    -- Flash's Churn (subscription) over the 30 business dates to the take's, as the refresh stored it per market, segment and channel
    select x.market, x.at_end as n
    from mcell x
    where x.kind = 'churned_30d'
  ), g_ch as (
    select case when grouping(ch.market) = 0 then 'market' else 'all' end as dim, coalesce(ch.market, '*') as key, sum(ch.n) as churned
    from ch group by grouping sets ((ch.market), ())
  ), g_spark as (
    select q.market, jsonb_agg(q.n order by q.month) as j
    from (select mc.market, mc.month, sum(mc.at_end) as n from mc where mc.month >= (v_month - interval '12 months')::date group by 1, 2) q
    group by 1
  ), keys as (
    -- every market of the tenant's stores, with or without a subscription (zeros, never a missing row), and unknown
    -- where a subscription has no store
    select g.key from g_c g where g.dim = 'market' union select g.key from g_sub g where g.dim = 'market'
    union select st.market from cma.commerce_store st where st.tenant_id = p_tenant_id and (p_market is null or st.market = p_market)
  ), stat as materialized (
    -- one row per market, per segment and over all: the present figures as JSON
    select k.dim, k.key,
           jsonb_build_object(
             'customers', coalesce(gc.customers, 0), 'by_segment', coalesce(gs.j, '{}'::jsonb),
             'subscriptions', coalesce(gb.subscriptions, 0), 'devices', coalesce(gc.devices, 0),
             'amounts', coalesce(ga.j, '{}'::jsonb), 'median_age', round(gc.median_age::numeric, 1), 'clv', coalesce(gv.j, '{}'::jsonb),
             'churned_30d', coalesce(gh.churned, 0), 'net_30d', coalesce(g3.net, 0),
             'indirect', coalesce(gc.indirect, 0), 'direct', coalesce(gc.direct, 0), 'unknown_channel', coalesce(gc.unknown_channel, 0),
             'indirect_share', case when coalesce(gc.indirect, 0) + coalesce(gc.direct, 0) > 0
                                    then round(gc.indirect::numeric / (gc.indirect + gc.direct), 4) end,
             'subscriptions_per_customer', case when coalesce(gc.customers, 0) > 0 then round(gc.holding::numeric / gc.customers, 2) end,
             'devices_per_customer', case when coalesce(gc.customers, 0) > 0 then round(gc.devices::numeric / gc.customers, 2) end,
             'devices_from_share', case when coalesce(gc.customers, 0) > 0 then round(gc.dev_from::numeric / gc.customers, 4) end) as j,
           coalesce(gc.customers, 0) as customers
    from (select 'market'::text as dim, keys.key from keys
          union all select 'segment', x from unnest(v_segments || array['unknown']) x
          union all select 'all', '*') k
    left join g_c gc on gc.dim = k.dim and gc.key = k.key
    left join g_seg gs on gs.dim = k.dim and gs.key = k.key
    left join g_sub gb on gb.dim = k.dim and gb.key = k.key
    left join g_amt ga on ga.dim = k.dim and ga.key = k.key
    left join g_clv gv on gv.dim = k.dim and gv.key = k.key
    left join g_ch gh on gh.dim = k.dim and gh.key = k.key
    left join g_30 g3 on g3.dim = k.dim and g3.key = k.key
  ), cmp_long as (
    select 'customers'::text as measure, null::integer as months, null::text as currency, 10 as ord, s.key, s.customers::numeric as v, null::integer as longest
    from stat s where s.dim = 'segment'
    union all
    select 'share', null, null, 20, s.key,
           case when (select t.customers from stat t where t.dim = 'all') > 0
                then round(s.customers::numeric / (select t.customers from stat t where t.dim = 'all'), 4) end, null
    from stat s where s.dim = 'segment'
    union all
    select 'lifetime_median', null, null, 30, g.key, (g.j ->> 'median')::numeric, (g.j ->> 'longest')::integer from g_km g where g.dim = 'segment'
    union all
    select 'retention', a.months, null, 40, g.key,
           (select (p ->> 'survival')::numeric from jsonb_array_elements(g.j -> 'curve') p
            where (p ->> 'age')::integer = a.months and (p ->> 'at_risk')::integer > 0), null
    from g_km g cross join unnest(v_bands[1:3]) a(months) where g.dim = 'segment'
    union all
    select 'median_age', null, null, 50, s.key, (s.j ->> 'median_age')::numeric, null from stat s where s.dim = 'segment'
    union all
    select x.measure, null, e.key, x.ord, s.key, (e.value ->> x.field)::numeric, null
    from stat s cross join jsonb_each(s.j -> 'clv') e
    cross join (values ('clv_average', 'average', 60), ('clv_median', 'median', 70), ('clv_per_month', 'per_month', 80)) x(measure, field, ord)
    where s.dim = 'segment'
    union all
    select 'average_monthly_amount', null, e.key, 90, s.key, (e.value ->> 'average')::numeric, null
    from stat s cross join jsonb_each(s.j -> 'amounts') e where s.dim = 'segment'
    union all
    select x.measure, null, null, x.ord, s.key, (s.j ->> x.measure)::numeric, null
    from stat s
    cross join (values ('subscriptions_per_customer', 100), ('devices_per_customer', 110), ('devices_from_share', 115), ('indirect_share', 120)) x(measure, ord)
    where s.dim = 'segment'
  ), cmp as (
    select l.measure, l.months, l.currency, min(l.ord) as ord,
           max(l.v) filter (where l.key = v_segments[1]) as a, max(l.v) filter (where l.key = v_segments[2]) as b,
           max(l.v) filter (where l.key = 'unknown') as u,
           max(l.longest) filter (where l.key = v_segments[1]) as a_longest, max(l.longest) filter (where l.key = v_segments[2]) as b_longest,
           max(l.longest) filter (where l.key = 'unknown') as u_longest
    from cmp_long l
    group by 1, 2, 3
  )
  select jsonb_build_object(
    'figures', true,
    'months', (select coalesce(jsonb_agg(jsonb_build_object(
                        'month', mt.month, 'is_now', mt.month = v_month,
                        'inflow', mt.inflow, 'inflow_by_channel', coalesce(mchan.j, '{}'::jsonb), 'outflow', mt.outflow, 'net', mt.inflow - mt.outflow,
                        'amounts', case when mt.month = v_month
                                        then (select coalesce(jsonb_object_agg(q.currency, round(coalesce(q.amount, 0), 2)), '{}'::jsonb)
                                              from g_amt0 q where q.dim = 'all')
                                        else coalesce(mam.j, '{}'::jsonb) end,
                        'eur', case when v_fx = '{}'::jsonb then null
                                    when mt.month = v_month
                                    then (select case when count(*) > 0 and bool_and(q.currency = 'EUR' or coalesce(jsonb_typeof(v_fx -> q.currency) = 'number', false))
                                                      then round(sum(cma.active_eur_of(q.amount, q.currency, v_fx)), 2) end
                                          from g_amt0 q where q.dim = 'all')
                                    when mam.fx_ok then mam.eur end) order by mt.month), '[]'::jsonb)
               from mt
               left join mchan on mchan.month = mt.month
               left join mam on mam.month = mt.month
               where mt.month >= v_first),
    'markets', (select coalesce(jsonb_agg(s.j || jsonb_build_object(
                         'market', s.key,
                         'share', case when (select t.customers from stat t where t.dim = 'all') > 0
                                       then round(s.customers::numeric / (select t.customers from stat t where t.dim = 'all'), 4) end,
                         'spark', coalesce(gs.j, '[]'::jsonb))
                         order by s.customers desc, s.key = 'unknown', s.key), '[]'::jsonb)
                from stat s left join g_spark gs on gs.market = s.key where s.dim = 'market'),
    'markets_total', (select s.j || jsonb_build_object('share', case when s.customers > 0 then 1 end) from stat s where s.dim = 'all'),
    'comparison', jsonb_build_object(
      'a', v_segments[1], 'b', v_segments[2],
      'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                        'measure', c2.measure, 'months', c2.months, 'currency', c2.currency, 'a', c2.a, 'b', c2.b, 'unknown', c2.u,
                        'difference', c2.a - c2.b, 'ratio', case when c2.a > 0 and c2.b > 0 then round(c2.a / c2.b, 2) end,
                        'a_longest', c2.a_longest, 'b_longest', c2.b_longest, 'unknown_longest', c2.u_longest)
                        order by c2.ord, c2.months nulls first, c2.currency nulls first), '[]'::jsonb)
               from cmp c2)),
    'survival', jsonb_build_object(
      'all', (select g.j from g_km g where g.dim = 'all'),
      'segment', (select coalesce(jsonb_agg(g.j || jsonb_build_object('value', g.key)
                                            order by coalesce(array_position(v_segments, g.key), 1000), g.key), '[]'::jsonb)
                  from g_km g where g.dim = 'segment'),
      'channel', (select coalesce(jsonb_agg(g.j || jsonb_build_object('value', g.key)
                                            order by array_position(array['indirect', 'direct', 'unknown'], g.key)), '[]'::jsonb)
                  from g_km g where g.dim = 'channel')),
    'age_bands', (select coalesce(jsonb_agg(jsonb_build_object('band', w.band, 'customers', coalesce(q.n, 0)) order by w.ord), '[]'::jsonb)
                  from (select x.band, x.ord from unnest(cma.flash_age_bands_of(v_bands)) with ordinality x(band, ord)
                        union all
                        select 'unknown', 1000 where exists (select 1 from c where c.is_active and c.age is null)) w
                  left join (select cma.flash_age_band_of(c.age, v_bands) as band, count(*) as n from c where c.is_active group by 1) q
                    on q.band = w.band),
    'age_over', (select coalesce(jsonb_agg(jsonb_build_object('months', x.m, 'customers', x.n,
                                                           'share', case when g.customers > 0 then round(x.n::numeric / g.customers, 4) end)
                                         order by x.m), '[]'::jsonb)
                 from g_c g
                 cross join lateral (values (v_bands[1], g.over1), (v_bands[2], g.over2), (v_bands[3], g.over3)) x(m, n)
                 where g.dim = 'all' and x.m is not null),
    -- Devices per active customer (0009r): the active customers by the devices in the field on their holding
    -- subscriptions, in the bands of customers.device_bands (band 0: no linked device, never left out), each band with
    -- its customers and devices, their shares, and the customers and devices per segment and per acquisition channel;
    -- the average, the median, and the customers from v_dev_from devices on with their share of customers and of devices
    'device_customers', (select jsonb_build_object(
                  'bounds', to_jsonb(v_dev_bounds), 'from', v_dev_from,
                  'customers', t.n, 'devices', t.d,
                  'average', case when t.n > 0 then round(t.d::numeric / t.n, 2) end,
                  'median', round(t.median::numeric, 1),
                  'not_linked', t.n0,
                  'from_customers', t.n_from, 'from_devices', t.d_from,
                  'from_share', case when t.n > 0 then round(t.n_from::numeric / t.n, 4) end,
                  'from_devices_share', case when t.d > 0 then round(t.d_from::numeric / t.d, 4) end,
                  'bands', (select coalesce(jsonb_agg(jsonb_build_object(
                                     'band', w.band, 'customers', coalesce(q.n, 0), 'devices', coalesce(q.d, 0),
                                     'share', case when t.n > 0 then round(coalesce(q.n, 0)::numeric / t.n, 4) end,
                                     'devices_share', case when t.d > 0 then round(coalesce(q.d, 0)::numeric / t.d, 4) end,
                                     'by_segment', coalesce(qs.j, '{}'::jsonb), 'by_channel', coalesce(qc.j, '{}'::jsonb))
                                     order by w.ord), '[]'::jsonb)
                            from unnest(cma.flash_count_bands_of(v_dev_bounds)) with ordinality w(band, ord)
                            left join (select cma.flash_count_band_of(c.devices, v_dev_bounds) as band, count(*) as n, sum(c.devices) as d
                                       from c where c.is_active group by 1) q on q.band = w.band
                            left join (select x.band, jsonb_object_agg(x.segment, jsonb_build_object('customers', x.n, 'devices', x.d)) as j
                                       from (select cma.flash_count_band_of(c.devices, v_dev_bounds) as band, c.segment, count(*) as n, sum(c.devices) as d
                                             from c where c.is_active group by 1, 2) x
                                       group by 1) qs on qs.band = w.band
                            left join (select x.band, jsonb_object_agg(x.channel, jsonb_build_object('customers', x.n, 'devices', x.d)) as j
                                       from (select cma.flash_count_band_of(c.devices, v_dev_bounds) as band, c.channel, count(*) as n, sum(c.devices) as d
                                             from c where c.is_active group by 1, 2) x
                                       group by 1) qc on qc.band = w.band))
                from (select count(*) as n, coalesce(sum(c.devices), 0) as d,
                             percentile_cont(0.5) within group (order by c.devices) as median,
                             count(*) filter (where c.devices = 0) as n0,
                             count(*) filter (where c.devices >= v_dev_from) as n_from,
                             coalesce(sum(c.devices) filter (where c.devices >= v_dev_from), 0) as d_from
                      from c where c.is_active) t),
    'mix', jsonb_build_object(
      'billing', (select coalesce(jsonb_agg(jsonb_build_object('key', q.billing, 'subscriptions', q.n)
                                            order by array_position(array['monthly', 'yearly', 'other', 'unknown'], q.billing)), '[]'::jsonb)
                  from (select b.billing, count(*) as n from b where b.is_holding group by 1) q),
      'device_band', (select coalesce(jsonb_agg(jsonb_build_object('key', w.band, 'subscriptions', coalesce(q.n, 0)) order by w.ord), '[]'::jsonb)
                      from unnest(cma.flash_count_bands_of(v_device_bands)) with ordinality w(band, ord)
                      left join (select cma.flash_count_band_of(b.devices_in_field, v_device_bands) as band, count(*) as n
                                 from b where b.is_holding group by 1) q on q.band = w.band),
      'model', (select coalesce(jsonb_agg(jsonb_build_object('key', q.model_key, 'name', q.name, 'devices', q.n) order by q.n desc, q.model_key), '[]'::jsonb)
                from (select e.key as model_key, (select m.name from cma.device_model m where m.tenant_id = p_tenant_id and m.key = e.key) as name,
                             sum(e.value::bigint) as n
                      from b cross join jsonb_each_text(coalesce(b.device_models, '{}'::jsonb)) e
                      where b.is_holding
                      group by 1) q),
      'payment_state', (select coalesce(jsonb_agg(jsonb_build_object('key', x.state, 'subscriptions', coalesce(q.n, 0)) order by x.ord), '[]'::jsonb)
                        from (values ('paid', 1), ('in_retry', 2), ('failed', 3), ('paused', 4)) x(state, ord)
                        left join (select b.payment_state, count(*) as n from b group by 1) q on q.payment_state = x.state)),
    'notes', jsonb_build_object(
      'no_amount', (select count(*) from b where b.is_holding and b.is_paying and (b.monthly_amount is null or b.currency is null)),
      'unknown_channel', jsonb_build_object(
        'customers', (select count(*) from c where c.is_active and c.channel = 'unknown'),
        'reasons', (select coalesce(jsonb_object_agg(q.unknown_reason, q.n), '{}'::jsonb)
                    from (select c.unknown_reason, count(*) as n from c where c.is_active and c.channel = 'unknown' and c.unknown_reason is not null
                          group by 1) q))))
  into v_doc;
  return v_doc;
end
$$;
alter function cma.active_rest_body_of(uuid, text, text, text, timestamptz) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 4. The customer list under a band
-- ---------------------------------------------------------------------------------------------
-- One more argument each, so the earlier signatures go first (a second function under the same name would make a call
-- without the band ambiguous). A call without the band, as main's web makes it, resolves to the new ones
drop function if exists cma.active_rows(text, text, text, text, boolean, text, text, integer, boolean);
drop function if exists cma.active_rows_of(uuid, text, text, text, text, boolean, text, text, integer, timestamptz);
drop function if exists cma.active_file_record(text, text, text, integer);

-- The list's rows as 172's, with the band of Devices per active customer as one more filter of the rows and of the total
-- (a residual filter on the sort's index: the walk reads the customers of the other bands on its way)
-- based on: 172_active_customers.sql
create or replace function cma.active_rows_of(p_tenant_id uuid, p_market text, p_segment text, p_channel text, p_sort text,
                                              p_descending boolean, p_after text, p_before text, p_limit integer, p_now timestamptz,
                                              p_band text default null)
returns jsonb
language plpgsql stable
as $fn$
declare
  v_zone   text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_take   jsonb := cma.active_take_of(p_tenant_id, p_now);
  v_keys   text[];
  v_types  text[];
  v_cursor jsonb;
  v_back   boolean := p_before is not null;
  v_desc   boolean;
  v_at     text := '';
  v_order  text;
  v_rows   jsonb;
  v_more   boolean;
  v_total  bigint;
  i        integer;
  v_set_up boolean;
  v_dev_bounds integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'customers.device_bands'));
begin
  -- a statement, not an expression (as the reads' heads): its plan is made again when the role changes
  select coalesce(cma.flash_source_set_up_of(p_tenant_id, 'commerce'), false) and coalesce(cma.flash_source_set_up_of(p_tenant_id, 'subscriptions'), false)
  into v_set_up;
  if not v_set_up then
    return jsonb_build_object('set_up', false, 'history', false, 'take', null, 'time_zone', v_zone, 'total', 0, 'rows', '[]'::jsonb,
                              'next', null, 'prev', null);
  end if;
  if v_take is null then
    return jsonb_build_object('set_up', true, 'history', false, 'take', null, 'time_zone', v_zone, 'total', null, 'rows', '[]'::jsonb,
                              'next', null, 'prev', null);
  end if;
  -- the sort's key: expressions over cma.active_customer, each with its index (active_customer_*_idx). A fixed list:
  -- nothing of the caller's text reaches the statement but through parameters
  case p_sort
    when 'monthly_amount' then v_keys := array[$k$coalesce(c.currency, '')$k$, 'coalesce(c.amount, -1)']; v_types := array['text', 'numeric'];
    when 'clv' then v_keys := array[$k$coalesce(c.clv_currency, '')$k$, 'coalesce(c.clv, -1)']; v_types := array['text', 'numeric'];
    when 'store_customer' then v_keys := '{}'; v_types := '{}';
    when 'store' then v_keys := array['c.store']; v_types := array['text'];
    when 'market' then v_keys := array['c.market']; v_types := array['text'];
    when 'segment' then v_keys := array['c.segment']; v_types := array['text'];
    when 'channel' then v_keys := array['c.channel']; v_types := array['text'];
    when 'level' then v_keys := array[$k$coalesce(c.level, '')$k$]; v_types := array['text'];
    when 'customer_start' then v_keys := array[$k$coalesce(c.customer_start, '-infinity'::timestamptz)$k$]; v_types := array['timestamptz'];
    when 'age_months' then v_keys := array['coalesce(c.age_months, -1)']; v_types := array['integer'];
    when 'subscriptions' then v_keys := array['c.holding']; v_types := array['integer'];
    when 'devices' then v_keys := array['c.devices']; v_types := array['integer'];
    else raise exception 'not a sort key of the list' using errcode = 'CMA04';
  end case;
  -- a cursor is the id of a customer of the take: its row's key in this sort (the sort's values, the store customer's id
  -- and the customer's id) is read here, so no value of the caller's reaches a cast
  if p_after is not null or p_before is not null then
    if coalesce(p_after, p_before) !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'a cursor is the next or prev of a page of this list' using errcode = 'CMA04';
    end if;
    execute format($q$select jsonb_build_object('k', jsonb_build_array(%s), 's', c.source_id, 'i', c.customer_id)
                      from cma.active_customer c where c.tenant_id = $1 and c.customer_id = $2$q$, array_to_string(v_keys, ', '))
      into v_cursor
      using p_tenant_id, coalesce(p_after, p_before)::uuid;
    if v_cursor is null then
      raise exception 'a cursor is the next or prev of a page of this list' using errcode = 'CMA04';
    end if;
  end if;
  -- the scan's direction: the sort's, turned around to read the rows before a cursor
  v_desc := p_descending <> v_back;
  v_order := (select string_agg(k || case when v_desc then ' desc' else ' asc' end, ', ' order by o)
              from unnest(v_keys || array['c.source_id', 'c.customer_id']) with ordinality u(k, o));
  if v_cursor is not null then
    v_at := ' and (' || array_to_string(v_keys || array['c.source_id', 'c.customer_id'], ', ') || ')'
            || case when v_desc then ' < ' else ' > ' end || '('
            || coalesce((select string_agg(format($f$($6 -> 'k' ->> %s)::%s$f$, o - 1, t), ', ' order by o) || ', '
                         from unnest(v_types) with ordinality u(t, o)), '')
            || $f$$6 ->> 's', ($6 ->> 'i')::uuid)$f$;
  end if;
  execute format($q$
    with page as materialized (
      select c.*, row_number() over (order by %2$s) as pos
      from cma.active_customer c
      where c.tenant_id = $1 and c.is_active
        and ($2::text is null or c.market = $2) and ($3::text is null or c.segment = $3) and ($4::text is null or c.channel = $4)
        and ($8::text is null or cma.flash_count_band_of(c.devices, $9) = $8)%1$s
      order by %2$s
      limit $5 + 1
    ), ps as (
      %3$s
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'store_customer', page.source_id, 'store', page.store, 'market', page.market, 'segment', page.segment,
             'customer_start', (page.customer_start at time zone $7)::date, 'age_months', page.age_months,
             'subscriptions', page.holding, 'devices', page.devices, 'currency', page.currency,
             'monthly_amount', round(page.amount, 2), 'other_amounts', page.other_amounts,
             'clv', page.clv, 'clv_currency', page.clv_currency, 'payment_state', ps.worst, 'channel', page.channel, 'level', page.level,
             'contact_id', page.contact_source_id,
             'contact_url', cma.record_url(page.crm_connection_id, 'contact', page.contact_source_id),
             'cursor', page.customer_id) order by page.pos), '[]'::jsonb)
    from page left join ps on ps.customer_id = page.customer_id
  $q$, v_at, v_order,
     case when p_limit <= 200 then $ps$
      -- the worst payment state of each customer on the page: its subscriptions' states, read live for these alone
      select b.customer_id,
             (array['failed', 'in_retry', 'paused', 'paid'])[min(array_position(array['failed', 'in_retry', 'paused', 'paid'], p.payment_state))] as worst
      from cma.active_base b
      join cma.subscription_payment_state_of($1, array(select b2.subscription_id from cma.active_base b2
                                                       where b2.tenant_id = $1 and b2.customer_id in (select page.customer_id from page))) p
        on p.subscription_id = b.subscription_id
      where b.tenant_id = $1 and b.customer_id in (select page.customer_id from page)
      group by 1 $ps$
     else $ps$
      -- a file's rows (more than a page's 200): the worst payment state as the take holds it, of the file's as_of moment
      select b.customer_id,
             (array['failed', 'in_retry', 'paused', 'paid'])[min(array_position(array['failed', 'in_retry', 'paused', 'paid'], b.payment_state))] as worst
      from cma.active_base b
      where b.tenant_id = $1 and b.customer_id in (select page.customer_id from page)
      group by 1 $ps$ end)
    into v_rows
    using p_tenant_id, p_market, p_segment, p_channel, p_limit, v_cursor, v_zone, p_band, v_dev_bounds;
  v_more := jsonb_array_length(v_rows) > p_limit;
  if v_more then
    v_rows := v_rows - p_limit;                       -- the one row read beyond the page
  end if;
  if v_back then
    -- read backwards from the cursor: put the page back in the sort's order
    v_rows := (select coalesce(jsonb_agg(e.value order by e.ord desc), '[]'::jsonb) from jsonb_array_elements(v_rows) with ordinality e(value, ord));
  end if;
  select count(*) into v_total
  from cma.active_customer c
  where c.tenant_id = p_tenant_id and c.is_active
    and (p_market is null or c.market = p_market) and (p_segment is null or c.segment = p_segment) and (p_channel is null or c.channel = p_channel)
    and (p_band is null or cma.flash_count_band_of(c.devices, v_dev_bounds) = p_band);
  i := jsonb_array_length(v_rows);
  return jsonb_build_object(
    'set_up', true, 'history', true, 'take', v_take, 'as_of', v_take -> 'computed_at', 'time_zone', v_zone, 'total', v_total,
    'next', case when i > 0 and (v_back or v_more) then v_rows -> (i - 1) -> 'cursor' end,
    'prev', case when i > 0 and ((not v_back and v_cursor is not null) or (v_back and v_more)) then v_rows -> 0 -> 'cursor' end,
    'rows', (select coalesce(jsonb_agg(e.value - 'cursor' order by e.ord), '[]'::jsonb) from jsonb_array_elements(v_rows) with ordinality e(value, ord)));
end
$fn$;
alter function cma.active_rows_of(uuid, text, text, text, text, boolean, text, text, integer, timestamptz, text) set jit = off;

-- The list's page as 172's; the band is one of the tenant's bands (cma.flash_count_bands_of of customers.device_bands) or
-- CMA04, so a band kept in an address after the setting changed is refused, not answered with another band's rows
-- based on: 172_active_customers.sql
create or replace function cma.active_rows(p_market text default null, p_segment text default null, p_channel text default null,
                                           p_sort text default 'monthly_amount', p_descending boolean default true, p_after text default null,
                                           p_before text default null, p_limit integer default 50, p_file boolean default false,
                                           p_band text default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_active_filter(p_market, p_segment, p_channel);
  if p_sort is null or p_sort not in ('monthly_amount', 'clv', 'store_customer', 'store', 'market', 'segment', 'customer_start', 'age_months',
                                      'subscriptions', 'devices', 'channel', 'level') then
    raise exception 'the list sorts by monthly_amount, clv, store_customer, store, market, segment, customer_start, age_months, subscriptions, devices, channel or level'
      using errcode = 'CMA04';
  end if;
  if p_band is not null
     and not (p_band = any (cma.flash_count_bands_of(cma.flash_bounds_of(cma.setting_of(v_tenant, 'customers.device_bands'))))) then
    raise exception 'the band is one of the bands of customers.device_bands, such as 0, 1 or 3-5' using errcode = 'CMA04';
  end if;
  if p_after is not null and p_before is not null then
    raise exception 'a page continues after a cursor or ends before one, not both' using errcode = 'CMA04';
  end if;
  if coalesce(length(p_after), 0) > 36 or coalesce(length(p_before), 0) > 36 then
    raise exception 'a cursor is the next or prev of a page of this list' using errcode = 'CMA04';
  end if;
  if coalesce(p_file, false) then
    if p_after is not null or p_before is not null then
      raise exception 'a file takes no cursor' using errcode = 'CMA04';
    end if;
    return cma.active_rows_of(v_tenant, p_market, p_segment, p_channel, p_sort, coalesce(p_descending, true), null, null,
                              cma.setting_of(v_tenant, 'flash.file_max_rows')::integer, now(), p_band);
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'a list page holds 1 to 200 rows' using errcode = 'CMA04';
  end if;
  return cma.active_rows_of(v_tenant, p_market, p_segment, p_channel, p_sort, coalesce(p_descending, true), p_after, p_before, p_limit, now(), p_band);
end
$$;

-- The audit row of a file read as 172's, naming the band (one of the tenant's bands, as the list's)
-- based on: 172_active_customers.sql
create or replace function cma.active_file_record(p_market text, p_segment text, p_channel text, p_rows integer, p_band text default null)
returns void
language plpgsql
as $$
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_active_filter(p_market, p_segment, p_channel);
  if p_band is not null
     and not (p_band = any (cma.flash_count_bands_of(cma.flash_bounds_of(cma.setting_of(cma.current_tenant_id(), 'customers.device_bands'))))) then
    raise exception 'the band is one of the bands of customers.device_bands, such as 0, 1 or 3-5' using errcode = 'CMA04';
  end if;
  if p_rows is null or p_rows < 0 then
    raise exception 'a file record names its rows' using errcode = 'CMA04';
  end if;
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  values (cma.current_tenant_id(), 'active_file', 'insert', null,
          jsonb_strip_nulls(jsonb_build_object('market', p_market, 'segment', p_segment, 'channel', p_channel, 'band', p_band, 'rows', p_rows)),
          cma.current_user_id(), cma.current_actor_label());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.active_rows_of(uuid,text,text,text,text,boolean,text,text,integer,timestamptz,text)',
    'cma.active_rows(text,text,text,text,boolean,text,text,integer,boolean,text)',
    'cma.active_file_record(text,text,text,integer,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Every stored take computed again at the job's next run
-- ---------------------------------------------------------------------------------------------
-- As a settings save marks it (cma.active_take_mark_stale): the mark and its count, so a refresh that is running now
-- does not clear it. Once: a rerun of this script marks nothing
update cma.active_take t
set stale = true, stale_since = coalesce(t.stale_since, now()), stale_marks = t.stale_marks + 1
where not exists (select 1 from cma.schema_migration m where m.version = '0009r');

-- ---------------------------------------------------------------------------------------------
-- 7. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009r', 'Customers → Active: Devices per active customer (the devices in the field on a customer''s holding subscriptions) in the bands of the setting customers.device_bands (1,2,3,6,11), as the part device_customers of the below-the-fold document, the share of customers from the third bound on in the markets and the comparison, and a band filter on the customer list; the page''s Devices is that term from now on; every stored take is computed again once')
on conflict (version) do nothing;

commit;
reset role;
