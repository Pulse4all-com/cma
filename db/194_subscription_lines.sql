-- =============================================================================================
-- 194_subscription_lines.sql: addition 0009w, the subscription app read whole: lines, the product catalog, billing events,
-- more event types, observed changes and a history start (brief B39, Part A)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: tables and functions say subscription app, line, product variant,
-- billing event and chargeback; the adapter maps the source's words (docs/ingest/README.md, section Juo). Runs unchanged
-- in every database, after 192_fleet_page.sql (0009v). Rerunnable, forward-only, in one transaction with a lock timeout.
-- Run as your own IAM login: dev first, then 195_verify_subscription_lines.sql there (normal, then provoked), then the
-- verifies named below, then prod before the merge (the ingest of this change calls the new functions and the new
-- signature of cma.ingest_upsert_subscriptions; the ingest of main runs unchanged on it: its two-argument call of
-- cma.ingest_upsert_subscriptions reaches the new function through the two-argument one, made again as a wrapper).
--
-- Why (Martin, 18 November 2026, brief B39 Part A; Decision log, 18 Nov 2026): the CMA read seven event types and eleven
-- subscription fields per store; Juo holds more that is not personal (the probes of 18 November 2026): each
-- subscription's lines, the store's product catalog, chargebacks, refunds, invoice renewals, skips, billing-date moves,
-- frequency and line changes, migrations. Part A mirrors them read only, so Parts B to F can compute churn rate,
-- movements, renewal outcomes and payment follow-up from the CMA's own mirror. The subscription app stays the owner of
-- every subscription fact (README, Source of truth). Nothing personal is stored: no name, email, phone, address, payment
-- detail, custom attribute, free-text message or reason; a catalog title or SKU is the store's own text (at most 100
-- characters, never an @ or a control character).
--
-- What it adds
--   setting            subscriptions.history_start_date (a date as YYYY-MM-DD, or empty): the first date the backfill of a
--                      subscription app's events and billing events reads without --from; empty reads all of the app's
--                      history. It may lie before intake.start_date (as reviews.history_start_date). The default is empty
--                      (no seed row). cma.check_tenant_setting() trims and checks it as the other start dates
--   runs               cma.ingest_sync_run_finish() takes lines_new, lines_missing, variants_new, billing_events_new,
--                      changes_observed, instrument_unknown, duplicate_skipped, return_code_dropped and
--                      catalog_text_dropped among the counts; the new streams (subscription_product, billing_event) need no
--                      change (sync_run.stream is a form, not a list)
--   subscriptions      cma.subscription gains source_number (the app's own sequence number, #2502), min_cycles and
--                      max_cycles (its billing policy's), discount_count (how many discounts, never a code), line_count
--                      (its lines the app has not canceled) and device_units (null: Part C fills it from the variant
--                      mapping); payment_instrument_type takes card, paypal, sepa_direct_debit, ideal, bancontact, invoice
--                      or other; raw takes serial, minCycles, maxCycles, discountCount, lineCount
--   lines              cma.subscription_line: one row per line of a subscription and connection, canceled lines included
--                      (product, variant, quantity, amount per cycle, currency, billing interval and count, min and max
--                      cycles, recurring cycle limit: null recurring, 1 a one-time add-on; canceled_at; source_deleted_at
--                      once the subscription's latest read no longer holds it); cma.ingest_upsert_subscription_lines
--                      (connection, subscription ids, items, run) takes the given subscriptions' lines as a set
--   catalog            cma.subscription_product_variant: the store's catalog per variant (product and variant ids, titles,
--                      SKU, product status, source_deleted_at); cma.ingest_upsert_subscription_products(connection, items)
--                      takes the full catalog of one read and marks a variant it no longer holds missing
--   billing events     cma.billing_event, append-only: chargeback, refund_created, refund_completed, refund_failed,
--                      invoice_placed, invoice_paid, invoice_overdue, invoice_payment_failed, order_placement_failed,
--                      order_draft_created; the subscription (when the app names it), the store customer, the store's
--                      order, the renewal, the app's own record (owner), amount and currency, the payment scheme's return
--                      code, the instrument type, attempt and error code, partial (a refund); never a message or a note.
--                      cma.ingest_upsert_billing_events(connection, items): new ones inserted, held ones left as they are
--   event types        cma.subscription_event takes purchased, created, migrated, skipped, billing_date_moved,
--                      interval_changed, lines_changed, payment_method_changed, discount_changed, merged_to, merged_from,
--                      split_to, split_from, renewal_notice and update_failed besides the seven, and the columns
--                      billing_from_at, billing_to_at, cause_code, interval_from, interval_count_from, interval_to,
--                      interval_count_to, lines_added, lines_removed, lines_updated, related_subscription_source_id,
--                      operation_source_id (the app's id of the operation that wrote it, which pairs the events of one
--                      change) and order_source_id (a renewal's store order, until now in raw only: what a chargeback's
--                      order joins); cma.ingest_upsert_subscription_events made again with them
--   observed changes   cma.subscription_change, append-only: the CMA's own observation when a read finds a known
--                      subscription's status, amount_per_cycle, currency, billing_interval, billing_interval_count or
--                      line_count (cma.ingest_upsert_subscriptions) or the sum of its recurring lines' quantities
--                      (recurring_quantity, cma.ingest_upsert_subscription_lines) differing from the stored value: one row
--                      with the field, old and new value, observed_at and the run. A value held as null (before this
--                      addition's first read) is a start, never a change, so the first read after this script writes none
--   upserts            cma.ingest_upsert_subscriptions(connection, items, run), new: the new columns, the seven instrument
--                      types, the observed changes with the run, and the count of changes per subscription; the
--                      two-argument function made again as a call of it without a run (same answers as before)
--   readers            cma_read.subscription_line, cma_read.subscription_product_variant, cma_read.billing_event and
--                      cma_read.subscription_change (every column but raw); cma_read.subscription and
--                      cma_read.subscription_event gain the new columns (at their end)
--
-- Busy table (CLAUDE.md, Performance): cma.subscription_event's new columns and checks go last, directly before the
-- schema_migration insert, with its reader view; the ACCESS EXCLUSIVE lock they take is held until the commit. No index
-- is created on it: subscription_event_type_occurred_idx (122) already holds (tenant_id, event_type, occurred_at), and
-- Part C adds one when a read of its needs it. cma.billing_event is new and empty, so its indexes are made here.
--
-- Functions re-created and the verifies to run again afterwards (all edited by nothing here unless said):
--   cma.check_tenant_setting()                       (base 184)  by name: 73, 101, 113, 121, 123, 137, 179; through its
--                                                                trigger: 14, 27, 185
--   cma.ingest_sync_run_finish(uuid,text,jsonb,text)  (base 118)  33, 69, 75, 79, 105, 107, 109, 115, 117, 119
--   cma.ingest_upsert_subscriptions(uuid,jsonb)       (base 118, now a wrapper of the new three-argument function)  119
--   cma.ingest_upsert_subscription_events(uuid,jsonb) (base 118)  119
-- 119 passes unchanged: its fixtures use the old instrument types and event types, which the new checks still take. No
-- verify is edited by this change. The readers of cma.subscription and cma.subscription_event (Flash, Installed base,
-- Active, the job reads, the payment state) name their columns, so the added columns change none of them; no read is
-- added for a page, so 131_time_all.sql, round-trips.json and perf.json gain no row.
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
  if not exists (select 1 from cma.schema_migration where version = '0009v') then
    raise exception 'addition 0009v (192_fleet_page.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The setting: subscriptions.history_start_date
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('subscriptions.history_start_date', 'text', null, '',
     'First date the backfill of the subscription app''s events and billing events reads without --from, as YYYY-MM-DD (it may lie before intake.start_date); a --from before it is refused. Empty means all of the app''s history')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0009r (184), with subscriptions.history_start_date trimmed and checked as a date (or empty) next to the other start
-- dates
-- based on: 184_active_device_bands.sql
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
-- 2. Runs: the counts of a read of lines, the catalog and billing events
-- ---------------------------------------------------------------------------------------------
-- As 0008zl (118), plus lines_new, lines_missing, variants_new, billing_events_new, changes_observed, instrument_unknown,
-- duplicate_skipped, return_code_dropped and catalog_text_dropped
-- based on: 118_subscriptions.sql
create or replace function cma.ingest_sync_run_finish(p_run_id uuid, p_status text, p_counts jsonb, p_error text default null)
returns void
language plpgsql
as $$
declare
  v_status text;
begin
  perform cma.assert_permission('ingest.write');
  if p_status not in ('succeeded', 'failed') then
    raise exception 'status must be succeeded or failed' using errcode = 'CMA04';
  end if;
  if p_counts is not null and (jsonb_typeof(p_counts) <> 'object'
     or exists (select 1 from jsonb_each(p_counts) e
                where e.key not in ('fetched', 'upserted', 'stale', 'skipped', 'failed', 'dropped', 'ref_dropped',
                                    'rows', 'inserted', 'updated', 'unchanged', 'missing_now', 'components_replaced', 'components_closed',
                                    'unmapped_model', 'unmapped_status', 'unmapped_market', 'customer_ref_invalid', 'refs_dropped',
                                    'stage_ms', 'map_ms', 'upsert_ms', 'components_ms', 'missing_ms', 'cleanup_ms', 'chunk_max_ms', 'slice_max_ms',
                                    'chunk_size_min', 'chunk_halvings', 'events_new', 'customers_unmatched', 'reason_dropped',
                                    'lines_new', 'lines_missing', 'variants_new', 'billing_events_new', 'changes_observed',
                                    'instrument_unknown', 'duplicate_skipped', 'return_code_dropped', 'catalog_text_dropped')
                   or jsonb_typeof(e.value) <> 'number' or (e.value #>> '{}') !~ '^\d+$')) then
    raise exception 'counts are whole numbers for fetched, upserted, stale, skipped, failed, dropped and ref_dropped, a device load''s counts and its phase times, and a subscriptions read''s counts'
      using errcode = 'CMA04';
  end if;
  select r.status into v_status from cma.sync_run r where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id for update;
  if v_status is null then
    raise exception 'no sync run % in the current tenant', p_run_id using errcode = 'CMA02';
  end if;
  if v_status <> 'running' then
    raise exception 'sync run % is already finished', p_run_id using errcode = 'CMA03';
  end if;
  update cma.sync_run r
     set status = p_status, finished_at = now(), counts = coalesce(p_counts, '{}'::jsonb), error = left(nullif(btrim(p_error), ''), 200)
   where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------------------------
-- A store's catalog text (a product's or variant's title, a SKU): 1 to 100 characters, never an @ and never a control
-- character. It is the merchant's own text, never a customer's. Null for null (a column's check then passes a missing
-- title, as every check passes a null)
create or replace function cma.catalog_text_ok(p_value text)
returns boolean
language sql immutable
as $$
  select length(p_value) between 1 and 100 and strpos(p_value, '@') = 0 and p_value !~ '[[:cntrl:]]'
$$;

-- A payment instrument's type in the CMA's codes
create or replace function cma.payment_instrument_type_ok(p_value text)
returns boolean
language sql immutable
as $$
  select p_value in ('card', 'paypal', 'sepa_direct_debit', 'ideal', 'bancontact', 'invoice', 'other')
$$;

-- The run an ingest call names (ingest.write): a running sync run of the connection in the current tenant; CMA04
-- otherwise. A null run is no run (an observed change then has none)
create or replace function cma.assert_running_run(p_connection_id uuid, p_run_id uuid)
returns void
language plpgsql stable
as $$
begin
  if p_run_id is not null and not exists (
       select 1 from cma.sync_run r
       where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id and r.connection_id = p_connection_id and r.status = 'running') then
    raise exception 'run % is no running run of connection %', p_run_id, p_connection_id using errcode = 'CMA04';
  end if;
end
$$;
revoke execute on function cma.catalog_text_ok(text), cma.payment_instrument_type_ok(text), cma.assert_running_run(uuid, uuid) from public;
grant execute on function cma.catalog_text_ok(text), cma.payment_instrument_type_ok(text), cma.assert_running_run(uuid, uuid) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 4. Subscriptions: the new columns, the seven instrument types, the wider raw
-- ---------------------------------------------------------------------------------------------
alter table cma.subscription
  add column if not exists source_number  text check (source_number ~ '^#?[A-Za-z0-9-]{1,30}$'),
  add column if not exists min_cycles     integer check (min_cycles between 0 and 1000),
  add column if not exists max_cycles     integer check (max_cycles between 0 and 1000),
  add column if not exists discount_count integer check (discount_count between 0 and 1000),
  add column if not exists line_count     integer check (line_count between 0 and 1000),
  add column if not exists device_units   integer check (device_units >= 0);
alter table cma.subscription drop constraint if exists subscription_payment_instrument_type_check;
alter table cma.subscription add constraint subscription_payment_instrument_type_check
  check (cma.payment_instrument_type_ok(payment_instrument_type));
alter table cma.subscription drop constraint if exists subscription_raw_check;
alter table cma.subscription add constraint subscription_raw_check
  check (cma.subscription_raw_ok(raw, array['id', 'status', 'customer', 'currentCycle', 'nextBillingDate', 'billingInterval',
                                            'billingIntervalCount', 'amountPerCycle', 'currencyCode', 'instrumentType', 'createdAt',
                                            'updatedAt', 'canceledAt', 'pausedAt', 'serial', 'minCycles', 'maxCycles', 'discountCount',
                                            'lineCount']));
comment on column cma.subscription.payment_instrument_type is 'The type of the payment method''s instrument only: card, paypal, sepa_direct_debit, ideal, bancontact, invoice or other (null when unknown); nothing else of the payment method (0008zl; seven codes since 0009w)';
comment on column cma.subscription.source_number is 'The subscription app''s own sequence number of the subscription (for example #2502), so staff can find it in the app; not a device serial (0009w)';
comment on column cma.subscription.min_cycles is 'The minimum number of billing cycles of the subscription''s billing policy as the source states it (else its lines'' highest); null when the source holds none (0009w)';
comment on column cma.subscription.max_cycles is 'The maximum number of billing cycles of the subscription''s billing policy as the source states it (else its lines'' highest); null when the source holds none (0009w)';
comment on column cma.subscription.discount_count is 'How many discounts the subscription carries; never a discount''s code or value (0009w)';
comment on column cma.subscription.line_count is 'How many of the subscription''s lines the source has not canceled (0009w)';
comment on column cma.subscription.device_units is 'Devices paid for: the sum over its recurring lines not canceled of quantity × the variant mapping''s devices per unit; null until Part C of brief B39 fills it (0009w)';

-- ---------------------------------------------------------------------------------------------
-- 5. Lines, the catalog, billing events and observed changes
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.subscription_line (
  id                       uuid primary key default uuidv7(),
  tenant_id                uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id            uuid not null,
  source_system            text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_id                text not null check (cma.subscription_id_ok(source_id)),
  subscription_source_id   text not null check (cma.subscription_id_ok(subscription_source_id)),
  product_source_id        text check (cma.subscription_id_ok(product_source_id)),
  variant_source_id        text check (cma.subscription_id_ok(variant_source_id)),
  quantity                 integer check (quantity between 0 and 100000),
  amount_per_cycle         numeric(14,2) check (amount_per_cycle >= 0),
  currency                 text check (currency ~ '^[A-Z]{3}$'),
  billing_interval         text check (billing_interval in ('day', 'week', 'month', 'year')),
  billing_interval_count   integer check (billing_interval_count between 1 and 1000),
  min_cycles               integer check (min_cycles between 0 and 1000),
  max_cycles               integer check (max_cycles between 0 and 1000),
  recurring_cycle_limit    integer check (recurring_cycle_limit between 1 and 1000),
  canceled_at              timestamptz,
  first_seen_at            timestamptz not null default now(),
  synced_at                timestamptz not null default now(),
  source_deleted_at        timestamptz,
  raw                      jsonb not null default '{}'::jsonb
                           check (cma.subscription_raw_ok(raw, array['id', 'subscriptionId', 'product', 'variant', 'quantity', 'totalPrice',
                                                                     'currencyCode', 'interval', 'intervalCount', 'minCycles', 'maxCycles',
                                                                     'recurringCycleLimit', 'canceledAt'])),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.subscription_line is 'A subscription app''s lines of its subscriptions per connection, canceled lines included: product and variant ids, quantity, amount per cycle, billing interval, cycle limits, canceled time. No title, custom attribute or customer data. Owned by the subscription app (0009w)';
comment on column cma.subscription_line.amount_per_cycle is 'The line''s total price per billing cycle as the source states it, in currency (the subscription''s)';
comment on column cma.subscription_line.recurring_cycle_limit is 'How many cycles the line is billed: null for every cycle (recurring), 1 for a one-time add-on';
comment on column cma.subscription_line.source_deleted_at is 'When the subscription''s latest read no longer held the line; null while it does';
comment on column cma.subscription_line.raw is 'The line''s mapped values under the source''s names only (checked keys, scalar values, never an @)';
create index if not exists subscription_line_subscription_idx on cma.subscription_line (tenant_id, connection_id, subscription_source_id);
create index if not exists subscription_line_variant_idx on cma.subscription_line (tenant_id, connection_id, variant_source_id)
  where variant_source_id is not null;

create table if not exists cma.subscription_product_variant (
  id                  uuid primary key default uuidv7(),
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id       uuid not null,
  source_system       text not null check (source_system ~ '^[a-z0-9_]+$'),
  product_source_id   text not null check (cma.subscription_id_ok(product_source_id)),
  variant_source_id   text not null check (cma.subscription_id_ok(variant_source_id)),
  product_title       text check (cma.catalog_text_ok(product_title)),
  variant_title       text check (cma.catalog_text_ok(variant_title)),
  sku                 text check (cma.catalog_text_ok(sku)),
  product_status      text check (product_status ~ '^[a-z][a-z_]{0,19}$'),
  first_seen_at       timestamptz not null default now(),
  synced_at           timestamptz not null default now(),
  source_deleted_at   timestamptz,
  unique (tenant_id, id),
  unique (tenant_id, connection_id, variant_source_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.subscription_product_variant is 'The store''s product catalog as the subscription app holds it, one row per variant and connection: product and variant ids, titles, SKU and the product''s status. Merchant catalog text only (cma.catalog_text_ok), never customer data. Owned by the subscription app (0009w)';
comment on column cma.subscription_product_variant.source_deleted_at is 'When the latest full read of the catalog no longer held the variant; null while it does';

create table if not exists cma.billing_event (
  id                      uuid primary key default uuidv7(),
  tenant_id               uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id           uuid not null,
  source_system           text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_id               text not null check (cma.subscription_id_ok(source_id)),
  kind                    text not null check (kind in ('chargeback', 'refund_created', 'refund_completed', 'refund_failed',
                                                       'invoice_placed', 'invoice_paid', 'invoice_overdue', 'invoice_payment_failed',
                                                       'order_placement_failed', 'order_draft_created')),
  occurred_at             timestamptz not null,
  subscription_source_id  text check (cma.subscription_id_ok(subscription_source_id)),
  customer_source_id      text check (cma.subscription_id_ok(customer_source_id)),
  order_source_id         text check (order_source_id ~ '^\d{1,30}$'),
  renewal_source_id       text check (cma.subscription_id_ok(renewal_source_id)),
  owner_source_id         text check (cma.subscription_id_ok(owner_source_id)),
  amount                  numeric(14,2) check (amount >= 0),
  currency                text check (currency ~ '^[A-Z]{3}$'),
  return_code             text check (return_code ~ '^[A-Za-z0-9][A-Za-z0-9_]{1,39}$'),
  instrument_type         text check (cma.payment_instrument_type_ok(instrument_type)),
  attempt                 integer check (attempt between 1 and 1000),
  error_code              text check (error_code ~ '^[A-Za-z][A-Za-z0-9_]{0,59}$'),
  partial                 boolean,
  synced_at               timestamptz not null default now(),
  raw                     jsonb not null default '{}'::jsonb
                          check (cma.subscription_raw_ok(raw, array['id', 'type', 'occurredAt', 'subscriptionId', 'customerId', 'orderId',
                                                                    'renewalId', 'ownerId', 'amount', 'currencyCode', 'reasonCode',
                                                                    'instrumentType', 'attempt', 'errorCode', 'partial'])),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  check (return_code is null or kind = 'chargeback'),
  check (partial is null or kind like 'refund\_%'),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.billing_event is 'A subscription app''s billing events per connection: chargebacks, refunds, invoice renewals and orders the app could not place. Ids, codes, amounts and times only; never a message, a note or payment details. Append-only. Owned by the subscription app (0009w)';
comment on column cma.billing_event.kind is 'The billing event in the CMA''s words; the adapter maps the source''s types (docs/ingest/README.md, the adapter''s section)';
comment on column cma.billing_event.subscription_source_id is 'The subscription when the source names it (an invoice''s); a chargeback or refund carries the customer and the store''s order, not always the subscription';
comment on column cma.billing_event.order_source_id is 'The store''s order id (digits) the event is about: a chargeback''s or refund''s order';
comment on column cma.billing_event.renewal_source_id is 'The source''s id of the renewal an invoice was placed for';
comment on column cma.billing_event.owner_source_id is 'The source''s own id of the record the event belongs to (the chargeback, the refund, the invoice''s order), which pairs an invoice placed with its payment';
comment on column cma.billing_event.return_code is 'The payment scheme''s return reason as a code (a SEPA return code such as MD01, a card dispute reason such as fraudulent); the message is never read';
comment on column cma.billing_event.raw is 'The event''s mapped values under the source''s names only (checked keys, scalar values, never an @)';
create index if not exists billing_event_order_idx on cma.billing_event (tenant_id, connection_id, order_source_id)
  where order_source_id is not null;
create index if not exists billing_event_kind_occurred_idx on cma.billing_event (tenant_id, kind, occurred_at);
create index if not exists billing_event_subscription_idx on cma.billing_event (tenant_id, connection_id, subscription_source_id)
  where subscription_source_id is not null;

create table if not exists cma.subscription_change (
  id                      uuid primary key default uuidv7(),
  tenant_id               uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id           uuid not null,
  subscription_source_id  text not null check (cma.subscription_id_ok(subscription_source_id)),
  field                   text not null check (field in ('status', 'amount_per_cycle', 'currency', 'billing_interval',
                                                         'billing_interval_count', 'line_count', 'recurring_quantity')),
  old_value               text not null check (length(old_value) between 1 and 40 and strpos(old_value, '@') = 0),
  new_value               text check (length(new_value) between 1 and 40 and strpos(new_value, '@') = 0),
  observed_at             timestamptz not null default now(),
  run_id                  uuid,
  unique (tenant_id, id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.subscription_change is 'The CMA''s own observation of a subscription''s change: a read found the field''s value different from the one stored (status, amount_per_cycle, currency, billing_interval, billing_interval_count, line_count, recurring_quantity). History from addition 0009w''s first read on; a value stored as null is a start, never a change. Append-only (0009w)';
comment on column cma.subscription_change.new_value is 'The value the read found, as text; null when the source no longer states one';
comment on column cma.subscription_change.run_id is 'The sync run whose read observed the change (cma.sync_run.id, checked running when written; no foreign key, so sync_run, a busy table, takes no lock from this table); null for a call that named none';
create index if not exists subscription_change_subscription_idx
  on cma.subscription_change (tenant_id, connection_id, subscription_source_id, observed_at);
create index if not exists subscription_change_observed_idx on cma.subscription_change (tenant_id, observed_at);

select cma.setup_tenant_table('cma.subscription_line');
select cma.setup_tenant_table('cma.subscription_product_variant');
select cma.setup_tenant_table('cma.billing_event');
select cma.setup_tenant_table('cma.subscription_change');

-- The application never deletes a line or a variant (a missing one gets source_deleted_at), and never changes or deletes
-- a billing event or an observed change: the ingest inserts them only
revoke delete on cma.subscription_line, cma.subscription_product_variant from cma_app;
revoke update, delete on cma.billing_event, cma.subscription_change from cma_app;

-- ---------------------------------------------------------------------------------------------
-- 6. The ingest's writes
-- ---------------------------------------------------------------------------------------------
-- Subscriptions of a connection, as 0008zl (118) with a run (the ingest of this change passes its run; a null run is none): [{sourceId, sourceNumber, customerSourceId, status,
-- currentCycle, nextBillingAt, billingInterval, billingIntervalCount, amountPerCycle, currency, paymentInstrumentType,
-- minCycles, maxCycles, discountCount, lineCount, sourceCreatedAt, pausedAt, canceledAt, sourceUpdatedAt, raw}], at most
-- 500, each id once. A subscription whose source update time is older than the stored one is stale and left as it is. A
-- new one is inserted; a known one is updated when anything differs (and comes back when it was missing), else unchanged.
-- paused_at: the source's pausedAt, else the latest paused event's time, else the stored one, while the status is paused;
-- null otherwise. device_units is never written here (Part C). An update writes one cma.subscription_change per field of
-- status, amount_per_cycle, currency, billing_interval, billing_interval_count and line_count whose stored value was not
-- null and differs, with the run (p_run_id: a running run of the connection, or null). Answers per subscription its
-- outcome (inserted, updated, unchanged, stale), whether its customer is among the customers of the connection's store
-- (null without a customer id) and the changes it observed. CMA04 for an item out of its form, a run that is no running
-- run of the connection, a connection without its store (store_not_configured) or one the ingest does not read
-- The three-argument function is new (no default on the run, so a call with two arguments still means the two-argument
-- function below, which stays for the ingest of main and 119)
create or replace function cma.ingest_upsert_subscriptions(p_connection_id uuid, p_items jsonb, p_run_id uuid)
returns table (source_id text, outcome text, customer_matched boolean, changes_observed integer)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_target   record;
  i          jsonb;
  v_id       text;
  v_number   text;
  v_customer text;
  v_status   text;
  v_cycle    integer;
  v_next     timestamptz;
  v_interval text;
  v_count    integer;
  v_amount   numeric;
  v_currency text;
  v_instr    text;
  v_min      integer;
  v_max      integer;
  v_disc     integer;
  v_lines    integer;
  v_created  timestamptz;
  v_paused   timestamptz;
  v_canceled timestamptz;
  v_upd      timestamptz;
  v_raw      jsonb;
  v_old      cma.subscription;
  v_n        integer;
begin
  select * into v_target from cma.subscriptions_ingest_target(p_connection_id);
  perform cma.assert_running_run(p_connection_id, p_run_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500
     or exists (select 1 from jsonb_array_elements(p_items) x where jsonb_typeof(x) <> 'object') then
    raise exception 'items must be an array of at most 500 subscriptions' using errcode = 'CMA04';
  end if;
  if (select count(*) <> count(distinct x ->> 'sourceId') from jsonb_array_elements(p_items) x) then
    raise exception 'a subscription appears twice among the items' using errcode = 'CMA04';
  end if;
  for i in select x from jsonb_array_elements(p_items) x loop
    v_id := i ->> 'sourceId';
    if not coalesce(cma.subscription_id_ok(v_id), false) then
      raise exception 'a subscription needs an id (a letter or a digit, then letters, digits, _ . : -, at most 100)' using errcode = 'CMA04';
    end if;
    v_number := nullif(i ->> 'sourceNumber', '');
    v_customer := nullif(i ->> 'customerSourceId', '');
    v_status := i ->> 'status';
    v_interval := i ->> 'billingInterval';
    v_currency := i ->> 'currency';
    v_instr := i ->> 'paymentInstrumentType';
    if (v_customer is not null and not cma.subscription_id_ok(v_customer))
       or coalesce(v_status, '') not in ('active', 'paused', 'canceled', 'expired', 'failed', 'merged', 'never-subscribed')
       or (v_interval is not null and v_interval not in ('day', 'week', 'month', 'year'))
       or (v_currency is not null and v_currency !~ '^[A-Z]{3}$')
       or (v_instr is not null and not cma.payment_instrument_type_ok(v_instr))
       or (v_number is not null and v_number !~ '^#?[A-Za-z0-9-]{1,30}$')
       or (i ? 'amountPerCycle' and jsonb_typeof(i -> 'amountPerCycle') not in ('number', 'null'))
       or (i ? 'raw' and jsonb_typeof(i -> 'raw') <> 'object') then
      raise exception 'subscription %: a customer id, a status of the seven, an interval of day, week, month or year, a currency code, an instrument of card, paypal, sepa_direct_debit, ideal, bancontact, invoice or other, a number as #2502, a number for the amount and an object for raw', v_id
        using errcode = 'CMA04';
    end if;
    v_cycle := cma.subscription_json_int(i -> 'currentCycle', 'currentCycle');
    v_count := cma.subscription_json_int(i -> 'billingIntervalCount', 'billingIntervalCount');
    v_min := cma.subscription_json_int(i -> 'minCycles', 'minCycles');
    v_max := cma.subscription_json_int(i -> 'maxCycles', 'maxCycles');
    v_disc := cma.subscription_json_int(i -> 'discountCount', 'discountCount');
    v_lines := cma.subscription_json_int(i -> 'lineCount', 'lineCount');
    v_amount := round((i ->> 'amountPerCycle')::numeric, 2);
    v_next := cma.json_time(i -> 'nextBillingAt', 'nextBillingAt');
    v_created := cma.json_time(i -> 'sourceCreatedAt', 'sourceCreatedAt');
    v_paused := cma.json_time(i -> 'pausedAt', 'pausedAt');
    v_canceled := cma.json_time(i -> 'canceledAt', 'canceledAt');
    v_upd := cma.json_time(i -> 'sourceUpdatedAt', 'sourceUpdatedAt');
    v_raw := coalesce(i -> 'raw', '{}'::jsonb);

    v_old := null;
    changes_observed := 0;
    select * into v_old from cma.subscription s
    where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.source_id = v_id
    for update;
    if v_old.id is not null and v_upd is not null and v_old.source_updated_at is not null and v_upd < v_old.source_updated_at then
      source_id := v_id; outcome := 'stale';
      customer_matched := case when v_old.customer_source_id is not null then exists (
        select 1 from cma.commerce_customer cu
        where cu.tenant_id = v_tenant and cu.connection_id = v_target.store_connection_id and cu.source_id = v_old.customer_source_id) end;
      return next;
      continue;
    end if;

    -- when the current pause began: the source's time, else the latest pause event, else the stored time
    v_paused := case when v_status = 'paused' then coalesce(
                  v_paused,
                  (select max(e.occurred_at) from cma.subscription_event e
                   where e.tenant_id = v_tenant and e.connection_id = p_connection_id and e.subscription_source_id = v_id
                     and e.status_to = 'paused'),
                  case when v_old.status = 'paused' then v_old.paused_at end) end;

    if v_old.id is null then
      insert into cma.subscription (tenant_id, connection_id, source_system, source_id, source_number, customer_source_id, status,
                                    current_cycle, next_billing_at, billing_interval, billing_interval_count, amount_per_cycle,
                                    currency, payment_instrument_type, min_cycles, max_cycles, discount_count, line_count,
                                    source_created_at, paused_at, canceled_at, source_updated_at, raw)
      values (v_tenant, p_connection_id, v_target.adapter, v_id, v_number, v_customer, v_status, v_cycle, v_next, v_interval, v_count,
              v_amount, v_currency, v_instr, v_min, v_max, v_disc, v_lines, v_created, v_paused, v_canceled, v_upd, v_raw);
      outcome := 'inserted';
    elsif (v_old.source_number, v_old.customer_source_id, v_old.status, v_old.current_cycle, v_old.next_billing_at, v_old.billing_interval,
           v_old.billing_interval_count, v_old.amount_per_cycle, v_old.currency, v_old.payment_instrument_type, v_old.min_cycles,
           v_old.max_cycles, v_old.discount_count, v_old.line_count, v_old.source_created_at, v_old.paused_at, v_old.canceled_at,
           v_old.source_updated_at, v_old.raw, v_old.source_deleted_at)
          is distinct from
          (v_number, v_customer, v_status, v_cycle, v_next, v_interval, v_count, v_amount, v_currency, v_instr, v_min, v_max, v_disc,
           v_lines, v_created, v_paused, v_canceled, v_upd, v_raw, null::timestamptz) then
      update cma.subscription s
         set source_number = v_number, customer_source_id = v_customer, status = v_status, current_cycle = v_cycle,
             next_billing_at = v_next, billing_interval = v_interval, billing_interval_count = v_count, amount_per_cycle = v_amount,
             currency = v_currency, payment_instrument_type = v_instr, min_cycles = v_min, max_cycles = v_max,
             discount_count = v_disc, line_count = v_lines, source_created_at = v_created, paused_at = v_paused,
             canceled_at = v_canceled, source_updated_at = v_upd, raw = v_raw, source_deleted_at = null, synced_at = now()
       where s.tenant_id = v_tenant and s.id = v_old.id;
      outcome := 'updated';
      -- the CMA's own observation: a field stored with a value that the read finds different (a null stored is a start)
      insert into cma.subscription_change (tenant_id, connection_id, subscription_source_id, field, old_value, new_value, run_id)
      select v_tenant, p_connection_id, v_id, c.field, c.old_value, c.new_value, p_run_id
      from (values ('status', v_old.status, v_status),
                   ('amount_per_cycle', v_old.amount_per_cycle::text, v_amount::text),
                   ('currency', v_old.currency, v_currency),
                   ('billing_interval', v_old.billing_interval, v_interval),
                   ('billing_interval_count', v_old.billing_interval_count::text, v_count::text),
                   ('line_count', v_old.line_count::text, v_lines::text)) c (field, old_value, new_value)
      where c.old_value is not null and c.old_value is distinct from c.new_value;
      get diagnostics v_n = row_count;
      changes_observed := v_n;
    else
      outcome := 'unchanged';
    end if;
    source_id := v_id;
    customer_matched := case when v_customer is not null then exists (
      select 1 from cma.commerce_customer cu
      where cu.tenant_id = v_tenant and cu.connection_id = v_target.store_connection_id and cu.source_id = v_customer) end;
    return next;
  end loop;
exception when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
  raise exception 'invalid subscription: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- As 0008zl (118): the two-argument call, now the three-argument function without a run (the ingest of main, 119); the
-- same answers but the count of changes
-- based on: 118_subscriptions.sql
create or replace function cma.ingest_upsert_subscriptions(p_connection_id uuid, p_items jsonb)
returns table (source_id text, outcome text, customer_matched boolean)
language sql
as $$
  select u.source_id, u.outcome, u.customer_matched from cma.ingest_upsert_subscriptions(p_connection_id, p_items, null::uuid) u
$$;

-- The lines of some subscriptions of a connection, as a set: p_subscription_ids the subscriptions read (1 to 500, each
-- once) and p_items every line the read returned for them, canceled ones included: [{sourceId, subscriptionSourceId,
-- productSourceId, variantSourceId, quantity, amountPerCycle, currency, billingInterval, billingIntervalCount, minCycles,
-- maxCycles, recurringCycleLimit, canceledAt, raw}], at most 5,000, each id once, each of one of the subscriptions named.
-- A new line is inserted; a known one is updated when anything differs (and comes back when it was missing, or moves to
-- the subscription that now holds it), else unchanged; a line of those subscriptions the items do not hold gets
-- source_deleted_at (missing). A subscription whose lines were held before and whose sum of recurring lines' quantities
-- (lines held, not canceled, without a cycle limit) differs afterwards gets one cma.subscription_change recurring_quantity,
-- with the run (p_run_id: a running run of the connection, or null). Answers { inserted, updated, unchanged, missing_now,
-- changes_observed }. CMA04 for an item out of its form, a line of a subscription not named, a run that is no running
-- run of the connection, a connection without its store or one the ingest does not read
create or replace function cma.ingest_upsert_subscription_lines(p_connection_id uuid, p_subscription_ids text[], p_items jsonb,
                                                                p_run_id uuid default null)
returns jsonb
language plpgsql
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_target   record;
  i          jsonb;
  v_id       text;
  v_sub      text;
  v_product  text;
  v_variant  text;
  v_qty      integer;
  v_amount   numeric;
  v_currency text;
  v_interval text;
  v_count    integer;
  v_min      integer;
  v_max      integer;
  v_limit    integer;
  v_canceled timestamptz;
  v_raw      jsonb;
  v_old      cma.subscription_line;
  v_before   jsonb;
  v_ins      integer := 0;
  v_updn     integer := 0;
  v_same     integer := 0;
  v_missing  integer;
  v_changes  integer;
begin
  select * into v_target from cma.subscriptions_ingest_target(p_connection_id);
  perform cma.assert_running_run(p_connection_id, p_run_id);
  if coalesce(cardinality(p_subscription_ids), 0) not between 1 and 500
     or exists (select 1 from unnest(p_subscription_ids) x where not coalesce(cma.subscription_id_ok(x), false))
     or (select count(*) <> count(distinct x) from unnest(p_subscription_ids) x) then
    raise exception 'the subscriptions read are 1 to 500 subscription ids, each once' using errcode = 'CMA04';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 5000
     or exists (select 1 from jsonb_array_elements(p_items) x where jsonb_typeof(x) <> 'object') then
    raise exception 'items must be an array of at most 5,000 lines' using errcode = 'CMA04';
  end if;
  if (select count(*) <> count(distinct x ->> 'sourceId') from jsonb_array_elements(p_items) x) then
    raise exception 'a line appears twice among the items' using errcode = 'CMA04';
  end if;
  if exists (select 1 from jsonb_array_elements(p_items) x where not coalesce((x ->> 'subscriptionSourceId') = any (p_subscription_ids), false)) then
    raise exception 'every line belongs to one of the subscriptions read' using errcode = 'CMA04';
  end if;

  -- before: per subscription read, whether lines were held and the sum of its recurring lines' quantities
  select coalesce(jsonb_object_agg(b.sub, b.qty), '{}'::jsonb) into v_before
  from (select l.subscription_source_id as sub,
               coalesce(sum(l.quantity) filter (where l.canceled_at is null and l.recurring_cycle_limit is null), 0) as qty
        from cma.subscription_line l
        where l.tenant_id = v_tenant and l.connection_id = p_connection_id and l.source_deleted_at is null
          and l.subscription_source_id = any (p_subscription_ids)
        group by 1) b;

  for i in select x from jsonb_array_elements(p_items) x loop
    v_id := i ->> 'sourceId';
    v_sub := i ->> 'subscriptionSourceId';
    v_product := nullif(i ->> 'productSourceId', '');
    v_variant := nullif(i ->> 'variantSourceId', '');
    v_currency := i ->> 'currency';
    v_interval := i ->> 'billingInterval';
    if not coalesce(cma.subscription_id_ok(v_id), false)
       or (v_product is not null and not cma.subscription_id_ok(v_product))
       or (v_variant is not null and not cma.subscription_id_ok(v_variant))
       or (v_interval is not null and v_interval not in ('day', 'week', 'month', 'year'))
       or (v_currency is not null and v_currency !~ '^[A-Z]{3}$')
       or (i ? 'amountPerCycle' and jsonb_typeof(i -> 'amountPerCycle') not in ('number', 'null'))
       or (i ? 'raw' and jsonb_typeof(i -> 'raw') <> 'object') then
      raise exception 'line %: an id, product and variant ids, an interval of day, week, month or year, a currency code, a number for the amount and an object for raw', coalesce(v_id, '(none)')
        using errcode = 'CMA04';
    end if;
    v_qty := cma.subscription_json_int(i -> 'quantity', 'quantity');
    v_count := cma.subscription_json_int(i -> 'billingIntervalCount', 'billingIntervalCount');
    v_min := cma.subscription_json_int(i -> 'minCycles', 'minCycles');
    v_max := cma.subscription_json_int(i -> 'maxCycles', 'maxCycles');
    v_limit := cma.subscription_json_int(i -> 'recurringCycleLimit', 'recurringCycleLimit');
    v_amount := round((i ->> 'amountPerCycle')::numeric, 2);
    v_canceled := cma.json_time(i -> 'canceledAt', 'canceledAt');
    v_raw := coalesce(i -> 'raw', '{}'::jsonb);

    v_old := null;
    select * into v_old from cma.subscription_line l
    where l.tenant_id = v_tenant and l.connection_id = p_connection_id and l.source_id = v_id
    for update;
    if v_old.id is null then
      insert into cma.subscription_line (tenant_id, connection_id, source_system, source_id, subscription_source_id, product_source_id,
                                         variant_source_id, quantity, amount_per_cycle, currency, billing_interval, billing_interval_count,
                                         min_cycles, max_cycles, recurring_cycle_limit, canceled_at, raw)
      values (v_tenant, p_connection_id, v_target.adapter, v_id, v_sub, v_product, v_variant, v_qty, v_amount, v_currency, v_interval,
              v_count, v_min, v_max, v_limit, v_canceled, v_raw);
      v_ins := v_ins + 1;
    elsif (v_old.subscription_source_id, v_old.product_source_id, v_old.variant_source_id, v_old.quantity, v_old.amount_per_cycle,
           v_old.currency, v_old.billing_interval, v_old.billing_interval_count, v_old.min_cycles, v_old.max_cycles,
           v_old.recurring_cycle_limit, v_old.canceled_at, v_old.raw, v_old.source_deleted_at)
          is distinct from
          (v_sub, v_product, v_variant, v_qty, v_amount, v_currency, v_interval, v_count, v_min, v_max, v_limit, v_canceled, v_raw,
           null::timestamptz) then
      update cma.subscription_line l
         set subscription_source_id = v_sub, product_source_id = v_product, variant_source_id = v_variant, quantity = v_qty,
             amount_per_cycle = v_amount, currency = v_currency, billing_interval = v_interval, billing_interval_count = v_count,
             min_cycles = v_min, max_cycles = v_max, recurring_cycle_limit = v_limit, canceled_at = v_canceled, raw = v_raw,
             source_deleted_at = null, synced_at = now()
       where l.tenant_id = v_tenant and l.id = v_old.id;
      v_updn := v_updn + 1;
    else
      v_same := v_same + 1;
    end if;
  end loop;

  -- the lines of the subscriptions read that the read no longer holds
  update cma.subscription_line l set source_deleted_at = now(), synced_at = now()
  where l.tenant_id = v_tenant and l.connection_id = p_connection_id and l.source_deleted_at is null
    and l.subscription_source_id = any (p_subscription_ids)
    and l.source_id not in (select x ->> 'sourceId' from jsonb_array_elements(p_items) x);
  get diagnostics v_missing = row_count;

  -- after: a subscription whose lines were held before and whose recurring quantity differs now
  insert into cma.subscription_change (tenant_id, connection_id, subscription_source_id, field, old_value, new_value, run_id)
  select v_tenant, p_connection_id, b.key, 'recurring_quantity', b.value #>> '{}', coalesce(a.qty, 0)::text, p_run_id
  from jsonb_each(v_before) b
  left join (select l.subscription_source_id as sub,
                    sum(l.quantity) filter (where l.canceled_at is null and l.recurring_cycle_limit is null) as qty
             from cma.subscription_line l
             where l.tenant_id = v_tenant and l.connection_id = p_connection_id and l.source_deleted_at is null
               and l.subscription_source_id = any (p_subscription_ids)
             group by 1) a on a.sub = b.key
  where (b.value #>> '{}') is distinct from coalesce(a.qty, 0)::text;
  get diagnostics v_changes = row_count;

  return jsonb_build_object('inserted', v_ins, 'updated', v_updn, 'unchanged', v_same, 'missing_now', v_missing,
                            'changes_observed', v_changes);
exception when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
  raise exception 'invalid subscription line: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- The store's catalog as the subscription app holds it, the full set of one read: [{productSourceId, variantSourceId,
-- productTitle, variantTitle, sku, productStatus}], 1 to 5,000 variants, each variant once. A new variant is inserted; a
-- known one is updated when anything differs (and comes back when it was missing), else unchanged; a variant of the
-- connection the set does not hold gets source_deleted_at. A title or SKU is the store's text (cma.catalog_text_ok);
-- the adapter leaves out one with an @ or a control character. Answers { inserted, updated, unchanged, missing_now }.
-- CMA04 for an empty set, an item out of its form, a connection without its store or one the ingest does not read
create or replace function cma.ingest_upsert_subscription_products(p_connection_id uuid, p_items jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_target  record;
  i         jsonb;
  v_product text;
  v_variant text;
  v_ptitle  text;
  v_vtitle  text;
  v_sku     text;
  v_pstatus text;
  v_old     cma.subscription_product_variant;
  v_ins     integer := 0;
  v_updn    integer := 0;
  v_same    integer := 0;
  v_missing integer;
begin
  select * into v_target from cma.subscriptions_ingest_target(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 5000
     or exists (select 1 from jsonb_array_elements(p_items) x where jsonb_typeof(x) <> 'object') then
    raise exception 'items must be the catalog''s 1 to 5,000 variants (an empty read marks nothing missing)' using errcode = 'CMA04';
  end if;
  if (select count(*) <> count(distinct x ->> 'variantSourceId') from jsonb_array_elements(p_items) x) then
    raise exception 'a variant appears twice among the items' using errcode = 'CMA04';
  end if;
  for i in select x from jsonb_array_elements(p_items) x loop
    v_product := i ->> 'productSourceId';
    v_variant := i ->> 'variantSourceId';
    v_ptitle := nullif(i ->> 'productTitle', '');
    v_vtitle := nullif(i ->> 'variantTitle', '');
    v_sku := nullif(i ->> 'sku', '');
    v_pstatus := nullif(i ->> 'productStatus', '');
    if not coalesce(cma.subscription_id_ok(v_product), false) or not coalesce(cma.subscription_id_ok(v_variant), false)
       or (v_ptitle is not null and not cma.catalog_text_ok(v_ptitle))
       or (v_vtitle is not null and not cma.catalog_text_ok(v_vtitle))
       or (v_sku is not null and not cma.catalog_text_ok(v_sku))
       or (v_pstatus is not null and v_pstatus !~ '^[a-z][a-z_]{0,19}$') then
      raise exception 'variant %: product and variant ids, titles and a SKU of 1 to 100 characters without an @ or a control character, a status in lower case', coalesce(v_variant, '(none)')
        using errcode = 'CMA04';
    end if;
    v_old := null;
    select * into v_old from cma.subscription_product_variant v
    where v.tenant_id = v_tenant and v.connection_id = p_connection_id and v.variant_source_id = v_variant
    for update;
    if v_old.id is null then
      insert into cma.subscription_product_variant (tenant_id, connection_id, source_system, product_source_id, variant_source_id,
                                                    product_title, variant_title, sku, product_status)
      values (v_tenant, p_connection_id, v_target.adapter, v_product, v_variant, v_ptitle, v_vtitle, v_sku, v_pstatus);
      v_ins := v_ins + 1;
    elsif (v_old.product_source_id, v_old.product_title, v_old.variant_title, v_old.sku, v_old.product_status, v_old.source_deleted_at)
          is distinct from (v_product, v_ptitle, v_vtitle, v_sku, v_pstatus, null::timestamptz) then
      update cma.subscription_product_variant v
         set product_source_id = v_product, product_title = v_ptitle, variant_title = v_vtitle, sku = v_sku, product_status = v_pstatus,
             source_deleted_at = null, synced_at = now()
       where v.tenant_id = v_tenant and v.id = v_old.id;
      v_updn := v_updn + 1;
    else
      v_same := v_same + 1;
    end if;
  end loop;
  update cma.subscription_product_variant v set source_deleted_at = now(), synced_at = now()
  where v.tenant_id = v_tenant and v.connection_id = p_connection_id and v.source_deleted_at is null
    and v.variant_source_id not in (select x ->> 'variantSourceId' from jsonb_array_elements(p_items) x);
  get diagnostics v_missing = row_count;
  return jsonb_build_object('inserted', v_ins, 'updated', v_updn, 'unchanged', v_same, 'missing_now', v_missing);
exception when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
  raise exception 'invalid catalog variant: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Billing events of a connection: [{sourceId, kind, occurredAt, subscriptionSourceId, customerSourceId, orderSourceId,
-- renewalSourceId, ownerSourceId, amount, currency, returnCode, instrumentType, attempt, errorCode, partial, raw}], at most
-- 500, each id once. Append-only: a new event is inserted, one already held is left as it is (unchanged). Answers per
-- event its outcome (inserted, unchanged). CMA04 for an item out of its form, a connection without its store or one the
-- ingest does not read
create or replace function cma.ingest_upsert_billing_events(p_connection_id uuid, p_items jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_target record;
  i        jsonb;
  v_id     text;
  v_kind   text;
  v_n      integer;
begin
  select * into v_target from cma.subscriptions_ingest_target(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500
     or exists (select 1 from jsonb_array_elements(p_items) x where jsonb_typeof(x) <> 'object') then
    raise exception 'items must be an array of at most 500 billing events' using errcode = 'CMA04';
  end if;
  if (select count(*) <> count(distinct x ->> 'sourceId') from jsonb_array_elements(p_items) x) then
    raise exception 'a billing event appears twice among the items' using errcode = 'CMA04';
  end if;
  for i in select x from jsonb_array_elements(p_items) x loop
    v_id := i ->> 'sourceId';
    v_kind := i ->> 'kind';
    if not coalesce(cma.subscription_id_ok(v_id), false)
       or coalesce(v_kind, '') not in ('chargeback', 'refund_created', 'refund_completed', 'refund_failed', 'invoice_placed', 'invoice_paid',
                                       'invoice_overdue', 'invoice_payment_failed', 'order_placement_failed', 'order_draft_created')
       or (i ? 'amount' and jsonb_typeof(i -> 'amount') not in ('number', 'null'))
       or (i ? 'partial' and jsonb_typeof(i -> 'partial') not in ('boolean', 'null'))
       or (i ? 'raw' and jsonb_typeof(i -> 'raw') <> 'object') then
      raise exception 'billing event %: an id, a kind of the ten, a number for the amount, true or false for partial and an object for raw', coalesce(v_id, '(none)')
        using errcode = 'CMA04';
    end if;
    insert into cma.billing_event (tenant_id, connection_id, source_system, source_id, kind, occurred_at, subscription_source_id,
                                   customer_source_id, order_source_id, renewal_source_id, owner_source_id, amount, currency, return_code,
                                   instrument_type, attempt, error_code, partial, raw)
    values (v_tenant, p_connection_id, v_target.adapter, v_id, v_kind, cma.json_time(i -> 'occurredAt', 'occurredAt'),
            nullif(i ->> 'subscriptionSourceId', ''), nullif(i ->> 'customerSourceId', ''), nullif(i ->> 'orderSourceId', ''),
            nullif(i ->> 'renewalSourceId', ''), nullif(i ->> 'ownerSourceId', ''), round((i ->> 'amount')::numeric, 2),
            nullif(i ->> 'currency', ''), nullif(i ->> 'returnCode', ''), nullif(i ->> 'instrumentType', ''),
            cma.subscription_json_int(i -> 'attempt', 'attempt'), nullif(i ->> 'errorCode', ''), (i ->> 'partial')::boolean,
            coalesce(i -> 'raw', '{}'::jsonb))
    on conflict (tenant_id, connection_id, source_id) do nothing;
    get diagnostics v_n = row_count;
    source_id := v_id;
    outcome := case when v_n = 1 then 'inserted' else 'unchanged' end;
    return next;
  end loop;
exception when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
  raise exception 'invalid billing event: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Events of a connection's subscriptions, as 0008zl (118) with the new types and columns: [{sourceId,
-- subscriptionSourceId, eventType, occurredAt, actorType, actorSourceId, cycleIndex, attempt, errorCode, reasonCode,
-- statusFrom, statusTo, billingFromAt, billingToAt, causeCode, intervalFrom, intervalCountFrom, intervalTo,
-- intervalCountTo, linesAdded, linesRemoved, linesUpdated, relatedSubscriptionSourceId, operationSourceId, orderSourceId,
-- raw}], at most
-- 500, each id once. Append-only: a new event is inserted, one already held is left as it is (unchanged). The
-- subscription need not be held yet. Answers per event its outcome (inserted, unchanged). CMA04 for an item out of its
-- form, a connection without its store or one the ingest does not read
-- based on: 118_subscriptions.sql
create or replace function cma.ingest_upsert_subscription_events(p_connection_id uuid, p_items jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_target record;
  i        jsonb;
  v_id     text;
  v_sub    text;
  v_type   text;
  v_actor  text;
  v_actid  text;
  v_n      integer;
begin
  select * into v_target from cma.subscriptions_ingest_target(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500
     or exists (select 1 from jsonb_array_elements(p_items) x where jsonb_typeof(x) <> 'object') then
    raise exception 'items must be an array of at most 500 events' using errcode = 'CMA04';
  end if;
  if (select count(*) <> count(distinct x ->> 'sourceId') from jsonb_array_elements(p_items) x) then
    raise exception 'an event appears twice among the items' using errcode = 'CMA04';
  end if;
  for i in select x from jsonb_array_elements(p_items) x loop
    v_id := i ->> 'sourceId';
    v_sub := i ->> 'subscriptionSourceId';
    v_type := i ->> 'eventType';
    v_actor := i ->> 'actorType';
    v_actid := nullif(i ->> 'actorSourceId', '');
    if not coalesce(cma.subscription_id_ok(v_id), false) or not coalesce(cma.subscription_id_ok(v_sub), false) then
      raise exception 'an event needs its id and its subscription''s id' using errcode = 'CMA04';
    end if;
    if coalesce(v_type, '') not in ('renewed', 'renew_failed', 'canceled', 'paused', 'resumed', 'reactivated', 'status_changed',
                                    'purchased', 'created', 'migrated', 'skipped', 'billing_date_moved', 'interval_changed',
                                    'lines_changed', 'payment_method_changed', 'discount_changed', 'merged_to', 'merged_from',
                                    'split_to', 'split_from', 'renewal_notice', 'update_failed')
       or (v_actor is not null and v_actor not in ('staff', 'customer', 'system', 'bulk', 'api'))
       or (v_actid is not null and v_actor is distinct from 'staff')
       or (i ? 'raw' and jsonb_typeof(i -> 'raw') <> 'object') then
      raise exception 'event %: a type of the twenty-two, an actor type of staff, customer, system, bulk or api, an actor id for staff only and an object for raw', v_id
        using errcode = 'CMA04';
    end if;
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type,
                                        occurred_at, actor_type, actor_source_id, cycle_index, attempt, error_code, reason_code,
                                        status_from, status_to, billing_from_at, billing_to_at, cause_code, interval_from,
                                        interval_count_from, interval_to, interval_count_to, lines_added, lines_removed, lines_updated,
                                        related_subscription_source_id, operation_source_id, order_source_id, raw)
    values (v_tenant, p_connection_id, v_target.adapter, v_id, v_sub, v_type, cma.json_time(i -> 'occurredAt', 'occurredAt'), v_actor,
            v_actid, cma.subscription_json_int(i -> 'cycleIndex', 'cycleIndex'), cma.subscription_json_int(i -> 'attempt', 'attempt'),
            nullif(i ->> 'errorCode', ''), nullif(i ->> 'reasonCode', ''), nullif(i ->> 'statusFrom', ''), nullif(i ->> 'statusTo', ''),
            cma.json_time(i -> 'billingFromAt', 'billingFromAt'), cma.json_time(i -> 'billingToAt', 'billingToAt'),
            nullif(i ->> 'causeCode', ''), nullif(i ->> 'intervalFrom', ''),
            cma.subscription_json_int(i -> 'intervalCountFrom', 'intervalCountFrom'), nullif(i ->> 'intervalTo', ''),
            cma.subscription_json_int(i -> 'intervalCountTo', 'intervalCountTo'), cma.subscription_json_int(i -> 'linesAdded', 'linesAdded'),
            cma.subscription_json_int(i -> 'linesRemoved', 'linesRemoved'), cma.subscription_json_int(i -> 'linesUpdated', 'linesUpdated'),
            nullif(i ->> 'relatedSubscriptionSourceId', ''), nullif(i ->> 'operationSourceId', ''), nullif(i ->> 'orderSourceId', ''),
            coalesce(i -> 'raw', '{}'::jsonb))
    on conflict (tenant_id, connection_id, source_id) do nothing;
    get diagnostics v_n = row_count;
    source_id := v_id;
    outcome := case when v_n = 1 then 'inserted' else 'unchanged' end;
    return next;
  end loop;
exception when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
  raise exception 'invalid subscription event: %', sqlerrm using errcode = 'CMA04';
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
    'cma.ingest_sync_run_finish(uuid,text,jsonb,text)',
    'cma.ingest_upsert_subscriptions(uuid,jsonb,uuid)',
    'cma.ingest_upsert_subscriptions(uuid,jsonb)',
    'cma.ingest_upsert_subscription_lines(uuid,text[],jsonb,uuid)',
    'cma.ingest_upsert_subscription_products(uuid,jsonb)',
    'cma.ingest_upsert_billing_events(uuid,jsonb)',
    'cma.ingest_upsert_subscription_events(uuid,jsonb)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Reporting views (cma.subscription_event's last, with its columns)
-- ---------------------------------------------------------------------------------------------
-- As 0008zl (118), with the new columns at its end: ids, the status, cycle, billing, amount, the instrument's type, times,
-- the app's number, the cycle limits, the counts of discounts and lines, the device units
create or replace view cma_read.subscription as
  select id, tenant_id, connection_id, source_system, source_id, customer_source_id, status, current_cycle, next_billing_at,
         billing_interval, billing_interval_count, amount_per_cycle, currency, payment_instrument_type, source_created_at, paused_at,
         canceled_at, source_updated_at, source_deleted_at, first_seen_at, synced_at, source_number, min_cycles, max_cycles,
         discount_count, line_count, device_units
  from cma.subscription
  where cma_read.reader_sees(tenant_id);

-- Every column but raw
create or replace view cma_read.subscription_line as
  select id, tenant_id, connection_id, source_system, source_id, subscription_source_id, product_source_id, variant_source_id, quantity,
         amount_per_cycle, currency, billing_interval, billing_interval_count, min_cycles, max_cycles, recurring_cycle_limit, canceled_at,
         first_seen_at, synced_at, source_deleted_at
  from cma.subscription_line
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.subscription_product_variant as
  select id, tenant_id, connection_id, source_system, product_source_id, variant_source_id, product_title, variant_title, sku,
         product_status, first_seen_at, synced_at, source_deleted_at
  from cma.subscription_product_variant
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.billing_event as
  select id, tenant_id, connection_id, source_system, source_id, kind, occurred_at, subscription_source_id, customer_source_id,
         order_source_id, renewal_source_id, owner_source_id, amount, currency, return_code, instrument_type, attempt, error_code, partial,
         synced_at
  from cma.billing_event
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.subscription_change as
  select id, tenant_id, connection_id, subscription_source_id, field, old_value, new_value, observed_at, run_id
  from cma.subscription_change
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 9. cma.subscription_event (a busy table): the new columns, types and checks, last
-- ---------------------------------------------------------------------------------------------
-- Its ACCESS EXCLUSIVE lock is held until the commit: nothing but its reader view and the record of the addition follows
alter table cma.subscription_event
  add column if not exists billing_from_at                timestamptz,
  add column if not exists billing_to_at                  timestamptz,
  add column if not exists cause_code                     text,
  add column if not exists interval_from                  text,
  add column if not exists interval_count_from            integer,
  add column if not exists interval_to                    text,
  add column if not exists interval_count_to              integer,
  add column if not exists lines_added                    integer,
  add column if not exists lines_removed                  integer,
  add column if not exists lines_updated                  integer,
  add column if not exists related_subscription_source_id text,
  add column if not exists operation_source_id            text,
  add column if not exists order_source_id                text;
alter table cma.subscription_event
  drop constraint if exists subscription_event_event_type_check,
  drop constraint if exists subscription_event_raw_check,
  drop constraint if exists subscription_event_cause_code_check,
  drop constraint if exists subscription_event_interval_check,
  drop constraint if exists subscription_event_lines_check,
  drop constraint if exists subscription_event_related_check,
  drop constraint if exists subscription_event_operation_check,
  drop constraint if exists subscription_event_order_check;
alter table cma.subscription_event
  add constraint subscription_event_event_type_check
    check (event_type in ('renewed', 'renew_failed', 'canceled', 'paused', 'resumed', 'reactivated', 'status_changed', 'purchased', 'created',
                          'migrated', 'skipped', 'billing_date_moved', 'interval_changed', 'lines_changed', 'payment_method_changed',
                          'discount_changed', 'merged_to', 'merged_from', 'split_to', 'split_from', 'renewal_notice', 'update_failed')),
  add constraint subscription_event_raw_check
    check (cma.subscription_raw_ok(raw, array['id', 'type', 'occurredAt', 'subscriptionId', 'customerId', 'actorType', 'actorId',
                                              'cycleIndex', 'attempt', 'errorCode', 'reason', 'previousStatus', 'status', 'orderId',
                                              'billingFrom', 'billingTo', 'cause', 'intervalFrom', 'intervalCountFrom', 'intervalTo',
                                              'intervalCountTo', 'linesAdded', 'linesRemoved', 'linesUpdated', 'relatedSubscriptionId',
                                              'operationId'])),
  add constraint subscription_event_cause_code_check
    check (cause_code is null
           or (event_type = 'billing_date_moved' and cause_code in ('requested', 'skipped', 'resumed', 'reactivated', 'reconciled'))
           or (event_type = 'discount_changed' and cause_code in ('added', 'removed', 'updated', 'code_applied', 'free_shipping'))),
  add constraint subscription_event_interval_check
    check ((interval_from is null or interval_from in ('day', 'week', 'month', 'year'))
           and (interval_to is null or interval_to in ('day', 'week', 'month', 'year'))
           and (interval_count_from is null or interval_count_from between 1 and 1000)
           and (interval_count_to is null or interval_count_to between 1 and 1000)
           and ((interval_from is null and interval_to is null and interval_count_from is null and interval_count_to is null)
                or event_type = 'interval_changed')),
  add constraint subscription_event_lines_check
    check ((lines_added is null or lines_added between 0 and 1000) and (lines_removed is null or lines_removed between 0 and 1000)
           and (lines_updated is null or lines_updated between 0 and 1000)
           and ((lines_added is null and lines_removed is null and lines_updated is null) or event_type = 'lines_changed')),
  add constraint subscription_event_related_check
    check (related_subscription_source_id is null
           or (cma.subscription_id_ok(related_subscription_source_id) and event_type in ('merged_to', 'merged_from', 'split_to', 'split_from'))),
  add constraint subscription_event_operation_check
    check (operation_source_id is null or cma.subscription_id_ok(operation_source_id)),
  add constraint subscription_event_order_check
    check (order_source_id is null or (order_source_id ~ '^\d{1,30}$' and event_type = 'renewed'));
comment on table cma.subscription_event is 'A subscription app''s events of its subscriptions per connection, in the CMA''s words (0008zl''s seven: renewed, renew_failed, canceled, paused, resumed, reactivated, status_changed; since 0009w purchased, created, migrated, skipped, billing_date_moved, interval_changed, lines_changed, payment_method_changed, discount_changed, merged_to, merged_from, split_to, split_from, renewal_notice, update_failed). Codes, counts and times only; a staff actor''s id, never a name; no free-text message or reason. Append-only. Owned by the subscription app (0008zl, 0009w)';
comment on column cma.subscription_event.cycle_index is 'The billing cycle the event is about, as the source counts them (a renewal''s or a failed renewal''s; a migration''s current cycle at the move into the app)';
comment on column cma.subscription_event.billing_from_at is 'A billing-date move''s previous date, a skip''s skipped date (0009w)';
comment on column cma.subscription_event.billing_to_at is 'A billing-date move''s new date, a skip''s next billing date, a migration''s next billing date (0009w)';
comment on column cma.subscription_event.cause_code is 'Why a billing date moved (requested, skipped, resumed, reactivated, reconciled) or how a discount changed (added, removed, updated, code_applied, free_shipping); a code, never a discount''s code or value (0009w)';
comment on column cma.subscription_event.lines_added is 'How many lines a line change added (lines_removed, lines_updated alike); counts, never the lines'' content (0009w)';
comment on column cma.subscription_event.related_subscription_source_id is 'The other subscription of a merge or split (0009w)';
comment on column cma.subscription_event.order_source_id is 'The store''s order id (digits) of a renewal: the order the renewal placed, which a chargeback or refund names (cma.billing_event.order_source_id) (0009w)';
comment on column cma.subscription_event.operation_source_id is 'The source''s id of the operation that wrote the event: the events of one change share it (a line change written both as lines-changed and as line-added) (0009w)';

-- As 0008zl (118), with the new columns at its end: every column but raw
create or replace view cma_read.subscription_event as
  select id, tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, actor_type,
         actor_source_id, cycle_index, attempt, error_code, reason_code, status_from, status_to, synced_at, billing_from_at, billing_to_at,
         cause_code, interval_from, interval_count_from, interval_to, interval_count_to, lines_added, lines_removed, lines_updated,
         related_subscription_source_id, operation_source_id, order_source_id
  from cma.subscription_event
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 10. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009w', 'The subscription app read whole (brief B39 Part A): the setting subscriptions.history_start_date (the events backfill''s start without --from, before intake.start_date allowed; empty all history); cma.subscription gains source_number, min_cycles, max_cycles, discount_count, line_count, device_units and seven instrument types; cma.subscription_line (lines as a set per subscription, canceled ones included, missing marked), cma.subscription_product_variant (the catalog per variant, titles and SKU as merchant text), cma.billing_event (chargebacks, refunds, invoice renewals, order placement; append-only) and cma.subscription_change (observed changes of status, amount, currency, interval, line count and recurring quantity; a stored null is a start; append-only); cma.subscription_event takes fifteen more types and the columns of billing-date moves, interval and line changes, merges, the operation and a renewal''s order; cma.ingest_upsert_subscriptions with a run (the two-argument function a wrapper of it), cma.ingest_upsert_subscription_lines, cma.ingest_upsert_subscription_products, cma.ingest_upsert_billing_events; the run counts lines_new, lines_missing, variants_new, billing_events_new, changes_observed, instrument_unknown, duplicate_skipped, return_code_dropped, catalog_text_dropped; cma_read.subscription_line, subscription_product_variant, billing_event, subscription_change, and the new columns of cma_read.subscription and subscription_event')
on conflict (version) do nothing;

commit;
reset role;
