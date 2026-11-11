-- =============================================================================================
-- 172_active_customers.sql: addition 0009l, Customers → Active (the active customer base: its state and its movement)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: the statuses a figure counts, the segments, the ages, the history's
-- length and the indicative rates are the tenant's settings; the stores, markets and models its catalogs. Runs unchanged
-- in every database, after 170_live_inbound_talk.sql (0009k). Rerunnable, forward-only, additive, in one transaction with
-- a lock timeout. Run as your own IAM login: dev first, then 173_verify_active_customers.sql there (normal, then
-- provoked), then the verifies that read cma.check_tenant_setting() again, the one function this script re-creates.
-- Directly (grep -lw 'cma\.check_tenant_setting' db/*verify*.sql): 73_verify_follow_up.sql,
-- 101_verify_definitions_calls.sql, 113_verify_assets.sql, 121_verify_lead_cohorts.sql, 123_verify_flash.sql and
-- 137_verify_flash_insights.sql (each reads the function's source for the branches 172 keeps). Through its trigger
-- check_value on cma.tenant_setting, which every cma.set_tenant_setting reaches: 14_verify_tenant_settings.sql and
-- 151_verify_courtesy.sql (the refusals of 150, the definition 172 starts from). All unchanged, still PASS: the function
-- keeps every earlier rule in its order and gains four keys; no function or view calls it, so no verify reads it through
-- a caller, and no existing verify is edited by this change. 85_verify_first_orders.sql is optional (cma.first_orders_of
-- is read here, not re-created). Then seed 02 (Pulse4all's three customers settings and the empty rates) and, in dev,
-- seed 03 (the test rates and the synthetic base); then 131_time_all.sql part b, which gains the page's two rows and
-- refuses to run before 0009l.
-- Prod: this script just before the merge (docs/RUNBOOK.md's usual order). The web of main runs unchanged on it: nothing
-- main reads changes. The web of this change reads cma.active_page and cma.active_rows, and the merge deploys it, so a
-- merge before this script would leave Customers → Active failing in prod until it has run. After the merge: 173 and
-- the verifies above, seed 02 and 131 part b in prod, without seed 03.
--
-- Why (Martin, 11 November 2026, brief B35 with addendum A; Decision log): the sales director, Kira, Peter and Bas open
-- one page first for the state and the movement of the customer base: who the active customers are, in which markets and
-- segments, direct or indirect, how long they stay, what they are worth, how the base grows and shrinks, how cohorts
-- retain. One fact one source: the store's customers (commerce, 0007b) with their CRM contact (0008h) and its segment
-- (0008zt), the subscription app's subscriptions and events (0008zl), the asset register's devices (0008zi), First
-- orders' attribution (0008u) and the tenant's settings. Flash's population unchanged (0008zu): an Active customer is a
-- store customer with a subscription in a device-holding status; Total subscriptions are the subscriptions in one.
--
-- Definitions (docs/definitions.md, Active customer terms):
--   Customer start     the earliest of the store customer's creation and the creation of any of its subscriptions here
--   Customer age       whole months from the Customer start to the business date (cma.flash_age_months_of)
--   Monthly recurring amount   per currency, the subscriptions in a device-holding status that pay (a status of
--                      flash.active_subscription_statuses), each at its amount per cycle turned into a month
--                      (cma.active_month_factor_of). The subscription app's contracted amount, not revenue
--   Ended time         a subscription's canceled_at, else its latest event into a status of
--                      flash.ended_subscription_statuses, else unknown (left out of the history, counted in a note)
--   active spell       a maximal stretch in which at least one of a store customer's subscriptions holds, by the
--                      reconstruction: from its creation to its Ended time, the start of its current pause, or still.
--                      Inflow: a spell starting in a month; Outflow: one ending in it. Past pauses are not read
--   Customer cohort    the customers by the month or quarter of their Customer start, followed at the ages of
--                      customers.cohort_ages_months: the share still in a spell at their own start plus the age
--   Customer lifetime  the median of a Kaplan–Meier survival curve over the spells in whole months (an ended spell an
--                      event at its length, an active one censored at its age); "not reached" while the curve stays
--                      above 50 %. Retention (customer) at an age: the curve's survival at that age
--   Customer lifetime value (realised)   the store's amount spent of a store customer, in the store's currency
--   Acquisition channel   indirect (First orders' attribution call_center of the customer's first order), direct
--                      (self_service) or unknown, with the reason
--
-- What it adds
--   settings          customers.cohort_ages_months (3,6,12,24,36; one to eight increasing, each at most 120),
--                     customers.age_months (12,24,36,48,60; one to ten), customers.history_months (60; 12 to 120),
--                     reports.fx_eur_rates ({}; a JSON object of currency codes with the euros one unit is worth and an
--                     as_of date; cma.active_fx_ok); cma.check_tenant_setting() as 0009a's (150) with the four
--   pure functions    cma.active_spells_from, cma.active_month_cube_from, cma.active_cohort_cube_from, cma.active_km_from
--                     (arrays in, rows out: no table read, so 173 proves them on hand-made arrays against brute force),
--                     cma.active_month_factor_of, cma.active_billing_of, cma.active_eur_of, cma.active_km_json
--   reads             cma.active_base_of (the subscriptions with their holding interval, their store customer with
--                     Flash's own figures of it, and its acquisition channel: read once per request),
--                     cma.active_customers_of, cma.active_spells_of(tenant), cma.active_channel_of(tenant),
--                     cma.active_spell_lengths_of, cma.active_survival_of(tenant, split), cma.active_months_of,
--                     cma.active_cohorts_of
--   page              cma.active_page(from_month, market, segment, channel, grouping) and cma.active_rows(market,
--                     segment, channel, sort, descending, offset, limit, file) (reports.view or performance.team,
--                     CMA06), cma.active_file_record (the audit row of a file read)
--   readers           cma_read.active_customer_month and cma_read.customer_cohort over SECURITY DEFINER functions:
--                     counts per month or cohort, market, segment and acquisition channel; no customer, no contact
-- No table, and no column of a table: every figure is computed when read. No index: the reads use
-- subscription_event_subscription_idx and subscription_event_occurred_idx (118), the customers' unique key and primary
-- key (36) and First orders' own (84, 90).
--
-- Everything is SECURITY INVOKER and executable by the application only; the two cma_read functions are SECURITY DEFINER,
-- owned by cma_owner, search path pinned, executable by readers only.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA04 invalid, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0009k') then
    raise exception 'addition 0009k (170_live_inbound_talk.sql) must run before 0009l';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('customers.cohort_ages_months', 'text', null, '3,6,12,24,36',
     'The ages in months at which Customers → Active follows each customer cohort: one to eight increasing whole numbers, each at most 120'),
  ('customers.age_months', 'text', null, '12,24,36,48,60',
     'The bounds in months of the Customer age bands on Customers → Active: one to ten increasing whole numbers; the first three are the ages of "More than" and of Retention'),
  ('customers.history_months', 'integer', null, '60',
     'The months of history Customers → Active shows at most (its range All), 12 to 120'),
  ('reports.fx_eur_rates', 'text', null, '{}',
     'Indicative rates for an approximate euro total: a JSON object of currency codes with the euros one unit is worth and the date they are of, such as {"as_of": "2026-11-01", "GBP": 1.15}; {} shows no euro total')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0009a (150), with the four settings of Customers → Active: the customer cohorts' ages, the Customer age bands (both
-- stripped of spaces, as the other lists of whole numbers), the history's months and the indicative euro rates
-- based on: 150_courtesy.sql
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
                 'customers.cohort_ages_months', 'customers.age_months') then
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
  elsif new.key = 'customers.history_months'
        and (case when length(new.value) > 3 then true else new.value::integer not between 12 and 120 end) then
    raise exception 'Setting % takes a whole number of months from 12 to 120', new.key using errcode = 'CMA04';
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
-- 2. The settings as values, and the pure functions (no table read: arrays in, rows out)
-- ---------------------------------------------------------------------------------------------
-- reports.fx_eur_rates' form: a JSON object, {} or an "as_of" date (YYYY-MM-DD, a real date) with at least one currency
-- code (three capitals) and its rate, a number above 0: the euros one unit of that currency is worth. Never an @
create or replace function cma.active_fx_ok(p_value text)
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
  if j is null or jsonb_typeof(j) <> 'object' or strpos(p_value, '@') > 0 or length(p_value) > 2000 then
    return false;
  end if;
  if j = '{}'::jsonb then
    return true;
  end if;
  if jsonb_typeof(j -> 'as_of') is distinct from 'string' or (j ->> 'as_of') !~ '^\d{4}-\d{2}-\d{2}$' then
    return false;
  end if;
  begin
    perform (j ->> 'as_of')::date;
  exception when others then
    return false;
  end;
  return exists (select 1 from jsonb_each(j) e where e.key <> 'as_of')
     and not exists (select 1 from jsonb_each(j) e
                     where e.key <> 'as_of'
                       and (e.key !~ '^[A-Z]{3}$'
                            or case when jsonb_typeof(e.value) = 'number'
                                    then (e.value #>> '{}')::numeric <= 0 or (e.value #>> '{}')::numeric > 1000000
                                    else true end));
end
$$;

-- The tenant's indicative rates: the setting as JSON ({} while unset)
create or replace function cma.active_fx_of(p_tenant_id uuid)
returns jsonb
language sql stable
as $$
  select coalesce(nullif(cma.setting_of(p_tenant_id, 'reports.fx_eur_rates'), '')::jsonb, '{}'::jsonb)
$$;

-- The euros an amount in a currency is worth at the tenant's indicative rates: the amount itself for EUR, null for a
-- currency the setting holds no rate for (never a guess)
create or replace function cma.active_eur_of(p_amount numeric, p_currency text, p_fx jsonb)
returns numeric
language sql immutable
as $$
  select case when p_amount is null or p_currency is null then null
              when p_currency = 'EUR' then p_amount
              when jsonb_typeof(p_fx -> p_currency) = 'number' then p_amount * (p_fx ->> p_currency)::numeric end
$$;

-- The factor that turns an amount per billing cycle into an amount per month (Monthly recurring amount): a day
-- 365.25/12, a week 365.25/84, a month 1, a year 1/12, each divided by the cycle's count of them; null without either
create or replace function cma.active_month_factor_of(p_interval text, p_count integer)
returns numeric
language sql immutable
as $$
  select case when p_count is null or p_count < 1 then null
              else case p_interval when 'day' then 365.25 / 12 when 'week' then 365.25 / 84 when 'month' then 1 when 'year' then 1.0 / 12 end
                   / p_count end
$$;

-- A subscription's billing interval as the subscription mix shows it: monthly (every month), yearly (every year), other
-- (any other cycle), unknown without one
create or replace function cma.active_billing_of(p_interval text, p_count integer)
returns text
language sql immutable
as $$
  select case when p_interval is null or p_count is null then 'unknown'
              when p_interval = 'month' and p_count = 1 then 'monthly'
              when (p_interval = 'year' and p_count = 1) or (p_interval = 'month' and p_count = 12) then 'yearly'
              else 'other' end
$$;

-- The active spells of a set of holding intervals (Inflow / Outflow, docs/definitions.md): per key (a store customer)
-- the maximal stretches in which at least one of its intervals [start, end) holds; end null: still holding. Set-based:
-- +1 at every start and -1 at every end, a running sum per key in time order (a start before an end of the same
-- instant, so an interval that begins where another ends continues the spell), a spell from the sum's 0 to 1 until its
-- 1 to 0. An interval without a key or a start, and one that ends at or before its start, is left out
create or replace function cma.active_spells_from(p_key text[], p_start timestamptz[], p_end timestamptz[])
returns table (key text, spell_start timestamptz, spell_end timestamptz)
language sql immutable
rows 10000   -- about one spell per customer with a subscription (CLAUDE.md, Performance: a set-returning function says its rows)
as $$
  with iv as (
    select u.k, u.s, u.e from unnest(p_key, p_start, p_end) u(k, s, e)
    where u.k is not null and u.s is not null and (u.e is null or u.e > u.s)
  ), ev as (
    select iv.k, iv.s as at, 1 as d from iv
    union all
    select iv.k, iv.e, -1 from iv where iv.e is not null
  ), run as (
    select ev.k, ev.at, ev.d,
           sum(ev.d) over (partition by ev.k order by ev.at, ev.d desc rows between unbounded preceding and current row) as n
    from ev
  ), bound as (
    select run.k, run.at, run.d, lead(run.at) over (partition by run.k order by run.at, run.d desc) as next_at
    from run
    where (run.d = 1 and run.n = 1) or (run.d = -1 and run.n = 0)
  )
  select bound.k, bound.at, bound.next_at from bound where bound.d = 1
$$;

-- The month ends of a set of intervals [start, end) with three dimensions and a weight each (1 to count them, an amount
-- to add it up): per calendar month in the zone, from the month of the first start to the month of p_now, and per
-- combination of the dimensions, the weight that started in the month (inflow), that ended in it (outflow) and that
-- holds at its end (at_end: everything started up to the month's end less everything ended up to it; the running month's
-- is as of p_now). Set-based: the starts and the ends added up per month, then a running sum over the months, never a
-- join of the months with the intervals. An interval that starts after p_now is left out; an end after p_now is no end yet
create or replace function cma.active_month_cube_from(p_d1 text[], p_d2 text[], p_d3 text[], p_weight numeric[], p_start timestamptz[],
                                                      p_end timestamptz[], p_zone text, p_now timestamptz)
returns table (month date, d1 text, d2 text, d3 text, inflow numeric, outflow numeric, at_end numeric)
language sql immutable
rows 5000    -- the months of the history times the combinations of the dimensions
as $$
  with iv as (
    select coalesce(u.a, '') as a, coalesce(u.b, '') as b, coalesce(u.c, '') as c, coalesce(u.w, 0) as w,
           date_trunc('month', u.s at time zone p_zone)::date as ms,
           case when u.e is not null and u.e <= p_now then date_trunc('month', u.e at time zone p_zone)::date end as me
    from unnest(p_d1, p_d2, p_d3, p_weight, p_start, p_end) u(a, b, c, w, s, e)
    where u.s is not null and u.s <= p_now and (u.e is null or u.e > u.s)
  ), ev as (
    select iv.a, iv.b, iv.c, iv.ms as m, sum(iv.w) as i, 0::numeric as o from iv group by 1, 2, 3, 4
    union all
    select iv.a, iv.b, iv.c, iv.me, 0, sum(iv.w) from iv where iv.me is not null group by 1, 2, 3, 4
  ), g as (
    select ev.a, ev.b, ev.c, ev.m, sum(ev.i) as i, sum(ev.o) as o from ev group by 1, 2, 3, 4
  ), cell as (
    select distinct g.a, g.b, g.c from g
  ), grid as (
    select x::date as m
    from generate_series((select min(g.m) from g)::timestamp, date_trunc('month', p_now at time zone p_zone)::timestamp, interval '1 month') x
  )
  select grid.m, cell.a, cell.b, cell.c, coalesce(g.i, 0), coalesce(g.o, 0),
         sum(coalesce(g.i, 0) - coalesce(g.o, 0)) over (partition by cell.a, cell.b, cell.c order by grid.m)
  from grid
  cross join cell
  left join g on g.m = grid.m and g.a = cell.a and g.b = cell.b and g.c = cell.c
$$;

-- The customer cohorts of a set of spells (Customer cohort, docs/definitions.md): per period of the Customer start (a
-- calendar month or quarter in the zone), per combination of three dimensions and per age in months, the customers
-- started in it, those still in a spell at their own Customer start plus the age, and whether the row is Mature at the
-- age (every customer in it is that old as of p_now; until then still_active counts those who are). One input row per
-- spell: a customer of several spells repeats its key, its dimensions and its Customer start. A customer's spells never
-- overlap, so at most one of them holds at an instant: the spells that hold at their customer's age are the customers
-- still active, counted in one pass over the spells times the ages (never a search of the spells per customer and age)
create or replace function cma.active_cohort_cube_from(p_customer text[], p_d1 text[], p_d2 text[], p_d3 text[], p_customer_start timestamptz[],
                                                       p_start timestamptz[], p_end timestamptz[], p_ages integer[], p_grouping text,
                                                       p_zone text, p_now timestamptz)
returns table (cohort date, d1 text, d2 text, d3 text, age_months integer, started bigint, still_active bigint, mature boolean)
language sql immutable
rows 5000    -- the cohorts times the ages times the combinations of the dimensions
as $$
  with sp as (
    select coalesce(u.a, '') as a, coalesce(u.b, '') as b, coalesce(u.c, '') as c, u.cs, u.s, u.e,
           date_trunc(case when p_grouping = 'quarter' then 'quarter' else 'month' end, u.cs at time zone p_zone)::date as cohort,
           -- a customer counts once: on its first spell
           row_number() over (partition by u.k order by u.s) = 1 as first
    from unnest(p_customer, p_d1, p_d2, p_d3, p_customer_start, p_start, p_end) u(k, a, b, c, cs, s, e)
    where u.k is not null and u.cs is not null and u.s is not null
  )
  select sp.cohort, sp.a, sp.b, sp.c, g.age,
         count(*) filter (where sp.first),
         count(*) filter (where x.at <= p_now and sp.s <= x.at and (sp.e is null or sp.e > x.at)),
         coalesce(bool_and(x.at <= p_now) filter (where sp.first), true)
  from sp
  cross join unnest(p_ages) g(age)
  cross join lateral (select ((sp.cs at time zone p_zone) + make_interval(months => g.age)) at time zone p_zone as at) x
  group by 1, 2, 3, 4, 5
$$;

-- Kaplan–Meier over a set of spells in whole months (Customer lifetime, docs/definitions.md): p_length a spell's length
-- (an ended spell's) or its age today (an active one's), p_ended whether it ended (an event at its length) or is still
-- active (censored at its age). Per age from 0 to the longest length: at_risk the spells of at least that length, events
-- the ended ones of exactly that length, survival the product over the ages up to and including it of
-- (1 - events / at_risk), which is Retention (customer) at that age. The median is the first age whose survival is at
-- most 0.5, so a curve crosses 50 % exactly at its median
create or replace function cma.active_km_from(p_length integer[], p_ended boolean[])
returns table (age_months integer, at_risk integer, events integer, survival numeric)
language plpgsql immutable
rows 60
as $$
declare
  r record;
  v_s numeric := 1;
begin
  for r in
    with sp as (
      select u.l, coalesce(u.e, false) as e from unnest(p_length, p_ended) u(l, e) where u.l is not null and u.l >= 0
    ), h as (
      select sp.l, count(*) as n, count(*) filter (where sp.e) as d from sp group by sp.l
    )
    select a.age, coalesce(sum(h.n) filter (where h.l >= a.age), 0)::integer as n_at,
           coalesce(sum(h.d) filter (where h.l = a.age), 0)::integer as d_at
    from generate_series(0, (select max(sp.l) from sp)) a(age)
    left join h on h.l >= a.age
    group by a.age
    order by a.age
  loop
    age_months := r.age;
    at_risk := r.n_at;
    events := r.d_at;
    if r.n_at > 0 then
      v_s := v_s * (1 - r.d_at::numeric / r.n_at);
    end if;
    survival := round(v_s, 6);
    return next;
  end loop;
end
$$;

-- A Kaplan–Meier curve's summary as JSON: the spells, the longest observed age, the median (null: not reached within
-- it), and the curve's points
create or replace function cma.active_km_json(p_length integer[], p_ended boolean[])
returns jsonb
language sql immutable
as $$
  select jsonb_build_object('spells', coalesce(cardinality(p_length), 0),
                            'ended', (select count(*) from unnest(p_ended) e where e),
                            'longest', max(k.age_months),
                            'median', min(k.age_months) filter (where k.survival <= 0.5),
                            'curve', coalesce(jsonb_agg(jsonb_build_object('age', k.age_months, 'at_risk', k.at_risk, 'events', k.events,
                                                                           'survival', k.survival)
                                                        order by k.age_months), '[]'::jsonb))
  from cma.active_km_from(p_length, p_ended) k
$$;
-- ---------------------------------------------------------------------------------------------
-- 3. The base: the subscriptions with their holding interval, their store customer and its acquisition channel
-- ---------------------------------------------------------------------------------------------
-- One row per subscription the latest full read still returns (merged and never-subscribed left out unless the tenant
-- counts them as device-holding), read once per request; the page, the list, the spells, the channel, the survival and
-- the readers' views all start here.
--   the subscription   its store and market (its connection's store: cma.flash_subscription_stores_of, unknown without
--                      one), status, whether the status holds devices (flash.device_holding_statuses: Flash's Total
--                      subscriptions) and whether it pays (flash.active_subscription_statuses), its payment state
--                      (cma.subscription_payment_state_of; null when p_with_payment is false), currency, its amount per
--                      month (amount_per_cycle times cma.active_month_factor_of; null without an amount, an interval or
--                      a currency), billing interval (cma.active_billing_of), its devices in the field (as
--                      cma.flash_subscriptions_of counts them: the register's devices of its market whose subscription
--                      reference is its id, in a status flagged is_in_field)
--   the holding interval [started_at, ended_at): started_at its creation in the subscription app; ended_at null while its
--                      status holds devices, else for a paused one paused_at (else its latest paused event), for one in a
--                      status of flash.ended_subscription_statuses its Ended time (canceled_at, else the latest event
--                      into one of those statuses, as cma.flash_churn_of reads them: canceled, or status_changed to
--                      one), for any other status its latest status_changed event into that status. in_history: it has
--                      a start and, unless it holds, an end; left_out says why not (no_created_time, no_ended_time).
--                      Past pauses are not read: a subscription paused and resumed counts as holding throughout
--   the store customer the customer of its store with its id (not missing from the store), with Flash's own figures of it
--                      (cma.flash_customer_figures_of, read for these customers alone: segment, CRM contact, holding
--                      subscriptions, devices, the store's amount spent and its currency) and its Customer start (the
--                      earliest of its creation in the store and the creation of any of its subscriptions here); null
--                      for a subscription whose customer the store does not hold (segment and channel unknown)
--   the channel        when p_with_channel: indirect or direct from the attribution cma.first_orders_of gives the
--                      customer's first order (call_center indirect, self_service direct; the customer of the first
--                      order's linked store order; the earliest by the deal's creation when it has several), read once
--                      from the attribution's history start (p_attribution_start: cma.first_orders_history_start_of's,
--                      which the caller reads once; a date in the tenant's zone; null: no order deal yet) to
--                      p_now; else unknown with the reason: no_contact (the customer has no CRM contact), before_history
--                      (its Customer start lies before the history start), no_first_order (an order deal is linked to one
--                      of its orders, none a first order), order_not_matched (a first order of its contact without a
--                      linked store order) or no_order_deal. Without p_with_channel every channel is unknown, no reason
create or replace function cma.active_base_of(p_tenant_id uuid, p_now timestamptz, p_with_channel boolean, p_attribution_start date,
                                              p_with_payment boolean)
returns table (subscription_id uuid, connection_id uuid, source_id text, store text, market text, status text, is_holding boolean,
               is_paying boolean, payment_state text, currency text, monthly_amount numeric, billing text, devices_in_field integer,
               started_at timestamptz, ended_at timestamptz, in_history boolean, left_out text,
               customer_id uuid, customer_connection_id uuid, customer_source_id text, segment text, crm_connection_id uuid,
               contact_source_id text, customer_start timestamptz, customer_holding integer, customer_devices integer, clv numeric,
               clv_currency text, channel text, level text, unknown_reason text, first_order_at timestamptz)
language sql stable
rows 10000   -- a tenant's subscriptions (CLAUDE.md, Performance: a set-returning function says its rows)
as $$
  with s as materialized (
    select cma.flash_holding_statuses_of(p_tenant_id) as holding, cma.flash_active_statuses_of(p_tenant_id) as paying,
           cma.flash_ended_statuses_of(p_tenant_id) as ended,
           (select t.timezone from cma.tenant t where t.id = p_tenant_id) as zone,
           case when p_with_channel then p_attribution_start end as attribution_start
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  ), ps as materialized (
    select p.subscription_id, p.payment_state from cma.subscription_payment_state_of(p_tenant_id) p where p_with_payment
  ), dev as (
    select d.subscription_ref, d.market, count(*) filter (where coalesce(ds.is_in_field, false))::integer as n_field
    from cma.device d
    left join cma.device_status ds on ds.tenant_id = d.tenant_id and ds.key = d.device_status_key
    where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.subscription_ref is not null
    group by 1, 2
  ), s0 as materialized (
    select x.id, x.connection_id, x.source_id, x.customer_source_id, x.status, x.currency, x.amount_per_cycle, x.billing_interval,
           x.billing_interval_count, x.source_created_at, x.paused_at, x.canceled_at,
           x.status = any ((select s.holding from s)::text[]) as is_holding, x.status = any ((select s.paying from s)::text[]) as is_paying,
           x.status = any ((select s.ended from s)::text[]) as is_ended
    from cma.subscription x
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null
      and (x.status not in ('merged', 'never-subscribed') or x.status = any ((select s.holding from s)::text[]))
  ), ev as (
    -- the event that ended the holding, read only for the subscriptions whose own times do not say it (through
    -- subscription_event_subscription_idx, one range per subscription)
    select n.id, e.at
    from s0 n
    cross join lateral (
      select max(e.occurred_at) as at
      from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = n.connection_id and e.subscription_source_id = n.source_id
        and case when n.status = 'paused' then e.event_type = 'paused' or (e.event_type = 'status_changed' and e.status_to = 'paused')
                 when n.is_ended
                 then (e.event_type = 'canceled' and 'canceled' = any ((select s.ended from s)::text[]))
                   or (e.event_type = 'status_changed' and e.status_to = any ((select s.ended from s)::text[]))
                 else e.event_type = 'status_changed' and e.status_to = n.status end
    ) e
    where not n.is_holding
      and not (n.status = 'paused' and n.paused_at is not null)
      and not (n.status <> 'paused' and n.is_ended and n.canceled_at is not null)
  ), sb as materialized (
    select x.id, x.connection_id, x.source_id, sm.store_connection_id, coalesce(sm.handle, 'unknown') as store,
           coalesce(sm.market, 'unknown') as market, x.customer_source_id, x.status, x.is_holding, x.is_paying,
           x.currency, x.amount_per_cycle * cma.active_month_factor_of(x.billing_interval, x.billing_interval_count) as monthly_amount,
           cma.active_billing_of(x.billing_interval, x.billing_interval_count) as billing, x.source_created_at as started_at,
           case when x.is_holding then null
                when x.status = 'paused' then coalesce(x.paused_at, ev.at)
                when x.is_ended then coalesce(x.canceled_at, ev.at)
                else ev.at end as ended_at,
           coalesce(dev.n_field, 0) as devices_in_field
    from s0 x
    left join sm on sm.connection_id = x.connection_id
    left join ev on ev.id = x.id
    left join dev on dev.subscription_ref = x.source_id and dev.market = coalesce(sm.market, 'unknown')
  ), cu as materialized (
    -- the store customers of these subscriptions, with the earliest creation of their subscriptions here
    select c.id, c.connection_id, c.source_id, least(c.source_created_at, k.first_started) as customer_start
    from (select sb.store_connection_id, sb.customer_source_id, min(sb.started_at) as first_started
          from sb where sb.store_connection_id is not null and sb.customer_source_id is not null group by 1, 2) k
    join cma.commerce_customer c
      on c.tenant_id = p_tenant_id and c.connection_id = k.store_connection_id and c.source_id = k.customer_source_id
     and c.source_deleted_at is null
  ), fig as materialized (
    -- Flash's own figures of these customers (D2): the function read through the customers' primary key
    select f.customer_id, f.segment, f.crm_connection_id, f.contact_source_id, f.holding_subscriptions, f.devices, f.total_spent, f.currency
    from cma.flash_customer_figures_of(p_tenant_id) f
    where f.customer_id = any (array(select cu.id from cu))
  ), fo as materialized (
    -- First orders' rows over the attribution's history, read once (never a second rule)
    select o.connection_id, o.contact_source_id, o.created_at, o.kind, o.order_id, o.level, o.attribution
    from s
    cross join lateral cma.first_orders_of(p_tenant_id, (s.attribution_start::timestamp at time zone s.zone), p_now) o
    where p_with_channel and s.attribution_start is not null
  ), oc as materialized (
    -- the store customer of each order deal's linked store order
    select cu.id as customer_id, o.kind, o.created_at, o.order_id, o.level, o.attribution
    from fo o
    join cma.commerce_order co on co.tenant_id = p_tenant_id and co.id = o.order_id
    join cu on cu.connection_id = co.connection_id and cu.source_id = co.customer_source_id
    where o.order_id is not null
  ), att as materialized (
    select distinct on (oc.customer_id) oc.customer_id, oc.attribution, oc.level, oc.created_at
    from oc where oc.kind = 'first'
    order by oc.customer_id, oc.created_at, oc.order_id
  ), oth as materialized (
    select distinct oc.customer_id from oc
  ), unm as materialized (
    select distinct o.connection_id, o.contact_source_id from fo o
    where o.kind = 'first' and o.order_id is null and o.contact_source_id is not null
  )
  select sb.id, sb.connection_id, sb.source_id, sb.store, sb.market, sb.status, sb.is_holding, sb.is_paying,
         ps.payment_state, sb.currency, sb.monthly_amount, sb.billing, sb.devices_in_field,
         sb.started_at, sb.ended_at,
         sb.started_at is not null and (sb.is_holding or sb.ended_at is not null),
         case when sb.started_at is null then 'no_created_time' when not sb.is_holding and sb.ended_at is null then 'no_ended_time' end,
         cu.id, cu.connection_id, cu.source_id, coalesce(f.segment, 'unknown'), f.crm_connection_id, f.contact_source_id, cu.customer_start,
         f.holding_subscriptions, f.devices, f.total_spent, f.currency,
         case a.attribution when 'call_center' then 'indirect' when 'self_service' then 'direct' else 'unknown' end,
         a.level,
         case when cu.id is null or a.customer_id is not null or not p_with_channel then null
              when f.contact_source_id is null then 'no_contact'
              when (select s.attribution_start from s) is not null
                   and (cu.customer_start at time zone (select s.zone from s))::date < (select s.attribution_start from s) then 'before_history'
              when oth.customer_id is not null then 'no_first_order'
              when unm.contact_source_id is not null then 'order_not_matched'
              else 'no_order_deal' end,
         a.created_at
  from sb
  left join ps on ps.subscription_id = sb.id
  left join cu on cu.connection_id = sb.store_connection_id and cu.source_id = sb.customer_source_id
  left join fig f on f.customer_id = cu.id
  left join att a on a.customer_id = cu.id
  left join oth on oth.customer_id = cu.id
  left join unm on unm.connection_id = f.crm_connection_id and unm.contact_source_id = f.contact_source_id
$$;
-- JIT off (as cma.courtesy_orders_of, 150): the joins are small, and a session's first compiled call costs more than the
-- read. The setting also keeps the function out of its callers' plans: it is read once and materialized there
alter function cma.active_base_of(uuid, timestamptz, boolean, date, boolean) set jit = off;

-- The store customers of the base, one row each: the customer with its store, market, segment, Customer start and age in
-- whole months today, Flash's figures of it, and its acquisition channel
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
         b.customer_holding > 0, b.customer_holding, b.customer_devices, b.channel, b.level, b.unknown_reason, b.first_order_at
  from cma.active_base_of(p_tenant_id, p_now, p_with_channel,
                          case when p_with_channel then (select h.history_start from cma.first_orders_history_start_of(p_tenant_id) h) end, false) b
  where b.customer_id is not null
  order by b.customer_id
$$;

-- Per store customer of the base its active spells (start, end or null while it lasts): cma.active_spells_from over its
-- subscriptions' holding intervals. A subscription left out of the history (no creation time, or no Ended time) and one
-- whose customer the store does not hold have no part in it
create or replace function cma.active_spells_of(p_tenant_id uuid)
returns table (customer_id uuid, connection_id uuid, source_id text, spell_start timestamptz, spell_end timestamptz)
language sql stable
rows 10000
as $$
  with b as materialized (
    select x.customer_id, x.customer_connection_id, x.customer_source_id, x.started_at, x.ended_at
    from cma.active_base_of(p_tenant_id, now(), false, null, false) x
    where x.customer_id is not null and x.in_history
  ), c as (
    select distinct b.customer_id, b.customer_connection_id, b.customer_source_id from b
  )
  select c.customer_id, c.customer_connection_id, c.customer_source_id, sp.spell_start, sp.spell_end
  from (select array_agg(b.customer_id::text) as k, array_agg(b.started_at) as s, array_agg(b.ended_at) as e from b) a
  cross join lateral cma.active_spells_from(a.k, a.s, a.e) sp
  join c on c.customer_id = sp.key::uuid
$$;

-- Per store customer of the base its acquisition channel (indirect, direct or unknown), First orders' level of its first
-- order and, when unknown, the reason (cma.active_base_of)
create or replace function cma.active_channel_of(p_tenant_id uuid)
returns table (customer_id uuid, connection_id uuid, source_id text, channel text, level text, unknown_reason text, first_order_at timestamptz)
language sql stable
rows 10000
as $$
  select c.customer_id, c.connection_id, c.source_id, c.channel, c.level, c.unknown_reason, c.first_order_at
  from cma.active_customers_of(p_tenant_id, now(), true) c
$$;

-- The spells of the base with their customer's dimensions and their length in whole months as PostgreSQL's age() counts
-- them (cma.flash_age_months_of): from the spell's start to its end, or to today while it lasts
create or replace function cma.active_spell_lengths_of(p_tenant_id uuid, p_now timestamptz, p_with_channel boolean)
returns table (customer_id uuid, market text, segment text, channel text, customer_start timestamptz, spell_start timestamptz,
               spell_end timestamptz, length_months integer, ended boolean)
language sql stable
rows 10000
as $$
  with z as materialized (
    select t.timezone as zone, (p_now at time zone t.timezone)::date as today from cma.tenant t where t.id = p_tenant_id
  ), b as materialized (
    select x.customer_id, x.market, x.segment, x.channel, x.customer_start, x.started_at, x.ended_at, x.in_history
    from cma.active_base_of(p_tenant_id, p_now, p_with_channel,
                          case when p_with_channel then (select h.history_start from cma.first_orders_history_start_of(p_tenant_id) h) end, false) x
    where x.customer_id is not null
  ), c as (
    select distinct on (b.customer_id) b.customer_id, b.market, b.segment, b.channel, b.customer_start from b order by b.customer_id
  )
  select c.customer_id, c.market, c.segment, c.channel, c.customer_start, sp.spell_start, sp.spell_end,
         greatest(0, cma.flash_age_months_of(sp.spell_start, (select z.zone from z),
                                             coalesce((sp.spell_end at time zone (select z.zone from z))::date, (select z.today from z)))),
         sp.spell_end is not null
  from (select array_agg(b.customer_id::text) as k, array_agg(b.started_at) as s, array_agg(b.ended_at) as e from b where b.in_history) a
  cross join lateral cma.active_spells_from(a.k, a.s, a.e) sp
  join c on c.customer_id = sp.key::uuid
$$;

-- Kaplan–Meier per value of a split (segment, channel, or none: one curve under the value all) over every spell of the
-- tenant: per age the spells at risk, the events and the survival (cma.active_km_from), with the curve's median (null:
-- not reached) and its longest observed age on every row. p_now is the moment an active spell's age is taken at (now when
-- left out; a verify script pins it)
create or replace function cma.active_survival_of(p_tenant_id uuid, p_split text, p_now timestamptz default now())
returns table (split_value text, age_months integer, at_risk integer, events integer, survival numeric, median_months integer,
               longest_months integer)
language sql stable
rows 500
as $$
  select g.v, k.age_months, k.at_risk, k.events, k.survival,
         min(k.age_months) filter (where k.survival <= 0.5) over (partition by g.v), max(k.age_months) over (partition by g.v)
  from (select case p_split when 'segment' then l.segment when 'channel' then l.channel else 'all' end as v,
               array_agg(l.length_months) as len, array_agg(l.ended) as ended
        from cma.active_spell_lengths_of(p_tenant_id, p_now, p_split = 'channel') l
        group by 1) g
  cross join lateral cma.active_km_from(g.len, g.ended) k
$$;

-- The page's and the list's filters: a market's code or unknown, a segment's code or unknown, a channel (indirect,
-- direct or unknown); anything else CMA04
create or replace function cma.assert_active_filter(p_market text, p_segment text, p_channel text)
returns void
language plpgsql immutable
as $$
begin
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'a market filter is a two-letter code or unknown' using errcode = 'CMA04';
  end if;
  if p_segment is not null and p_segment !~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$' then
    raise exception 'a segment filter is a segment''s code or unknown' using errcode = 'CMA04';
  end if;
  if p_channel is not null and p_channel not in ('indirect', 'direct', 'unknown') then
    raise exception 'a channel filter is indirect, direct or unknown' using errcode = 'CMA04';
  end if;
end
$$;
-- ---------------------------------------------------------------------------------------------
-- 4. Customers → Active in one read
-- ---------------------------------------------------------------------------------------------
-- The page as one JSON document, in one statement over the base read once (cma.active_base_of with the channel and the
-- payment state), narrowed by market, segment and acquisition channel. Keys:
--   set_up            commerce and subscriptions (cma.flash_source_set_up_of); while either is false nothing else is
--                     computed (figures null: "Not set up", never zeros)
--   tiles             active_customers (Flash's Active customers: the store customers with a subscription in a
--                     device-holding status, cma.flash_customer_figures_of) with its split by segment and by channel;
--                     total_subscriptions (Flash's Total subscriptions) with its split by status; amounts per currency
--                     (the Monthly recurring amount, the customers with a holding subscription in the currency, their
--                     average), the indicative euros (eur: only when reports.fx_eur_rates holds a rate for every currency
--                     shown); customer_age (median, and the customers of at least each of the first three ages of
--                     customers.age_months); lifetime (Kaplan–Meier over the spells; no change line: the curve as of a past
--                     month end is not computed); clv per currency (the store's amount spent is today's: no change line).
--                     The others with prev_month and prev_year: the value at the previous month's end and at the month end
--                     twelve months before that, null where the history does not reach
--   unit_economics    the placeholders' keys with status pending and no figure, and churned_30d (Flash's Churn
--                     (subscription) over the last 30 business dates, cma.flash_churn_of)
--   months            per month end from from_month: customers (with by_segment), subscriptions, inflow (with
--                     inflow_by_channel), outflow, amounts per currency and eur; the running month's row is "now" and
--                     carries the present (tiles), its inflow and outflow the month to date
--   markets, markets_total   per market and over all: the present figures, churned and net change over 30 days, the
--                     indirect share, and the customers at the last twelve month ends and now (spark)
--   comparison        the first two segments of crm.customer_segments side by side with unknown: one row per measure
--                     (and currency) with a, b, unknown, difference (a - b) and ratio (a / b, only when both are above 0)
--   survival          the Kaplan–Meier curves per segment, per channel and over all
--   age_bands, cohorts, cohort_splits, mix, notes, filters, settings
-- Amounts are per currency and never added across currencies; the euros are indicative and absent without every rate
create or replace function cma.active_page_of(p_tenant_id uuid, p_from_month date, p_market text, p_segment text, p_channel text,
                                              p_grouping text, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone         text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_today        date;
  v_month        date;
  v_prev         date;
  v_year         date;
  v_ages         integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'customers.cohort_ages_months'));
  v_bands        integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'customers.age_months'));
  v_hist         integer := cma.setting_of(p_tenant_id, 'customers.history_months')::integer;
  v_fx           jsonb := cma.active_fx_of(p_tenant_id);
  v_segments     text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments'));
  v_device_bands integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.device_bands'));
  v_from         date;
  v_head         jsonb;
  v_doc          jsonb;
  v_commerce     boolean := coalesce(cma.flash_source_set_up_of(p_tenant_id, 'commerce'), false);
  v_subs         boolean := coalesce(cma.flash_source_set_up_of(p_tenant_id, 'subscriptions'), false);
  -- the attribution's history start, read once: the header names it and the base reads First orders from it
  v_attr         date := (select h.history_start from cma.first_orders_history_start_of(p_tenant_id) h);
begin
  v_today := (p_now at time zone v_zone)::date;
  v_month := date_trunc('month', v_today)::date;
  v_prev := (v_month - interval '1 month')::date;
  v_year := (v_month - interval '13 months')::date;
  -- the history's first month: the one asked for, never before customers.history_months back, never after this month
  v_from := least(v_month, greatest(coalesce(p_from_month, date '0001-01-01'), (v_month - make_interval(months => v_hist))::date));
  v_head := jsonb_build_object(
    'set_up', jsonb_build_object('commerce', v_commerce, 'subscriptions', v_subs),
    'computed_at', p_now, 'time_zone', v_zone, 'today', v_today, 'month', v_month, 'from_month', v_from, 'grouping', p_grouping,
    'filter', jsonb_build_object('market', p_market, 'segment', p_segment, 'channel', p_channel),
    'settings', jsonb_build_object('cohort_ages_months', to_jsonb(v_ages), 'age_months', to_jsonb(v_bands), 'history_months', v_hist,
                                   'fx', case when v_fx = '{}'::jsonb then null else v_fx end, 'segments', to_jsonb(v_segments),
                                   'statuses', cma.flash_status_settings_of(p_tenant_id),
                                   'attribution', jsonb_build_object(
                                     'assisted_levels', to_jsonb(coalesce(string_to_array(nullif(cma.setting_of(p_tenant_id, 'attribution.assisted_levels'), ''), ','), '{}'::text[])),
                                     'history_start', v_attr)));
  if not (v_commerce and v_subs) then
    return v_head || jsonb_build_object('figures', false);
  end if;

  with b0 as materialized (
    select * from cma.active_base_of(p_tenant_id, p_now, true, v_attr, true)
  ), b as materialized (
    select * from b0 x
    where (p_market is null or x.market = p_market) and (p_segment is null or x.segment = p_segment)
      and (p_channel is null or x.channel = p_channel)
  ), c as materialized (
    -- the store customers, one row each (a customer's subscriptions share its store, segment and channel)
    select distinct on (b.customer_id) b.customer_id, b.market, b.segment, b.channel, b.unknown_reason, b.customer_start,
           coalesce(b.customer_holding, 0) > 0 as is_active, coalesce(b.customer_holding, 0) as holding,
           coalesce(b.customer_devices, 0) as devices, b.clv, b.clv_currency,
           cma.flash_age_months_of(b.customer_start, v_zone, v_today) as age
    from b where b.customer_id is not null
    order by b.customer_id
  ), sp as materialized (
    -- their active spells, with the length in whole months (to the end, or to today while the spell lasts)
    select c.customer_id, c.market, c.segment, c.channel, c.customer_start, x.spell_start, x.spell_end,
           greatest(0, cma.flash_age_months_of(x.spell_start, v_zone, coalesce((x.spell_end at time zone v_zone)::date, v_today))) as len,
           x.spell_end is not null as ended
    from (select array_agg(b.customer_id::text) as k, array_agg(b.started_at) as s, array_agg(b.ended_at) as e
          from b where b.customer_id is not null and b.in_history) a
    cross join lateral cma.active_spells_from(a.k, a.s, a.e) x
    join c on c.customer_id = x.key::uuid
  ), mc as materialized (
    -- the customers per month end, by market, segment and channel
    select x.month, x.d1 as market, x.d2 as segment, x.d3 as channel, x.inflow, x.outflow, x.at_end
    from (select array_agg(sp.market) as a, array_agg(sp.segment) as b, array_agg(sp.channel) as c, array_agg(1::numeric) as w,
                 array_agg(sp.spell_start) as s, array_agg(sp.spell_end) as e from sp) a
    cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, v_zone, p_now) x
  ), ms as materialized (
    -- the subscriptions holding at each month end, by the reconstruction
    select x.month, x.at_end
    from (select array_agg(''::text) as n, array_agg(1::numeric) as w, array_agg(b.started_at) as s, array_agg(b.ended_at) as e
          from b where b.in_history) a
    cross join lateral cma.active_month_cube_from(a.n, a.n, a.n, a.w, a.s, a.e, v_zone, p_now) x
  ), ma as materialized (
    -- the Monthly recurring amount per month end and currency: the subscriptions holding then at their amount today; one
    -- that holds today without paying (a status outside flash.active_subscription_statuses) is left out throughout
    select x.month, x.d1 as currency, x.at_end
    from (select array_agg(b.currency) as a, array_agg(''::text) as n, array_agg(b.monthly_amount) as w, array_agg(b.started_at) as s,
                 array_agg(b.ended_at) as e
          from b where b.in_history and b.currency is not null and b.monthly_amount is not null and (not b.is_holding or b.is_paying)) a
    cross join lateral cma.active_month_cube_from(a.a, a.n, a.n, a.w, a.s, a.e, v_zone, p_now) x
  ), mk as materialized (
    -- the customers with a subscription in a currency at the two month ends a change line compares with (the previous
    -- month's end and the one twelve months before it): those whose subscription in it held then
    select x.m as month, b.currency, count(distinct b.customer_id) as at_end
    from b
    cross join (values (v_prev, v_month::timestamp at time zone v_zone),
                       (v_year, (v_year + interval '1 month')::timestamp at time zone v_zone)) x(m, at)
    where b.customer_id is not null and b.in_history and b.currency is not null
      and b.started_at < x.at and (b.ended_at is null or b.ended_at >= x.at)
    group by 1, 2
  ), mt as materialized (
    select mc.month, sum(mc.at_end) as customers, sum(mc.inflow) as inflow, sum(mc.outflow) as outflow from mc group by 1
  ), mseg as (
    select q.month, jsonb_object_agg(q.segment, q.n) as j
    from (select mc.month, mc.segment, sum(mc.at_end) as n from mc group by 1, 2) q group by 1
  ), mchan as (
    select q.month, jsonb_object_agg(q.channel, q.n) as j
    from (select mc.month, mc.channel, sum(mc.inflow) as n from mc group by 1, 2) q group by 1
  ), mam as (
    select ma.month, jsonb_object_agg(ma.currency, round(ma.at_end, 2)) as j,
           bool_and(ma.currency = 'EUR' or coalesce(jsonb_typeof(v_fx -> ma.currency) = 'number', false)) as fx_ok,
           round(sum(cma.active_eur_of(ma.at_end, ma.currency, v_fx)), 2) as eur
    from ma group by 1
  ),
  -- ---- the present, per market, per segment and over all (dim market, segment, all; key '*' for all) --------------
  g_c as materialized (
    select case when grouping(c.market) = 0 then 'market' when grouping(c.segment) = 0 then 'segment' else 'all' end as dim,
           coalesce(c.market, c.segment, '*') as key,
           count(*) as customers, sum(c.devices) as devices, sum(c.holding) as holding,
           percentile_cont(0.5) within group (order by c.age) as median_age,
           count(*) filter (where c.channel = 'indirect') as indirect, count(*) filter (where c.channel = 'direct') as direct,
           count(*) filter (where c.channel = 'unknown') as unknown_channel,
           count(*) filter (where c.age >= v_bands[1]) as over1, count(*) filter (where c.age >= v_bands[2]) as over2,
           count(*) filter (where c.age >= v_bands[3]) as over3
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
    -- Flash's Churn (subscription) over the last 30 business dates, under the same filters
    select x.market
    from cma.flash_churn_of(p_tenant_id, v_today - 29, v_today) x
    left join b0 on b0.subscription_id = x.subscription_id
    where (p_market is null or x.market = p_market) and (p_segment is null or coalesce(b0.segment, 'unknown') = p_segment)
      and (p_channel is null or coalesce(b0.channel, 'unknown') = p_channel)
  ), g_ch as (
    select case when grouping(ch.market) = 0 then 'market' else 'all' end as dim, coalesce(ch.market, '*') as key, count(*) as churned
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
             'devices_per_customer', case when coalesce(gc.customers, 0) > 0 then round(gc.devices::numeric / gc.customers, 2) end) as j,
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
  ),
  -- ---- the comparison: the first two segments side by side, long then wide ------------------------------------------
  cmp_long as (
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
    cross join (values ('subscriptions_per_customer', 100), ('devices_per_customer', 110), ('indirect_share', 120)) x(measure, ord)
    where s.dim = 'segment'
  ), cmp as (
    select l.measure, l.months, l.currency, min(l.ord) as ord,
           max(l.v) filter (where l.key = v_segments[1]) as a, max(l.v) filter (where l.key = v_segments[2]) as b,
           max(l.v) filter (where l.key = 'unknown') as u,
           max(l.longest) filter (where l.key = v_segments[1]) as a_longest, max(l.longest) filter (where l.key = v_segments[2]) as b_longest,
           max(l.longest) filter (where l.key = 'unknown') as u_longest
    from cmp_long l
    group by 1, 2, 3
  ),
  -- ---- the cohorts ---------------------------------------------------------------------------------------------
  cc as materialized (
    select x.cohort, x.d2 as segment, x.d3 as channel, x.age_months, x.started, x.still_active, x.mature
    from (select array_agg(sp.customer_id::text) as k, array_agg(sp.market) as a, array_agg(sp.segment) as b, array_agg(sp.channel) as c,
                 array_agg(sp.customer_start) as cs, array_agg(sp.spell_start) as s, array_agg(sp.spell_end) as e from sp) a
    cross join lateral cma.active_cohort_cube_from(a.k, a.a, a.b, a.c, a.cs, a.s, a.e, v_ages, p_grouping, v_zone, p_now) x
    where x.cohort >= date_trunc(p_grouping, v_from::timestamp)::date
  ), co as materialized (
    select q.cohort, max(q.started) as started,
           jsonb_agg(jsonb_build_object('age', q.age_months, 'still_active', q.still_active, 'mature', q.mature) order by q.age_months) as ages
    from (select cc.cohort, cc.age_months, sum(cc.started) as started, sum(cc.still_active) as still_active, bool_and(cc.mature) as mature
          from cc group by 1, 2) q
    group by 1
  ), co_split as (
    -- per value of a split and age: the cohorts' rows Mature at the age, pooled
    select q.dim, q.key, sum(q.started) filter (where q.age_months = v_ages[1]) as started_all,
           jsonb_agg(jsonb_build_object('age', q.age_months, 'started', q.started_mature, 'still_active', q.still_mature) order by q.age_months) as ages
    from (select case when grouping(cc.segment) = 0 then 'segment' else 'channel' end as dim, coalesce(cc.segment, cc.channel) as key, cc.age_months,
                 sum(cc.started) as started, coalesce(sum(cc.started) filter (where cc.mature), 0) as started_mature,
                 coalesce(sum(cc.still_active) filter (where cc.mature), 0) as still_mature
          from cc group by grouping sets ((cc.segment, cc.age_months), (cc.channel, cc.age_months))) q
    group by 1, 2
  )
  select jsonb_build_object(
    'figures', true,
    'filters', jsonb_build_object(
      'markets', (select coalesce(jsonb_agg(q.market order by q.market = 'unknown', q.market), '[]'::jsonb)
                  from (select distinct b0.market from b0
                        union select st.market from cma.commerce_store st where st.tenant_id = p_tenant_id) q),
      'segments', to_jsonb(v_segments || array['unknown']),
      'channels', '["indirect", "direct", "unknown"]'::jsonb),
    'tiles', jsonb_build_object(
      'active_customers', jsonb_build_object(
        'value', (select s.customers from stat s where s.dim = 'all'),
        'by_segment', (select s.j -> 'by_segment' from stat s where s.dim = 'all'),
        'by_channel', (select jsonb_build_object('indirect', s.j -> 'indirect', 'direct', s.j -> 'direct', 'unknown', s.j -> 'unknown_channel')
                       from stat s where s.dim = 'all'),
        'prev_month', (select mt.customers from mt where mt.month = v_prev),
        'prev_year', (select mt.customers from mt where mt.month = v_year)),
      'total_subscriptions', jsonb_build_object(
        'value', (select (s.j ->> 'subscriptions')::bigint from stat s where s.dim = 'all'),
        'by_status', (select coalesce(jsonb_object_agg(q.status, q.n), '{}'::jsonb)
                      from (select b.status, count(*) as n from b where b.is_holding group by 1) q),
        'prev_month', (select ms.at_end from ms where ms.month = v_prev),
        'prev_year', (select ms.at_end from ms where ms.month = v_year)),
      'amounts', (select coalesce(jsonb_agg(jsonb_build_object(
                           'currency', e.key, 'amount', e.value -> 'amount', 'customers', e.value -> 'customers', 'average', e.value -> 'average',
                           'prev_month', (select round(ma.at_end, 2) from ma where ma.month = v_prev and ma.currency = e.key),
                           'prev_year', (select round(ma.at_end, 2) from ma where ma.month = v_year and ma.currency = e.key),
                           'average_prev_month', (select case when mk.at_end > 0 then round(ma.at_end / mk.at_end, 2) end
                                                  from ma join mk on mk.month = ma.month and mk.currency = ma.currency
                                                  where ma.month = v_prev and ma.currency = e.key),
                           'average_prev_year', (select case when mk.at_end > 0 then round(ma.at_end / mk.at_end, 2) end
                                                 from ma join mk on mk.month = ma.month and mk.currency = ma.currency
                                                 where ma.month = v_year and ma.currency = e.key)) order by e.key), '[]'::jsonb)
                  from stat s cross join jsonb_each(s.j -> 'amounts') e where s.dim = 'all'),
      'eur', (select case when v_fx <> '{}'::jsonb and count(*) > 0
                               and bool_and(q.currency = 'EUR' or coalesce(jsonb_typeof(v_fx -> q.currency) = 'number', false))
                          then jsonb_build_object(
                                 'amount', round(sum(cma.active_eur_of(q.amount, q.currency, v_fx)), 2), 'as_of', v_fx ->> 'as_of',
                                 'prev_month', (select case when m.fx_ok then m.eur end from mam m where m.month = v_prev),
                                 'prev_year', (select case when m.fx_ok then m.eur end from mam m where m.month = v_year)) end
              from g_amt0 q where q.dim = 'all'),
      'customer_age', (select jsonb_build_object(
                         'median', round(g.median_age::numeric, 1),
                         'over', (select coalesce(jsonb_agg(jsonb_build_object('months', x.m, 'customers', x.n,
                                                                             'share', case when g.customers > 0 then round(x.n::numeric / g.customers, 4) end)
                                                           order by x.m), '[]'::jsonb)
                                  from (values (v_bands[1], g.over1), (v_bands[2], g.over2), (v_bands[3], g.over3)) x(m, n) where x.m is not null),
                         'prev_month', (select round((percentile_cont(0.5) within group (
                                                        order by cma.flash_age_months_of(sp.customer_start, v_zone, v_month - 1)))::numeric, 1)
                                        from sp
                                        where sp.spell_start < (v_month::timestamp at time zone v_zone)
                                          and (sp.spell_end is null or sp.spell_end >= (v_month::timestamp at time zone v_zone))
                                          and exists (select 1 from mt where mt.month = v_prev)),
                         'prev_year', (select round((percentile_cont(0.5) within group (
                                                       order by cma.flash_age_months_of(sp.customer_start, v_zone, (v_year + interval '1 month')::date - 1)))::numeric, 1)
                                       from sp
                                       where sp.spell_start < ((v_year + interval '1 month')::timestamp at time zone v_zone)
                                         and (sp.spell_end is null or sp.spell_end >= ((v_year + interval '1 month')::timestamp at time zone v_zone))
                                         and exists (select 1 from mt where mt.month = v_year)))
                       from g_c g where g.dim = 'all'),
      'lifetime', (select g.j - 'curve' from g_km g where g.dim = 'all'),
      'clv', (select s.j -> 'clv' from stat s where s.dim = 'all')),
    'unit_economics', jsonb_build_object(
      'churned_30d', (select coalesce((s.j ->> 'churned_30d')::bigint, 0) from stat s where s.dim = 'all'),
      'slots', (select jsonb_agg(jsonb_build_object('key', x.key, 'status', 'pending') order by x.ord)
                from (values ('churn_rate', 1), ('cac', 2), ('cost_per_subscription', 3), ('clv_projected', 4), ('clv_to_cac', 5),
                             ('payback_months', 6)) x(key, ord))),
    'months', (select coalesce(jsonb_agg(jsonb_build_object(
                        'month', mt.month, 'is_now', mt.month = v_month,
                        'customers', case when mt.month = v_month then (select s.customers from stat s where s.dim = 'all') else mt.customers end,
                        'by_segment', case when mt.month = v_month then (select s.j -> 'by_segment' from stat s where s.dim = 'all')
                                           else coalesce(mseg.j, '{}'::jsonb) end,
                        'subscriptions', case when mt.month = v_month then (select (s.j ->> 'subscriptions')::numeric from stat s where s.dim = 'all')
                                              else coalesce(ms.at_end, 0) end,
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
               left join mseg on mseg.month = mt.month
               left join mchan on mchan.month = mt.month
               left join ms on ms.month = mt.month
               left join mam on mam.month = mt.month
               where mt.month >= v_from),
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
    'cohorts', (select coalesce(jsonb_agg(jsonb_build_object(
                         'cohort', co.cohort, 'started', co.started,
                         'share', case when (select sum(x.started) from co x) > 0 then round(co.started / (select sum(x.started) from co x), 4) end,
                         'ages', co.ages) order by co.cohort desc), '[]'::jsonb)
                from co),
    'cohort_splits', jsonb_build_object(
      'segment', (select coalesce(jsonb_agg(jsonb_build_object('value', x.key, 'started', x.started_all, 'ages', x.ages)
                                            order by coalesce(array_position(v_segments, x.key), 1000), x.key), '[]'::jsonb)
                  from co_split x where x.dim = 'segment'),
      'channel', (select coalesce(jsonb_agg(jsonb_build_object('value', x.key, 'started', x.started_all, 'ages', x.ages)
                                            order by array_position(array['indirect', 'direct', 'unknown'], x.key)), '[]'::jsonb)
                  from co_split x where x.dim = 'channel')),
    'mix', jsonb_build_object(
      'billing', (select coalesce(jsonb_agg(jsonb_build_object('key', q.billing, 'subscriptions', q.n)
                                            order by array_position(array['monthly', 'yearly', 'other', 'unknown'], q.billing)), '[]'::jsonb)
                  from (select b.billing, count(*) as n from b where b.is_holding group by 1) q),
      'device_band', (select coalesce(jsonb_agg(jsonb_build_object('key', w.band, 'subscriptions', coalesce(q.n, 0)) order by w.ord), '[]'::jsonb)
                      from unnest(cma.flash_count_bands_of(v_device_bands)) with ordinality w(band, ord)
                      left join (select cma.flash_count_band_of(b.devices_in_field, v_device_bands) as band, count(*) as n
                                 from b where b.is_holding group by 1) q on q.band = w.band),
      'model', (select coalesce(jsonb_agg(jsonb_build_object('key', q.model_key, 'name', q.name, 'devices', q.n) order by q.n desc, q.model_key), '[]'::jsonb)
                from (select coalesce(d.model_key, 'unknown') as model_key, max(m.name) as name, count(*) as n
                      from cma.device d
                      join b on b.source_id = d.subscription_ref and b.market = d.market and b.is_holding
                      join cma.device_status ds on ds.tenant_id = d.tenant_id and ds.key = d.device_status_key and ds.is_in_field
                      left join cma.device_model m on m.tenant_id = d.tenant_id and m.key = d.model_key
                      where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.subscription_ref is not null
                      group by 1) q),
      'payment_state', (select coalesce(jsonb_agg(jsonb_build_object('key', x.state, 'subscriptions', coalesce(q.n, 0)) order by x.ord), '[]'::jsonb)
                        from (values ('paid', 1), ('in_retry', 2), ('failed', 3), ('paused', 4)) x(state, ord)
                        left join (select b.payment_state, count(*) as n from b group by 1) q on q.payment_state = x.state)),
    'notes', jsonb_build_object(
      'no_ended_time', (select count(*) from b where b.left_out = 'no_ended_time'),
      'no_created_time', (select count(*) from b where b.left_out = 'no_created_time'),
      'no_amount', (select count(*) from b where b.is_holding and b.is_paying and (b.monthly_amount is null or b.currency is null)),
      'unmatched_subscriptions', (select count(*) from b where b.is_holding and b.customer_id is null),
      'reconstruction_gap', coalesce((select mt.customers from mt where mt.month = v_month), 0) - (select s.customers from stat s where s.dim = 'all'),
      'history_starts', (select coalesce(jsonb_agg(jsonb_build_object('store', q.store, 'market', q.market, 'date', q.d) order by q.d, q.store), '[]'::jsonb)
                         from (select b.store, b.market, (min(b.started_at) at time zone v_zone)::date as d
                               from b where b.started_at is not null group by 1, 2) q),
      'unknown_channel', jsonb_build_object(
        'customers', (select count(*) from c where c.is_active and c.channel = 'unknown'),
        'reasons', (select coalesce(jsonb_object_agg(q.unknown_reason, q.n), '{}'::jsonb)
                    from (select c.unknown_reason, count(*) as n from c where c.is_active and c.channel = 'unknown' and c.unknown_reason is not null
                          group by 1) q)),
      'dominant_cohort', (select jsonb_build_object('cohort', co.cohort, 'share', round(co.started / (select sum(x.started) from co x), 4))
                          from co
                          where (select sum(x.started) from co x) > 0 and co.started / (select sum(x.started) from co x) > 0.4
                          order by co.started desc limit 1)))
  into v_doc;
  return v_head || v_doc;
end
$$;
-- JIT off and a custom plan (as cma.courtesy_page_of, 150): the statement is one of many small joins and aggregates, and a
-- session's first compiled call costs more than the read; the generic plan after five calls on a connection is the wrong one
-- for the filters it then no longer sees (CLAUDE.md, Performance)
alter function cma.active_page_of(uuid, date, text, text, text, text, timestamptz) set jit = off;
alter function cma.active_page_of(uuid, date, text, text, text, text, timestamptz) set plan_cache_mode = force_custom_plan;

-- Customers → Active in one read (reports.view or performance.team, CMA06). p_from_month the history's first month (a
-- month's first day; null: as far back as customers.history_months allows, which also caps an earlier one), p_market a
-- market's code or unknown, p_segment a segment's code or unknown, p_channel indirect, direct or unknown, p_grouping month
-- or quarter (the customer cohorts); anything else CMA04. Team figures only: no person is named or counted
create or replace function cma.active_page(p_from_month date default null, p_market text default null, p_segment text default null,
                                           p_channel text default null, p_grouping text default 'month')
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_active_filter(p_market, p_segment, p_channel);
  if p_from_month is not null and p_from_month <> date_trunc('month', p_from_month)::date then
    raise exception 'the history starts on the first day of a month' using errcode = 'CMA04';
  end if;
  if p_grouping is null or p_grouping not in ('month', 'quarter') then
    raise exception 'the cohorts are grouped by month or quarter, not %', coalesce(p_grouping, 'none') using errcode = 'CMA04';
  end if;
  return cma.active_page_of(v_tenant, p_from_month, p_market, p_segment, p_channel, p_grouping, now());
end
$$;
-- ---------------------------------------------------------------------------------------------
-- 5. The customer list, its file's record
-- ---------------------------------------------------------------------------------------------
-- The active customers under the page's filters, one page of them: total (the customers there are) and rows, each the
-- store's customer id, store, market, segment, Customer start (a date in the tenant's zone), Customer age in months, its
-- holding subscriptions and devices (Flash's figures), its Monthly recurring amount in its currency (the currency of its
-- highest amount; any further currency under other_amounts), its Customer lifetime value (realised) in the store's
-- currency, the worst payment state of its subscriptions (failed, then in_retry, then paused, then paid;
-- cma.subscription_payment_state_of for the page's subscriptions alone), its acquisition channel with First orders'
-- level, and its CRM contact's id with its record link. Ids, codes, dates and amounts only: no name, email, phone or
-- address exists to answer. Sorted in the database: monthly_amount (within currency), clv (within currency),
-- store_customer, store, market, segment, customer_start, age_months, subscriptions, devices, channel or level; ties by
-- the customer's id
create or replace function cma.active_rows_of(p_tenant_id uuid, p_market text, p_segment text, p_channel text, p_sort text,
                                              p_descending boolean, p_offset integer, p_limit integer, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone  text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_today date;
  v_doc   jsonb;
begin
  v_today := (p_now at time zone v_zone)::date;
  if not (coalesce(cma.flash_source_set_up_of(p_tenant_id, 'commerce'), false)
          and coalesce(cma.flash_source_set_up_of(p_tenant_id, 'subscriptions'), false)) then
    return jsonb_build_object('set_up', false, 'as_of', p_now, 'time_zone', v_zone, 'total', 0, 'rows', '[]'::jsonb);
  end if;
  with b as materialized (
    select * from cma.active_base_of(p_tenant_id, p_now, true, (select h.history_start from cma.first_orders_history_start_of(p_tenant_id) h), false) x
    where x.customer_id is not null and coalesce(x.customer_holding, 0) > 0
      and (p_market is null or x.market = p_market) and (p_segment is null or x.segment = p_segment)
      and (p_channel is null or x.channel = p_channel)
  ), amt as (
    -- a customer's Monthly recurring amount per currency, the highest first
    select q.customer_id, q.currency, q.amount, row_number() over (partition by q.customer_id order by q.amount desc, q.currency) as rn
    from (select b.customer_id, b.currency, sum(b.monthly_amount) as amount
          from b where b.is_holding and b.is_paying and b.currency is not null and b.monthly_amount is not null group by 1, 2) q
  ), oth as (
    select o.customer_id, jsonb_object_agg(o.currency, round(o.amount, 2)) as j from amt o where o.rn > 1 group by 1
  ), c as materialized (
    select distinct on (b.customer_id) b.customer_id, b.customer_connection_id, b.customer_source_id, b.store, b.market, b.segment, b.channel,
           b.level, b.customer_start, b.customer_holding, coalesce(b.customer_devices, 0) as devices, b.clv, b.clv_currency,
           b.crm_connection_id, b.contact_source_id, cma.flash_age_months_of(b.customer_start, v_zone, v_today) as age,
           a.currency, a.amount, coalesce(oth.j, '{}'::jsonb) as other_amounts
    from b
    left join amt a on a.customer_id = b.customer_id and a.rn = 1
    left join oth on oth.customer_id = b.customer_id
    order by b.customer_id
  ), k as (
    select c.*,
           case p_sort when 'monthly_amount' then c.amount when 'clv' then c.clv when 'age_months' then c.age::numeric
                       when 'subscriptions' then c.customer_holding::numeric when 'devices' then c.devices::numeric
                       when 'customer_start' then extract(epoch from c.customer_start)::numeric end as num_key,
           case p_sort when 'store_customer' then c.customer_source_id when 'store' then c.store when 'market' then c.market
                       when 'segment' then c.segment when 'channel' then c.channel when 'level' then c.level end as txt_key,
           case p_sort when 'monthly_amount' then c.currency when 'clv' then c.clv_currency end as cur_key
    from c
  ), page as materialized (
    select k.*, row_number() over (order by k.cur_key asc nulls last,
                                            case when not p_descending then k.num_key end asc nulls last,
                                            case when p_descending then k.num_key end desc nulls last,
                                            case when not p_descending then k.txt_key end asc nulls last,
                                            case when p_descending then k.txt_key end desc nulls last,
                                            k.customer_source_id, k.customer_id) as pos
    from k
    order by pos
    offset p_offset limit p_limit
  ), ps as (
    -- the worst payment state of each customer on the page: its subscriptions' states, for these subscriptions alone
    select b.customer_id,
           (array['failed', 'in_retry', 'paused', 'paid'])[min(array_position(array['failed', 'in_retry', 'paused', 'paid'], p.payment_state))] as worst
    from b
    join cma.subscription_payment_state_of(p_tenant_id, array(select b2.subscription_id from b b2 join page on page.customer_id = b2.customer_id)) p
      on p.subscription_id = b.subscription_id
    group by 1
  )
  select jsonb_build_object(
    'set_up', true, 'as_of', p_now, 'time_zone', v_zone,
    'total', (select count(*) from c),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                      'store_customer', page.customer_source_id, 'store', page.store, 'market', page.market, 'segment', page.segment,
                      'customer_start', (page.customer_start at time zone v_zone)::date, 'age_months', page.age,
                      'subscriptions', page.customer_holding, 'devices', page.devices, 'currency', page.currency,
                      'monthly_amount', round(page.amount, 2), 'other_amounts', page.other_amounts,
                      'clv', page.clv, 'clv_currency', page.clv_currency, 'payment_state', ps.worst, 'channel', page.channel, 'level', page.level,
                      'contact_id', page.contact_source_id,
                      'contact_url', cma.record_url(page.crm_connection_id, 'contact', page.contact_source_id)) order by page.pos), '[]'::jsonb)
             from page left join ps on ps.customer_id = page.customer_id))
  into v_doc;
  return v_doc;
end
$$;
alter function cma.active_rows_of(uuid, text, text, text, text, boolean, integer, integer, timestamptz) set jit = off;
alter function cma.active_rows_of(uuid, text, text, text, text, boolean, integer, integer, timestamptz) set plan_cache_mode = force_custom_plan;

-- The list's page (reports.view or performance.team, CMA06): the filters of cma.active_page, a sort key of the list
-- (monthly_amount when left out, descending), an offset from 0 and a limit from 1 to 200; for a file (p_file) the offset
-- is 0 and the limit the tenant's flash.file_max_rows. Anything else CMA04
create or replace function cma.active_rows(p_market text default null, p_segment text default null, p_channel text default null,
                                           p_sort text default 'monthly_amount', p_descending boolean default true, p_offset integer default 0,
                                           p_limit integer default 50, p_file boolean default false)
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
  if coalesce(p_file, false) then
    return cma.active_rows_of(v_tenant, p_market, p_segment, p_channel, p_sort, coalesce(p_descending, true), 0,
                              cma.setting_of(v_tenant, 'flash.file_max_rows')::integer, now());
  end if;
  if p_offset is null or p_offset < 0 or p_limit is null or p_limit not between 1 and 200 then
    raise exception 'a list page starts at 0 or later and holds 1 to 200 rows' using errcode = 'CMA04';
  end if;
  return cma.active_rows_of(v_tenant, p_market, p_segment, p_channel, p_sort, coalesce(p_descending, true), p_offset, p_limit, now());
end
$$;

-- The audit row of a file read of the customer list (as cma.flash_file_record, 160): who, which filters, how many rows;
-- never a row of the file
create or replace function cma.active_file_record(p_market text, p_segment text, p_channel text, p_rows integer)
returns void
language plpgsql
as $$
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_active_filter(p_market, p_segment, p_channel);
  if p_rows is null or p_rows < 0 then
    raise exception 'a file record names its rows' using errcode = 'CMA04';
  end if;
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  values (cma.current_tenant_id(), 'active_file', 'insert', null,
          jsonb_strip_nulls(jsonb_build_object('market', p_market, 'segment', p_segment, 'channel', p_channel, 'rows', p_rows)),
          cma.current_user_id(), cma.current_actor_label());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The readers' rows: the month ends and the customer cohorts, by market, segment and acquisition channel
-- ---------------------------------------------------------------------------------------------
-- Per month from the tenant's first subscription to now, market, segment and acquisition channel: the active customers
-- and the holding subscriptions at the month's end by the reconstruction (the running month's as of p_now), and the
-- customers' inflow and outflow of the month. A subscription whose customer the store does not hold counts under segment
-- and channel unknown, in holding_subscriptions only
create or replace function cma.active_months_of(p_tenant_id uuid, p_now timestamptz)
returns table (month date, market text, segment text, acquisition_channel text, active_customers bigint, holding_subscriptions bigint,
               inflow bigint, outflow bigint)
language sql stable
rows 5000
as $$
  with z as materialized (
    select t.timezone as zone from cma.tenant t where t.id = p_tenant_id
  ), b as materialized (
    select x.market, x.segment, x.channel, x.customer_id, x.started_at, x.ended_at
    from cma.active_base_of(p_tenant_id, p_now, true, (select h.history_start from cma.first_orders_history_start_of(p_tenant_id) h), false) x
    where x.in_history
  ), c as (
    select distinct on (b.customer_id) b.customer_id, b.market, b.segment, b.channel from b where b.customer_id is not null order by b.customer_id
  ), sp as (
    select c.market, c.segment, c.channel, x.spell_start, x.spell_end
    from (select array_agg(b.customer_id::text) as k, array_agg(b.started_at) as s, array_agg(b.ended_at) as e
          from b where b.customer_id is not null) a
    cross join lateral cma.active_spells_from(a.k, a.s, a.e) x
    join c on c.customer_id = x.key::uuid
  ), mc as (
    select x.* from (select array_agg(sp.market) as a, array_agg(sp.segment) as b, array_agg(sp.channel) as c, array_agg(1::numeric) as w,
                            array_agg(sp.spell_start) as s, array_agg(sp.spell_end) as e from sp) a
    cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, (select z.zone from z), p_now) x
  ), ms as (
    select x.* from (select array_agg(b.market) as a, array_agg(b.segment) as b, array_agg(b.channel) as c, array_agg(1::numeric) as w,
                            array_agg(b.started_at) as s, array_agg(b.ended_at) as e from b) a
    cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, (select z.zone from z), p_now) x
  )
  select coalesce(mc.month, ms.month), coalesce(mc.d1, ms.d1), coalesce(mc.d2, ms.d2), coalesce(mc.d3, ms.d3),
         coalesce(mc.at_end, 0)::bigint, coalesce(ms.at_end, 0)::bigint, coalesce(mc.inflow, 0)::bigint, coalesce(mc.outflow, 0)::bigint
  from mc
  full join ms on ms.month = mc.month and ms.d1 = mc.d1 and ms.d2 = mc.d2 and ms.d3 = mc.d3
$$;
alter function cma.active_months_of(uuid, timestamptz) set jit = off;

-- Per customer cohort (the month or quarter of the Customer start), market, segment, acquisition channel and age of
-- customers.cohort_ages_months: the customers started, those still in a spell at their own start plus the age, and
-- whether the row is Mature at the age (cma.active_cohort_cube_from)
create or replace function cma.active_cohorts_of(p_tenant_id uuid, p_grouping text, p_now timestamptz)
returns table (cohort date, market text, segment text, acquisition_channel text, age_months integer, started bigint, still_active bigint,
               mature boolean)
language sql stable
rows 5000
as $$
  with z as materialized (
    select t.timezone as zone, cma.flash_bounds_of(cma.setting_of(t.id, 'customers.cohort_ages_months')) as ages
    from cma.tenant t where t.id = p_tenant_id
  ), b as materialized (
    select x.market, x.segment, x.channel, x.customer_id, x.customer_start, x.started_at, x.ended_at
    from cma.active_base_of(p_tenant_id, p_now, true, (select h.history_start from cma.first_orders_history_start_of(p_tenant_id) h), false) x
    where x.in_history and x.customer_id is not null
  ), c as (
    select distinct on (b.customer_id) b.customer_id, b.market, b.segment, b.channel, b.customer_start from b order by b.customer_id
  ), sp as (
    select c.customer_id, c.market, c.segment, c.channel, c.customer_start, x.spell_start, x.spell_end
    from (select array_agg(b.customer_id::text) as k, array_agg(b.started_at) as s, array_agg(b.ended_at) as e from b) a
    cross join lateral cma.active_spells_from(a.k, a.s, a.e) x
    join c on c.customer_id = x.key::uuid
  )
  select x.cohort, x.d1, x.d2, x.d3, x.age_months, x.started, x.still_active, x.mature
  from (select array_agg(sp.customer_id::text) as k, array_agg(sp.market) as a, array_agg(sp.segment) as b, array_agg(sp.channel) as c,
               array_agg(sp.customer_start) as cs, array_agg(sp.spell_start) as s, array_agg(sp.spell_end) as e from sp) a
  cross join lateral cma.active_cohort_cube_from(a.k, a.a, a.b, a.c, a.cs, a.s, a.e, (select z.ages from z), p_grouping, (select z.zone from z), p_now) x
$$;
alter function cma.active_cohorts_of(uuid, text, timestamptz) set jit = off;

-- For readers (BigQuery, analytics), over SECURITY DEFINER functions in cma_read (owned by cma_owner, search path pinned,
-- executable by readers only) that read every tenant the reader sees, as cma_read.lead_cohort_rows (120) and
-- cma_read.courtesy_order_rows (150): counts per month, market, segment and acquisition channel, and per customer cohort;
-- no customer, no contact and no attribution level. Off the application's path: the planner never inlines them
create or replace function cma_read.active_customer_month_rows()
returns table (tenant_id uuid, month date, market text, segment text, acquisition_channel text, active_customers bigint,
               holding_subscriptions bigint, inflow bigint, outflow bigint)
language sql stable security definer
rows 5000   -- every tenant's months times its markets, segments and channels (CLAUDE.md, Performance: a set-returning function says its rows)
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, r.month, r.market, r.segment, r.acquisition_channel, r.active_customers, r.holding_subscriptions, r.inflow, r.outflow
  from cma.tenant t
  cross join lateral cma.active_months_of(t.id, now()) r
  where cma_read.reader_sees(t.id)
$$;
revoke execute on function cma_read.active_customer_month_rows() from public;
grant execute on function cma_read.active_customer_month_rows() to cma_readonly;

create or replace view cma_read.active_customer_month as
  select * from cma_read.active_customer_month_rows();
comment on view cma_read.active_customer_month is
  'Per tenant, calendar month (the tenant''s zone), market, customer segment and acquisition channel (0009l): the active customers and the holding subscriptions at the month''s end as reconstructed from the subscriptions'' created and ended times (the running month as of now; a past pause counts as holding), and the customers'' inflow and outflow of the month (active spells starting and ending). Counts only: no customer and no contact';

create or replace function cma_read.customer_cohort_rows()
returns table (tenant_id uuid, cohort date, "grouping" text, market text, segment text, acquisition_channel text, started bigint,
               age_months integer, still_active bigint, mature boolean)
language sql stable security definer
rows 5000
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, r.cohort, g.grouping, r.market, r.segment, r.acquisition_channel, r.started, r.age_months, r.still_active, r.mature
  from cma.tenant t
  cross join (values ('month'), ('quarter')) g(grouping)
  cross join lateral cma.active_cohorts_of(t.id, g.grouping, now()) r
  where cma_read.reader_sees(t.id)
$$;
revoke execute on function cma_read.customer_cohort_rows() from public;
grant execute on function cma_read.customer_cohort_rows() to cma_readonly;

create or replace view cma_read.customer_cohort as
  select * from cma_read.customer_cohort_rows();
comment on view cma_read.customer_cohort is
  'Per tenant, customer cohort (the first day of the month or quarter of the Customer start, see grouping), market, customer segment, acquisition channel and age in months of customers.cohort_ages_months (0009l): the customers started, those still in an active spell at their own start plus the age, and whether every customer of the row is that old (mature; until then still_active counts those who are). Counts only: no customer and no contact';

-- ---------------------------------------------------------------------------------------------
-- 7. Grants: the application only (a function made again keeps its grants)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.active_fx_ok(text)', 'cma.active_fx_of(uuid)', 'cma.active_eur_of(numeric,text,jsonb)', 'cma.active_month_factor_of(text,integer)',
    'cma.active_billing_of(text,integer)', 'cma.active_spells_from(text[],timestamptz[],timestamptz[])',
    'cma.active_month_cube_from(text[],text[],text[],numeric[],timestamptz[],timestamptz[],text,timestamptz)',
    'cma.active_cohort_cube_from(text[],text[],text[],text[],timestamptz[],timestamptz[],timestamptz[],integer[],text,text,timestamptz)',
    'cma.active_km_from(integer[],boolean[])', 'cma.active_km_json(integer[],boolean[])',
    'cma.active_base_of(uuid,timestamptz,boolean,date,boolean)', 'cma.active_customers_of(uuid,timestamptz,boolean)', 'cma.active_spells_of(uuid)',
    'cma.active_channel_of(uuid)', 'cma.active_spell_lengths_of(uuid,timestamptz,boolean)', 'cma.active_survival_of(uuid,text,timestamptz)',
    'cma.assert_active_filter(text,text,text)', 'cma.active_page_of(uuid,date,text,text,text,text,timestamptz)',
    'cma.active_page(date,text,text,text,text)',
    'cma.active_rows_of(uuid,text,text,text,text,boolean,integer,integer,timestamptz)',
    'cma.active_rows(text,text,text,text,boolean,integer,integer,boolean)', 'cma.active_file_record(text,text,text,integer)',
    'cma.active_months_of(uuid,timestamptz)', 'cma.active_cohorts_of(uuid,text,timestamptz)'
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
values ('0009l', 'Customers → Active: the settings customers.cohort_ages_months (3,6,12,24,36), customers.age_months (12,24,36,48,60), customers.history_months (60) and reports.fx_eur_rates ({}), checked by cma.check_tenant_setting(); the pure functions cma.active_spells_from (active spells from holding intervals), cma.active_month_cube_from (month ends by running sums), cma.active_cohort_cube_from (customer cohorts by age) and cma.active_km_from (Kaplan–Meier in whole months); cma.active_base_of (the subscriptions with their holding interval from created and ended times, their store customer with Flash''s figures of it, and its acquisition channel from First orders'' attribution of its first order), cma.active_spells_of, cma.active_channel_of, cma.active_survival_of; cma.active_page (the page as one JSON document: tiles with the previous month end and a year before, the month ends, markets with totals, the two segments compared, survival, age bands, cohorts, the subscription mix, the placeholders without a figure, the data notes) and cma.active_rows (the customer list, ids, codes, dates and amounts with the contact''s record link) with cma.active_file_record; cma_read.active_customer_month and cma_read.customer_cohort without a customer or a contact')
on conflict (version) do nothing;

commit;
reset role;
