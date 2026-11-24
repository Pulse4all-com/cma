-- =============================================================================================
-- 224_subscription_rates_start.sql: addition 0009zl, the month the Churn rate, the Failed rate and the movements start for
-- every store (subscriptions.rates_start_month)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics; the month is tenant configuration, empty by default (no floor). Runs
-- unchanged in every database, after 216_subscriptions_page.sql (0009zh). Rerunnable, forward-only, in one transaction
-- with a lock timeout. Run as your own IAM login: dev first, then 225_verify_subscription_rates_start.sql there (normal,
-- then provoked), then the verifies that read what this re-creates (a tenant without the setting answers as before; two
-- are edited by this change so they hold with a floor set: 213's A3 compares the facts' digest with the floor part, and
-- 217's block B sets no floor):
--   cma.check_tenant_setting()                 73, 101, 113, 121, 123, 137, 179, 211, 215 (as 214 named them, and 215)
--   cma.subscription_rate_start_of             211, 213 (directly and through cma.subscription_facts_refresh_of), 217
--   cma.subscription_facts_inputs_key_of       211, 213 (213 compares its digest with 210's: equal while the setting is
--                                              empty), 217
--   cma.subscriptions_page_of                  217 (through cma.subscriptions_page and cma.subscription_file_record)
-- grep -lw 'cma\.<function>' db/*verify*.sql for each. Prod: this script and 225 (its block B refuses prod's data, as
-- 211's and 217's do), then 213 (block A, edited), 211 and 217 (their block A reads the re-created functions' rights and
-- settings; block B refused) and 123, 137, 179 and 215 (they read cma.check_tenant_setting; 179's E5 reads FAIL on its old
-- copy's gap until #309); after the setting is seeded and the facts computed again, 225 and 213 once more; then the setting seeded as Martin decided (db/02_seed_pulse4all.sql,
-- PROD_RUNBOOK 22.4c), which the facts' next refresh takes; then 225 again (A5 reads the floor in the stored take).
--
-- Why (Martin, 23 November 2026): the subscription app's events before 28 January 2026 reached the CMA late or not at all
-- (#309, #311), and months from June 2026 are touched by inferred moves until #311's acceptance. Customers →
-- Subscriptions' Churn rate, Failed rate and movements, and Customers → Active's Churn rate card start at 1 June 2026 for
-- every store; a store's own later start (cma.subscription_store_start.rate_start_month, the month after its migration)
-- still applies on top. One date for every store, as tenant configuration: subscriptions.rates_start_month = 2026-06
-- (Option A of docs/analyses/2026-11-23-subscriptions-incomplete-months.md, one date instead of one per store). Renewal
-- survival is not floored: it reads the renewals, not the month take's complete months.
--
-- What it adds
--   setting    subscriptions.rates_start_month (text, YYYY-MM or empty; default empty: no floor), checked by
--              cma.check_tenant_setting()
-- What it re-creates (each from its latest definition; JIT, grants as there)
--   cma.check_tenant_setting()                 214: the month's form
--   cma.subscription_rate_start_of(uuid,timestamptz)   210: a store's rate_start_month is the later of its own and the
--                                              floor, so cma.subscription_store_start, the month take's complete flag,
--                                              the rates on the page, Active's card and cma_read.subscription_churn_month
--                                              follow it
--   cma.subscription_facts_inputs_key_of(uuid,date)    210: the setting in the digest when it is set, so setting it
--                                              computes the facts again at the minute job's next run
--   cma.subscriptions_page_of(…)               216: the months' movements from the floor on (months before it hold none),
--                                              and the floor in the page's document (rates_start_month); the tiles' last
--                                              complete month from it too, so a take computed before the floor was set
--                                              shows no earlier month until its next refresh. A store's own
--                                              later start floors its rates, as before, not its movements (216 never
--                                              floored the movements per store), as Martin decided on 23 November
--                                              2026 ("still applies on top": rates only)
-- Comments: cma.subscription_store_start and cma_read.subscription_store_start say rate_start_month holds the floor
-- No table, view or column changes; no stored row changes here (the facts change at their next refresh once the setting
-- is set). No index.
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
  if not exists (select 1 from cma.schema_migration where version = '0009zh') then
    raise exception 'addition 0009zh (216_subscriptions_page.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The setting
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('subscriptions.rates_start_month', 'text', null, '',
     'The month (YYYY-MM) from which the Churn rate, the Failed rate and the movements by month start for every store on Customers → Subscriptions, and Customers → Active''s Churn rate card; a store''s own later start (the month after its migration) still applies; empty means no floor. Renewal survival is not floored (addition 0009zl)')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0009zg's (214), with the month of subscriptions.rates_start_month
-- based on: 214_source_figures.sql
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
  if new.key in ('email.start_date', 'reviews.history_start_date', 'courtesy.start_date',
                 'subscriptions.history_start_date') then
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
  if s.value_type = 'date' or (new.key in ('email.start_date', 'reviews.history_start_date', 'courtesy.start_date',
                 'subscriptions.history_start_date') and new.value <> '') then
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
  elsif new.key in ('flash.snapshot_local_time', 'source_figures.local_time') and new.value = '24:00' then
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
  -- the subscription facts (0009ze): the propositions of the variant mapping, and the age after which the takes are computed
  -- again
  elsif new.key = 'subscriptions.propositions' and not cma.flash_list_ok(new.value, '^[a-z][a-z0-9_]{0,39}$', 20, true) then
    raise exception 'Setting % takes up to twenty codes (a lower case letter, then lower case letters, digits and _, at most 40 each), each once, comma-separated without spaces, such as hs1,frx, or nothing', new.key
      using errcode = 'CMA04';
  elsif new.key = 'subscriptions.migration_bulk_min_pct'
        and (case when length(new.value) > 3 then true else new.value::integer not between 1 and 100 end) then
    raise exception 'Setting % takes a whole number of percent from 1 to 100', new.key using errcode = 'CMA04';
  elsif new.key = 'subscriptions.take_refresh_minutes'
        and (case when length(new.value) > 4 then true else new.value::integer not between 1 and 1440 end) then
    raise exception 'Setting % takes a whole number of minutes from 1 to 1440', new.key using errcode = 'CMA04';
  -- the month the Churn rate, the Failed rate and the movements start for every store (0009zl), or nothing (no floor)
  elsif new.key = 'subscriptions.rates_start_month' and new.value <> '' and new.value !~ '^(20[0-9]{2}|2100)-(0[1-9]|1[0-2])$' then
    raise exception 'Setting % takes a month from 2000-01 to 2100-12 as YYYY-MM, such as 2026-06, or nothing (no floor)', new.key using errcode = 'CMA04';
  -- the subscription app's own figures (0009zg): a gap's tolerance, in percent of the source's value and in the figure's unit
  elsif new.key = 'source_figures.tolerance_pct'
        and (case when length(new.value) > 3 then true else new.value::integer not between 0 and 100 end) then
    raise exception 'Setting % takes a whole number of percent from 0 to 100', new.key using errcode = 'CMA04';
  elsif new.key = 'source_figures.tolerance_min'
        and (case when length(new.value) > 7 then true else new.value::integer not between 0 and 1000000 end) then
    raise exception 'Setting % takes a whole number from 0 to 1,000,000', new.key using errcode = 'CMA04';
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
-- 2. A store's rate start: the later of its own and the tenant's floor
-- ---------------------------------------------------------------------------------------------
-- As 0009ze's (210), with the floor
-- based on: 210_subscription_facts.sql
create or replace function cma.subscription_rate_start_of(p_tenant_id uuid, p_now timestamptz)
returns table (connection_id uuid, first_event_month date, migration_months jsonb, last_migration_month date,
               straggler_months jsonb, stragglers integer, rate_start_month date)
language sql stable
rows 50
as $$
  with z as materialized (
    select t.timezone as zone, cma.setting_of(p_tenant_id, 'subscriptions.migration_bulk_min_pct')::numeric as pct,
           -- 0009zl: the tenant's floor, the first day of subscriptions.rates_start_month, or null (no floor)
           to_date(nullif(cma.setting_of(p_tenant_id, 'subscriptions.rates_start_month'), '') || '-01', 'YYYY-MM-DD') as floor_month
    from cma.tenant t where t.id = p_tenant_id
  ), fe as materialized (
    select e.connection_id, date_trunc('month', min(e.occurred_at) at time zone (select z.zone from z))::date as first_month
    from cma.subscription_event e
    where e.tenant_id = p_tenant_id and e.occurred_at <= p_now
    group by 1
  ), mm as materialized (
    select e.connection_id, date_trunc('month', e.occurred_at at time zone (select z.zone from z))::date as month, count(*) as n
    from cma.subscription_event e
    where e.tenant_id = p_tenant_id and e.event_type = 'migrated' and e.occurred_at <= p_now
    group by 1, 2
  ), mt as (
    select m.connection_id, m.month, m.n, m.n * 100.0 / sum(m.n) over (partition by m.connection_id) >= (select z.pct from z) as bulk
    from mm m
  ), lb as (
    -- the last month holding the share; a store whose migration is spread so thin that no month holds it takes its
    -- busiest month (the latest of equals), so a store with migrated events never starts as one without
    select t.connection_id,
           coalesce(max(t.month) filter (where t.bulk), (array_agg(t.month order by t.n desc, t.month desc))[1]) as last_month
    from mt t group by 1
  )
  select fe.connection_id, fe.first_month,
         coalesce((select jsonb_object_agg(to_char(t.month, 'YYYY-MM'), t.n) from mt t where t.connection_id = fe.connection_id), '{}'),
         lb.last_month,
         coalesce((select jsonb_object_agg(to_char(t.month, 'YYYY-MM'), t.n) from mt t
                   where t.connection_id = fe.connection_id and not t.bulk and t.month > lb.last_month), '{}'),
         coalesce((select sum(t.n) from mt t where t.connection_id = fe.connection_id and not t.bulk and t.month > lb.last_month), 0)::integer,
         -- the later of the store's own start and the tenant's floor (greatest passes over a null floor)
         greatest((coalesce(lb.last_month, fe.first_month) + interval '1 month')::date, (select z.floor_month from z))
  from fe
  left join lb on lb.connection_id = fe.connection_id
$$;
alter function cma.subscription_rate_start_of(uuid, timestamptz) set jit = off;

-- The store starts' table and its reader say what rate_start_month now holds
comment on table cma.subscription_store_start is
  'Per subscriptions connection (store) with an event (addition 0009ze): the month of its first event, its migrated events per month (YYYY-MM: count), the last month that holds at least subscriptions.migration_bulk_min_pct of them, the later months below that share (stragglers, reported, never moving the start) and the month its Churn rate and Failed rate start: the month after that last migration month, else the first complete month after its first event, and since 0009zl not before the tenant''s subscriptions.rates_start_month when that is set';
comment on view cma_read.subscription_store_start is
  'Per store of every tenant the reader sees (addition 0009ze): its migrated events per month, the last month of its migration, its stragglers and the month its Churn rate and Failed rate start (since 0009zl not before the tenant''s subscriptions.rates_start_month when that is set). Counts and months only';

-- ---------------------------------------------------------------------------------------------
-- 3. The facts' inputs: the floor, when it is set
-- ---------------------------------------------------------------------------------------------
-- As 0009ze's (210), with the setting
-- based on: 210_subscription_facts.sql
create or replace function cma.subscription_facts_inputs_key_of(p_tenant_id uuid, p_today date)
returns text
language sql stable
as $$
  select md5(concat_ws('|',
    array_to_string(cma.inputs_markers_of(p_tenant_id,
      array['subscription', 'subscription_event', 'commerce_order', 'commerce_store', 'device_model', 'market', 'integration_connection',
            'timezone', 'billing_event', 'subscription_line', 'subscription_product_variant', 'subscription_variant_mapping',
            'subscription_change']), '|'),
    cma.setting_of(p_tenant_id, 'flash.ended_subscription_statuses'), cma.setting_of(p_tenant_id, 'flash.device_holding_statuses'),
    cma.setting_of(p_tenant_id, 'subscriptions.propositions'), cma.setting_of(p_tenant_id, 'subscriptions.migration_bulk_min_pct'),
    p_today::text,
    -- 0009zl: the floor of the rates, only when it is set (concat_ws passes over a null), so a tenant without it keeps
    -- 210's digest and setting it computes the facts again
    nullif(cma.setting_of(p_tenant_id, 'subscriptions.rates_start_month'), '')))
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Customers → Subscriptions: the movements from the floor on
-- ---------------------------------------------------------------------------------------------
-- As 0009zh's (216), with the floor
-- based on: 216_subscriptions_page.sql
create or replace function cma.subscriptions_page_of(p_tenant_id uuid, p_market text, p_store uuid, p_proposition text, p_interval text,
                                                     p_from date, p_to date, p_measure text, p_sort text, p_descending boolean,
                                                     p_now timestamptz, p_page integer default 1)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone     text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_holding  text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.device_holding_statuses'));
  v_active   text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.active_subscription_statuses'));
  v_ended    text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.ended_subscription_statuses'));
  v_dbounds  integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.device_bands'));
  v_abounds  integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.subscription_age_months'));
  v_props    text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'subscriptions.propositions'));
  v_fx       jsonb := cma.active_fx_of(p_tenant_id);
  -- 0009zl: the month the movements start for every store (subscriptions.rates_start_month), or null (no floor); the rates
  -- follow it through the month take's complete flag
  v_floor    date := to_date(nullif(cma.setting_of(p_tenant_id, 'subscriptions.rates_start_month'), '') || '-01', 'YYYY-MM-DD');
  v_state    cma.subscription_take_state;
  v_doc      jsonb;
begin
  select * into v_state from cma.subscription_take_state s where s.tenant_id = p_tenant_id;
  v_doc := jsonb_build_object(
    'history', v_state.tenant_id is not null,
    'take', case when v_state.tenant_id is null then null
                 else jsonb_build_object('computed_at', v_state.computed_at, 'business_date', v_state.business_date,
                                         'amounts_from', v_state.amounts_from) end,
    'time_zone', v_zone,
    'today', (p_now at time zone v_zone)::date,
    'month', date_trunc('month', p_now at time zone v_zone)::date,
    'from', p_from, 'to', p_to,
    'filter', jsonb_build_object('market', p_market, 'store', p_store, 'proposition', p_proposition, 'interval', p_interval),
    'settings', jsonb_build_object('holding', to_jsonb(v_holding), 'active', to_jsonb(v_active), 'ended', to_jsonb(v_ended),
                                   'device_bands', to_jsonb(cma.flash_count_bands_of(v_dbounds)),
                                   'age_bands', to_jsonb(cma.flash_age_bands_of(v_abounds)),
                                   'fx', case when v_fx = '{}'::jsonb then null else v_fx end,
                                   'propositions', to_jsonb(v_props),
                                   'history_months', cma.setting_of(p_tenant_id, 'customers.history_months')::integer),
    'filters', jsonb_build_object(
      'markets', (select coalesce(jsonb_agg(m.market order by (m.market = 'unknown'), mk.sort_order, m.market collate "C"), '[]'::jsonb)
                  from (select distinct x.market from cma.subscription_store_start x where x.tenant_id = p_tenant_id
                        union select distinct t.market from cma.subscription_take t where t.tenant_id = p_tenant_id) m
                  left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = m.market),
      'stores', (select coalesce(jsonb_agg(jsonb_build_object('connection_id', y.connection_id, 'handle', y.handle,
                                                             'market', coalesce(y.market, 'unknown'))
                                           order by coalesce(y.market, 'unknown') collate "C", y.handle collate "C"), '[]'::jsonb)
                 from cma.flash_subscription_stores_of(p_tenant_id) y),
      'propositions', to_jsonb(v_props || array['none']),
      'intervals', to_jsonb(array['monthly', 'quarterly', 'yearly', 'other', 'unknown'])));
  if v_state.tenant_id is null then
    return v_doc || jsonb_build_object('tiles', null, 'months', '[]'::jsonb, 'rates', '[]'::jsonb, 'store_starts', '[]'::jsonb,
                                       'survival', null, 'mix', null, 'list', null);
  end if;

  -- the tiles and the mix: one scan of the take under the filters
  with t as materialized (
    select x.* from cma.subscriptions_scope_of(p_tenant_id, p_market, p_store, p_proposition, p_interval) x
  ), h as materialized (
    select t.* from t where t.status = any (v_holding)
  ), inst as materialized (
    -- the payment instrument's type and the app's created date of the tenant's present subscriptions (the mirror's row by
    -- its key; one scan of the tenant's rows, joined by hash: a lookup per subscription costs more at this size)
    select s.id, s.payment_instrument_type, s.source_created_at from cma.subscription s
    where s.tenant_id = p_tenant_id and s.source_deleted_at is null
  ), ages as (
    -- Subscription age (Flash's: whole months since the app's created date; the original start (estimated) waits for the
    -- hand check, Decision log 20 Nov 2026), grouped first: the band is then named once per distinct age
    select case when i.source_created_at is null then null
                else (extract(year from age(p_now, i.source_created_at)) * 12 + extract(month from age(p_now, i.source_created_at)))::integer end as months,
           count(*) as n
    from h left join inst i on i.id = h.subscription_id group by 1
  ), amt as (
    select t.currency, round(sum(t.monthly_amount), 2) as amount, count(*) as subscriptions
    from t where t.status = any (v_active) and t.currency is not null and t.monthly_amount is not null
    group by t.currency
  )
  select v_doc || jsonb_build_object(
    'tiles', jsonb_build_object(
      'total', jsonb_build_object('value', (select count(*) from h),
                                  'by_status', (select coalesce(jsonb_object_agg(u.s, (select count(*) from h where h.status = u.s)), '{}'::jsonb)
                                                from unnest(v_holding) u(s))),
      'paused', (select count(*) from t where t.status = 'paused'),
      'amounts', (select coalesce(jsonb_agg(jsonb_build_object('currency', a.currency, 'amount', a.amount, 'subscriptions', a.subscriptions)
                                            order by a.currency collate "C"), '[]'::jsonb) from amt a),
      'eur', case when exists (select 1 from amt)
                       and not exists (select 1 from amt a where cma.active_eur_of(a.amount, a.currency, v_fx) is null)
                  then jsonb_build_object('amount', (select round(sum(cma.active_eur_of(a.amount, a.currency, v_fx)), 2) from amt a),
                                          'as_of', v_fx ->> 'as_of') end,
      'devices', jsonb_build_object('units', (select coalesce(sum(h.device_units), 0) from h),
                                    'unmapped', (select count(*) from h where h.device_units is null)),
      'source_counts', cma.subscriptions_source_counts_of(p_tenant_id, p_market, p_store, p_proposition, p_interval, p_now)),
    'mix', jsonb_build_object(
      'proposition', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'subscriptions', z.n) order by z.n desc, z.k collate "C"), '[]'::jsonb)
                      from (select coalesce(p.p, 'none') as k, count(*) as n
                            from h left join lateral unnest(nullif(h.propositions, '{}')) p(p) on true group by 1) z),
      'model', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'label', md.name, 'subscriptions', z.n)
                                          order by z.n desc, z.k collate "C"), '[]'::jsonb)
                from (select coalesce(m.m, 'none') as k, count(*) as n
                      from h left join lateral unnest(nullif(h.models, '{}')) m(m) on true group by 1) z
                left join cma.device_model md on md.tenant_id = p_tenant_id and md.key = z.k),
      'interval', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'subscriptions', z.n)
                                             order by array_position(array['monthly', 'quarterly', 'yearly', 'other', 'unknown'], z.k)), '[]'::jsonb)
                   from (select h.interval_group as k, count(*) as n from h group by 1) z),
      'device_band', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'subscriptions', z.n)
                                                order by coalesce(array_position(cma.flash_count_bands_of(v_dbounds), z.k), 99)), '[]'::jsonb)
                      from (select coalesce(cma.flash_count_band_of(d.units, v_dbounds), 'unmapped') as k, sum(d.n) as n
                            from (select h.device_units as units, count(*) as n from h group by 1) d group by 1) z),
      'age_band', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'subscriptions', z.n)
                                             order by coalesce(array_position(cma.flash_age_bands_of(v_abounds), z.k), 99)), '[]'::jsonb)
                   from (select case when a.months is null then 'unknown' else cma.flash_age_band_of(a.months, v_abounds) end as k, sum(a.n) as n
                         from ages a group by 1) z),
      'instrument', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'subscriptions', z.n) order by z.n desc, z.k collate "C"), '[]'::jsonb)
                     from (select coalesce(i.payment_instrument_type, 'unknown') as k, count(*) as n
                           from h left join inst i on i.id = h.subscription_id group by 1) z),
      'payment_state', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'subscriptions', z.n)
                                                  order by coalesce(ps.sort_order, 99), z.k collate "C"), '[]'::jsonb)
                        from (select coalesce(h.payment_state, 'unknown') as k, count(*) as n from h group by 1) z
                        left join cma.payment_states() ps on ps.key = z.k)),
    'migrated_left_out', (select count(*) from t where t.migrated))
  into v_doc;

  -- the months, the rates, the stores' starts: the month take under the market and store filters
  with m as materialized (
    select x.connection_id, x.market, x.month, x.kind, x.currency, x.subscriptions, x.amount, x.complete
    from cma.subscription_month_take x
    where x.tenant_id = p_tenant_id and x.month between greatest(p_from, coalesce(v_floor, p_from)) and p_to
      and (p_market is null or x.market = p_market) and (p_store is null or x.connection_id = p_store)
  ), last_complete as (
    select max(x.month) as month
    from cma.subscription_month_take x
    where x.tenant_id = p_tenant_id and x.currency = '' and x.complete and x.month <= p_to and x.month >= coalesce(v_floor, x.month)
      and (p_market is null or x.market = p_market) and (p_store is null or x.connection_id = p_store)
  ), lc as (
    select l.month,
           sum(x.subscriptions) filter (where x.kind = 'start') as base,
           coalesce(sum(x.subscriptions) filter (where x.kind = 'churned'), 0) as churned,
           coalesce(sum(x.subscriptions) filter (where x.kind = 'moved_to_failed'), 0) as moved_to_failed
    from last_complete l
    join cma.subscription_month_take x on x.tenant_id = p_tenant_id and x.month = l.month and x.currency = '' and x.complete
                                       and (p_market is null or x.market = p_market) and (p_store is null or x.connection_id = p_store)
    group by l.month
  ), g as (
    select g::date as month from generate_series(p_from, p_to, interval '1 month') g
  )
  select v_doc || jsonb_build_object(
      'months', (select coalesce(jsonb_agg(jsonb_build_object(
                   'month', g.month,
                   'counts', (select jsonb_object_agg(k.kind, k.n) from (select m.kind, sum(m.subscriptions) as n from m
                                                                         where m.month = g.month and m.currency = '' group by m.kind) k),
                   'amounts', (select jsonb_object_agg(c.currency, c.kinds) from (
                                 select a.currency, jsonb_object_agg(a.kind, a.amount) as kinds
                                 from (select m.currency, m.kind, sum(m.amount) as amount from m
                                       where m.month = g.month and m.currency <> '' and m.amount is not null group by 1, 2) a
                                 group by a.currency) c),
                   'complete', (select jsonb_build_object('base', sum(m.subscriptions) filter (where m.kind = 'start'),
                                                          'churned', coalesce(sum(m.subscriptions) filter (where m.kind = 'churned'), 0),
                                                          'moved_to_failed', coalesce(sum(m.subscriptions) filter (where m.kind = 'moved_to_failed'), 0))
                                from m where m.month = g.month and m.currency = '' and m.complete
                                having count(*) > 0))
                 order by g.month), '[]'::jsonb) from g),
      'rates', (select coalesce(jsonb_agg(jsonb_build_object('market', r.market, 'month', r.month, 'base', r.base, 'churned', r.churned,
                                                             'moved_to_failed', r.moved_to_failed)
                                          order by r.market collate "C", r.month), '[]'::jsonb)
                from (select m.market, m.month,
                             sum(m.subscriptions) filter (where m.kind = 'start') as base,
                             coalesce(sum(m.subscriptions) filter (where m.kind = 'churned'), 0) as churned,
                             coalesce(sum(m.subscriptions) filter (where m.kind = 'moved_to_failed'), 0) as moved_to_failed
                      from m where m.currency = '' and m.complete group by 1, 2) r),
      'store_starts', (select coalesce(jsonb_agg(jsonb_build_object('connection_id', s.connection_id, 'handle', y.handle, 'market', s.market,
                                                                   'first_event_month', s.first_event_month,
                                                                   'rate_start_month', s.rate_start_month, 'stragglers', s.stragglers)
                                                 order by s.market collate "C", y.handle collate "C"), '[]'::jsonb)
                       from cma.subscription_store_start s
                       left join cma.flash_subscription_stores_of(p_tenant_id) y on y.connection_id = s.connection_id
                       where s.tenant_id = p_tenant_id
                         and (p_market is null or s.market = p_market) and (p_store is null or s.connection_id = p_store)),
      'last_complete', (select jsonb_build_object('month', lc.month, 'base', lc.base, 'churned', lc.churned,
                                                  'moved_to_failed', lc.moved_to_failed) from lc),
      'rates_start_month', v_floor)
  into v_doc;
  -- the last complete month's rates go with the tiles
  v_doc := jsonb_set(v_doc, '{tiles,rates}', coalesce(v_doc -> 'last_complete', 'null'::jsonb)) - 'last_complete';

  -- renewal survival: the take of cells under the market, store and interval filters, cohorts in the range
  select v_doc || jsonb_build_object('survival', jsonb_build_object(
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object('interval', gr.interval_group, 'cohorts', gr.cohorts) order by array_position(array['monthly', 'quarterly', 'yearly', 'other', 'unknown'], gr.interval_group))
      from (select c.interval_group,
                   jsonb_agg(jsonb_build_object('cohort', c.cohort_month, 'started', c.started, 'cells', c.cells) order by c.cohort_month) as cohorts
            from (select v.interval_group, v.cohort_month, max(v.started) filter (where v.renewal_number = 1) as started,
                         jsonb_agg(jsonb_build_object('renewal', v.renewal_number, 'eligible', v.eligible, 'survived', v.survived) order by v.renewal_number) as cells
                  from (select x.interval_group, x.cohort_month, x.renewal_number,
                               sum(x.started) as started, sum(x.eligible) as eligible, sum(x.survived) as survived
                        from cma.subscription_survival_take x
                        where x.tenant_id = p_tenant_id and x.cohort_month between p_from and p_to
                          and (p_market is null or x.market = p_market) and (p_store is null or x.connection_id = p_store)
                          and (p_interval is null or x.interval_group = p_interval)
                        group by 1, 2, 3) v
                  where v.eligible > 0 or v.renewal_number = 1
                  group by 1, 2) c
            group by c.interval_group) gr), '[]'::jsonb)))
  into v_doc;
  v_doc := jsonb_set(v_doc, '{survival,migrated_left_out}', v_doc -> 'migrated_left_out') - 'migrated_left_out';

  return v_doc || jsonb_build_object('list', cma.subscription_rows_of(p_tenant_id, p_market, p_store, p_proposition, p_interval,
                                                                       p_measure, p_sort, p_descending, coalesce(p_page, 1), 50, false, p_now));
end
$$;

do $$
declare
  f text;
begin
  foreach f in array array['cma.subscription_rate_start_of(uuid,timestamptz)', 'cma.subscription_facts_inputs_key_of(uuid,date)',
                           'cma.subscriptions_page_of(uuid,text,uuid,text,text,date,date,text,text,boolean,timestamptz,integer)'] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- JIT off, as 216 set it on the page's reads
  execute 'alter function cma.subscriptions_page_of(uuid,text,uuid,text,text,date,date,text,text,boolean,timestamptz,integer) set jit = off';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zl', 'The month the Churn rate, the Failed rate and the movements start for every store: the setting subscriptions.rates_start_month (YYYY-MM, empty: no floor), checked by cma.check_tenant_setting(); cma.subscription_rate_start_of takes the later of a store''s own start and the floor; cma.subscription_facts_inputs_key_of holds the setting when it is set; cma.subscriptions_page_of shows the movements from the floor on and names it (rates_start_month); renewal survival not floored')
on conflict (version) do nothing;

commit;
reset role;
