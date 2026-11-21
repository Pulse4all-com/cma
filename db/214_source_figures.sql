-- =============================================================================================
-- 214_source_figures.sql: addition 0009zg, the subscription app's own figures beside the CMA's (brief B39 continued,
-- Part B39b): a daily read of the app's own counts per store, stored with the CMA's value of the same scope, compared
-- against a tenant tolerance, a data-quality check for a gap above it, and the Flash watch's stale check for the job
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. The figure keys are the CMA's words; the source's own metric
-- key travels in source_metric only, for the trace (the adapter names it: ingest/src/adapters/juo/figures.mjs). Runs
-- unchanged in every database, after 212_subscription_facts_speed.sql (0009zf). Rerunnable, forward-only, in one
-- transaction with a lock timeout. Brief B39d (addition 0009zh, 216/217) runs beside this one: 216 starts from this
-- script's definitions of the functions both re-create (the data-quality functions and cma.check_tenant_setting).
--
-- Why (Martin, 20 and 21 November 2026; brief B39 continued, Part B39b; Decision log, 21 Nov 2026): the app owns these
-- measures. The audit of 0009zb compared its counts with the CMA's by hand in the chat (records/0009zb-prod-2026-11-20:
-- a gap in one store that named the paging defect 0009zc fixed). A daily, stored comparison makes
-- a missed read or a wrong rule show within a day; a gap is a defect or a documented difference, never a silent
-- tolerance (Decision log, 21 Nov 2026).
--
-- What it adds
--   settings     source_figures.tolerance_pct (1; a whole number of percent from 0 to 100), source_figures.tolerance_min
--                (2; a whole number from 0 to 1,000,000, in the figure's unit) and source_figures.local_time (05:00; the
--                time in the tenant's zone from which a day's read is due, 00:00 to 23:59); checked by
--                cma.check_tenant_setting() (re-created from 210's definition)
--   table        cma.source_figure: one row per connection, figure, business date and dims (allow-listed keys only:
--                status, cohort_start, period): the source's value, unit (count, or amount in the currency's own unit, as
--                the CMA stores amounts) and currency, the CMA's own value of the same scope taken when the row was
--                written (cma_value, cma_at), the latest fetch (fetched_at, run_id) and in raw the first fetch and the
--                number of fetches. A later fetch replaces the value. No audit trigger: a mirror of a source's figures,
--                every write a sync_run (job source_figures)
--   catalog      cma.source_figure_keys(): the seven figures, their kind (stock, flow, cohort), unit and dims, and whether
--                the CMA's value is compared here (renewal_survival is compared on Customers → Subscriptions, B39d)
--   writes       cma.ingest_upsert_source_figures(connection, run, items): ingest.write, a subscriptions connection of the
--                current tenant (CMA02 otherwise); the CMA's value computed in the
--                same statement, per figure (below); answers { inserted, updated, unchanged }
--   reads        cma.source_figure_rows_of(tenant, from, to) (the owner's core, no permission check: the data-quality
--                refresh reads it), cma.source_figure_compare_of(tenant, date) (reports.view or tenant.configure, the
--                current tenant only) and cma.source_figures_due_of(connection) (ingest.write: whether the day's read is
--                due, and the business dates it reads)
--   check        data quality source_figure_gap (sort 400; while subscriptions are set up; fixed in subscriptions): per
--                store, figure and dims, the latest date read (a flow's latest complete day), when the gap exceeds both
--                tolerances. cma.data_quality_flash_checks, cma.data_quality_of, cma.data_quality and
--                cma.data_quality_fix_in re-created from 210's definitions, with the check added and nothing else changed
--   market       cma.flash_findings_compute_of re-created from 178's definition: a source_figure finding takes its store's
--                market; nothing else changes
--   watch        cma.flash_watch_of re-created from 158's definition: the figures job is watched on its own (source
--                source_figures, its cadence its runs' median gap as every job's, stale after one and a half cadences
--                instead of three, so a day without figures shows at the next morning's snapshot), so the five-minute poll
--                of the same connection does not hide it; nothing else changes
--   runs         sync_run.job gains source_figures (its counts are sync_run's own: fetched, inserted, updated,
--                unchanged, skipped)
--   readers      cma_read.source_figure (every column but raw), cma_read.dq_source_figure_gap
--
-- The CMA's value per figure (cma_value), taken when the row is written:
--   subscriptions_in_status    present subscriptions of the connection (source_deleted_at null) in dims.status, now.
--                              The app's standing count is written forward once a day and cannot be recomputed for a past
--                              date; neither can the CMA's, so both are the state at the read and differ by the movement
--                              between the app's snapshot and the read
--   recurring_amount_active    per currency, present subscriptions in status active: amount per cycle times
--                              cma.active_month_factor_of (Customers → Active's month factor). Stored with the currency when
--                              the connection's active subscriptions hold one currency; with several, no currency and no
--                              CMA value (the app's figure is one number in the store's currency). The app leaves one-time
--                              and virtual lines out; the CMA's amount per cycle sums every line not canceled: a known cause
--   renewals, purchases        events renewed, purchased of the connection that occurred on the business date (the tenant's
--                              zone)
--   exits                      events of the connection into dims.status (status_to: canceled, failed or expired) on the
--                              business date, any event type: Exit (subscription app), not the CMA's Churn (subscription)
--   pauses                     events of the connection into paused on the business date, any event type
--   renewal_survival           none here (B39d compares it with the CMA's renewal survival)
--
-- Order to run: dev, 214 then 215_verify_source_figures.sql (normal and provoked), then the verifies that read what this
-- re-creates, still PASS: for cma.check_tenant_setting 73, 101, 113, 121, 123, 137, 179 (and 211, through the settings'
-- trigger); for cma.data_quality_flash_checks 123, 137; for cma.data_quality_of 41, 69, 73, 75, 101, 105, 113, 117, 123,
-- 133, 137, 161, 179, 211; for cma.data_quality 41, 69, 73, 75, 105, 113, 123, 133, 137; for cma.data_quality_fix_in 123,
-- 133, 137, 179, 211; for cma.flash_findings_compute_of 179; for cma.flash_watch_of 123, 137, 139, 159 (149 and 181 read
-- data quality's overview through Flash: optional). 123 and 137 are edited by this change (A8 and B5, A7: they expect
-- source_figure_gap, conditional on the 0009zg row), as are web/verify/flash.mjs and 131_time_all.sql. Then the data map's
-- schema.json refreshed from dev on this branch, the merge, prod (214, the same verifies; 215 refuses prod's data, as
-- the dev-seed verifies do). No index on a busy table: cma.source_figure is new and small (about 900 rows a store and
-- month: some 15 a day and 480 survival cells); source_figure_date_idx (tenant_id, business_date) serves the reads of a date range.
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
  if not exists (select 1 from cma.schema_migration where version = '0009zf') then
    raise exception 'addition 0009zf (212_subscription_facts_speed.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings (B.1)
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('source_figures.tolerance_pct', 'integer', null, '1',
     'A source figure''s gap counts on Data quality (source_figure_gap) when it exceeds this share of the source''s value in percent (0 to 100) and source_figures.tolerance_min both (addition 0009zg). Never widened to close a gap without a documented cause'),
  ('source_figures.tolerance_min', 'integer', null, '2',
     'A source figure''s gap counts on Data quality (source_figure_gap) when it exceeds this many of the figure''s unit (0 to 1,000,000: subscriptions or events, or the currency''s own unit for an amount) and source_figures.tolerance_pct both (addition 0009zg)'),
  ('source_figures.local_time', 'time', null, '05:00',
     'The time in the tenant''s zone from which a day''s read of the subscription app''s own figures is due (00:00 to 23:59): the hourly job reads each subscriptions connection once a day after it, yesterday and today (addition 0009zg)')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0009ze's (210), with the three settings of the source figures
-- based on: 210_subscription_facts.sql
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
-- 2. The figures' catalog and the table (B.1, B.2)
-- ---------------------------------------------------------------------------------------------
-- The figures a source may store, in the CMA's words. kind: stock (a count or amount at the read), flow (events on a
-- business date) or cohort (a cell of a start cohort and a renewal number, stored under the first day of the month it
-- was read in). dims: the keys the figure's rows carry. compared: whether cma.source_figure_rows_of compares it with the
-- CMA's value (renewal_survival is compared on Customers → Subscriptions, B39d)
create or replace function cma.source_figure_keys()
returns table (figure_key text, kind text, unit text, dims text[], compared boolean, sort_order integer)
language sql immutable
as $$
  values
    ('subscriptions_in_status', 'stock',  'count',  array['status'],                 true,  10),
    ('recurring_amount_active', 'stock',  'amount', array[]::text[],                  true,  20),
    ('renewals',                'flow',   'count',  array[]::text[],                  true,  30),
    ('exits',                   'flow',   'count',  array['status'],                 true,  40),
    ('purchases',               'flow',   'count',  array[]::text[],                  true,  50),
    ('pauses',                  'flow',   'count',  array[]::text[],                  true,  60),
    ('renewal_survival',        'cohort', 'count',  array['cohort_start', 'period'], false, 70)
$$;

-- A figure's dims: exactly its keys (cma.source_figure_keys), each value in its form: status a subscription status of the
-- CMA's seven, cohort_start the first day of a month (YYYY-MM-01), period a whole number from 1 to 36. Never anything else,
-- so no id or text of a customer can be stored in them
create or replace function cma.source_figure_dims_ok(p_figure_key text, p_dims jsonb)
returns boolean
language sql immutable
as $$
  select p_dims is not null and jsonb_typeof(p_dims) = 'object'
     and coalesce((select array(select x from unnest(k.dims) x order by x collate "C") from cma.source_figure_keys() k where k.figure_key = p_figure_key), array['?'])
         = array(select e from jsonb_object_keys(p_dims) e order by e collate "C")
     and (not (p_dims ? 'status') or (jsonb_typeof(p_dims -> 'status') = 'string'
          and (p_dims ->> 'status') in ('active', 'paused', 'canceled', 'expired', 'failed', 'merged', 'never-subscribed')))
     and (not (p_dims ? 'cohort_start') or (jsonb_typeof(p_dims -> 'cohort_start') = 'string'
          and (p_dims ->> 'cohort_start') ~ '^\d{4}-(0[1-9]|1[0-2])-01$'))
     and (not (p_dims ? 'period') or (jsonb_typeof(p_dims -> 'period') = 'number'
          and (p_dims ->> 'period') ~ '^\d{1,2}$' and (p_dims ->> 'period')::integer between 1 and 36))
$$;

create table if not exists cma.source_figure (
  id                uuid primary key default uuidv7(),
  tenant_id         uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id     uuid not null,
  figure_key        text not null check (figure_key in ('subscriptions_in_status', 'recurring_amount_active', 'renewals',
                                                        'exits', 'purchases', 'pauses', 'renewal_survival')),
  source_metric     text not null check (source_metric ~ '^[a-z][a-z0-9:._-]{0,79}$'),
  business_date     date not null,
  dims              jsonb not null default '{}'::jsonb check (cma.source_figure_dims_ok(figure_key, dims)),
  value             numeric(18,2) not null check (value >= 0),
  unit              text not null check (unit in ('count', 'amount')),
  currency          text check (currency ~ '^[A-Z]{3}$'),
  cma_value         numeric(18,2) check (cma_value >= 0),
  cma_at            timestamptz,
  fetched_at        timestamptz not null default now(),
  run_id            uuid,
  raw               jsonb not null default '{}'::jsonb
                    check (jsonb_typeof(raw) = 'object' and (raw - 'first_fetched_at' - 'fetches') = '{}'::jsonb),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, figure_key, business_date, dims),
  check (unit = 'amount' or currency is null),
  check ((cma_value is null) or cma_at is not null),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.source_figure is 'A source''s own figures per connection, figure, business date and dims (addition 0009zg): the subscription app''s counts and amount as it computes them, beside the CMA''s value of the same scope taken when the row was written. Codes, dates and figures only, never an id of a customer or a subscription. Written by the job source_figures (cma.ingest_upsert_source_figures); a later read replaces the value';
comment on column cma.source_figure.source_metric is 'The source''s own metric key, for the trace only (the adapter names it); the CMA reads figure_key';
comment on column cma.source_figure.business_date is 'The day the figure is of, in the tenant''s zone: a stock figure''s day of the read, a flow''s day of the events, a cohort cell''s first day of the month it was read in';
comment on column cma.source_figure.value is 'The source''s value: a count, or an amount in the currency''s own unit (as the CMA stores amounts)';
comment on column cma.source_figure.cma_value is 'The CMA''s own value of the same figure, date and dims, taken at cma_at (when the row was last written); null where the figure is not compared here or the scope has no single currency';
comment on column cma.source_figure.raw is 'first_fetched_at (the first read of this row) and fetches (how many reads wrote it); nothing else';
-- the reads of a date range (the comparison of a day, the check's last seven days); the table is new, so the index is
-- built here, not concurrently
create index if not exists source_figure_date_idx on cma.source_figure (tenant_id, business_date);
select cma.setup_tenant_table('cma.source_figure');
drop trigger if exists audit on cma.source_figure;

-- ---------------------------------------------------------------------------------------------
-- 3. The write: the source's figures, with the CMA's value of the same scope
-- ---------------------------------------------------------------------------------------------
-- p_items: [{ figureKey, sourceMetric, businessDate (YYYY-MM-DD), dims, value, unit }]; at most 2,000 a call. The
-- connection must be an active connection of the current tenant (cma.active_connection_adapter). Every item is checked
-- (CMA04 names the first fault, nothing is written); the CMA's value is computed per item in one statement; the rows
-- are written in key order (two runs on one connection lock them in the same order). Answers { inserted, updated,
-- unchanged } (unchanged: the source's and the CMA's values as stored; its fetch is recorded all the same)
create or replace function cma.ingest_upsert_source_figures(p_connection_id uuid, p_run_id uuid, p_items jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_zone   text;
  v_bad    text;
  v_out    jsonb;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if not exists (select 1 from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id and c.kind = 'subscriptions') then
    raise exception 'connection % is not a subscriptions connection', p_connection_id using errcode = 'CMA02';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 2000 then
    raise exception 'source figures are an array of at most 2,000 items' using errcode = 'CMA04';
  end if;
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;

  -- every item checked before anything is written: the first fault named
  select f.fault into v_bad
  from jsonb_array_elements(p_items) with ordinality i(x, n)
  left join cma.source_figure_keys() k on k.figure_key = i.x ->> 'figureKey'
  cross join lateral (select case
           when jsonb_typeof(i.x) <> 'object' then 'an item is no object'
           when exists (select 1 from jsonb_object_keys(i.x) y
                        where y not in ('figureKey', 'sourceMetric', 'businessDate', 'dims', 'value', 'unit')) then 'an item holds a key outside the list'
           when k.figure_key is null then 'figureKey is no figure of cma.source_figure_keys()'
           when coalesce(i.x ->> 'sourceMetric', '') !~ '^[a-z][a-z0-9:._-]{0,79}$' then 'sourceMetric is out of its form'
           when coalesce(i.x ->> 'businessDate', '') !~ '^\d{4}-\d{2}-\d{2}$' then 'businessDate is no date as YYYY-MM-DD'
           when jsonb_typeof(i.x -> 'value') is distinct from 'number' then 'value is no number'
           when (i.x ->> 'value')::numeric < 0 or round((i.x ->> 'value')::numeric, 2) >= 1e16 then 'value is out of its range (0 to 10^16)'
           when (i.x ->> 'unit') is distinct from k.unit then 'unit is not the figure''s'
           when not cma.source_figure_dims_ok(k.figure_key, coalesce(i.x -> 'dims', '{}'::jsonb)) then 'dims are not the figure''s'
         end as fault) f
  where f.fault is not null
  order by i.n
  limit 1;
  if v_bad is not null then
    raise exception 'invalid source figure: %', v_bad using errcode = 'CMA04';
  end if;
  begin
    perform (i ->> 'businessDate')::date from jsonb_array_elements(p_items) i;
  exception when others then
    raise exception 'invalid source figure: businessDate is no date as YYYY-MM-DD' using errcode = 'CMA04';
  end;

  with it as (
    -- one item per key: the last one given wins
    select distinct on (i.x ->> 'figureKey', (i.x ->> 'businessDate')::date, coalesce(i.x -> 'dims', '{}'::jsonb))
           i.x ->> 'figureKey' as figure_key, i.x ->> 'sourceMetric' as source_metric, (i.x ->> 'businessDate')::date as business_date,
           coalesce(i.x -> 'dims', '{}'::jsonb) as dims, round((i.x ->> 'value')::numeric, 2) as value, i.x ->> 'unit' as unit
    from jsonb_array_elements(p_items) with ordinality i(x, n)
    order by i.x ->> 'figureKey', (i.x ->> 'businessDate')::date, coalesce(i.x -> 'dims', '{}'::jsonb), i.n desc
  ), cur as (
    -- the connection's active subscriptions' monthly amount and its currencies, once (recurring_amount_active)
    select count(distinct s.currency) as currencies, min(s.currency) as currency,
           round(coalesce(sum(s.amount_per_cycle * cma.active_month_factor_of(s.billing_interval, s.billing_interval_count)), 0), 2) as amount
    from cma.subscription s
    where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.source_deleted_at is null and s.status = 'active'
      and s.currency is not null and s.amount_per_cycle is not null
  ), v as (
    select it.*,
           case when it.figure_key = 'recurring_amount_active' then (select case when cur.currencies = 1 then cur.currency end from cur) end as currency,
           case it.figure_key
             when 'subscriptions_in_status' then
               (select count(*) from cma.subscription s
                where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.source_deleted_at is null
                  and s.status = it.dims ->> 'status')::numeric
             when 'recurring_amount_active' then
               (select case when cur.currencies = 1 then cur.amount when cur.currencies = 0 then 0 end from cur)
             when 'renewal_survival' then null::numeric
             else
               (select count(*) from cma.subscription_event e
                where e.tenant_id = v_tenant and e.connection_id = p_connection_id
                  and e.occurred_at >= (it.business_date::timestamp at time zone v_zone)
                  and e.occurred_at < ((it.business_date + 1)::timestamp at time zone v_zone)
                  and case it.figure_key
                        when 'renewals' then e.event_type = 'renewed'
                        when 'purchases' then e.event_type = 'purchased'
                        when 'pauses' then e.status_to = 'paused'
                        when 'exits' then e.status_to = it.dims ->> 'status'
                      end)::numeric
           end as cma_value
    from it
  ), old as (
    select f.figure_key, f.business_date, f.dims, f.value, f.currency, f.cma_value
    from cma.source_figure f
    join v on v.figure_key = f.figure_key and v.business_date = f.business_date and v.dims = f.dims
    where f.tenant_id = v_tenant and f.connection_id = p_connection_id
  ), w as (
    insert into cma.source_figure as f (tenant_id, connection_id, figure_key, source_metric, business_date, dims, value, unit, currency,
                                        cma_value, cma_at, fetched_at, run_id, raw)
    select v_tenant, p_connection_id, v.figure_key, v.source_metric, v.business_date, v.dims, v.value, v.unit, v.currency,
           v.cma_value, case when v.cma_value is not null then now() end, now(), p_run_id,
           jsonb_build_object('first_fetched_at', now(), 'fetches', 1)
    from v
    order by v.figure_key, v.business_date, v.dims
    on conflict (tenant_id, connection_id, figure_key, business_date, dims) do update
      set source_metric = excluded.source_metric, value = excluded.value, unit = excluded.unit, currency = excluded.currency,
          cma_value = excluded.cma_value, cma_at = excluded.cma_at, fetched_at = excluded.fetched_at, run_id = excluded.run_id,
          raw = jsonb_build_object('first_fetched_at', coalesce(f.raw -> 'first_fetched_at', excluded.raw -> 'first_fetched_at'),
                                   'fetches', coalesce((f.raw ->> 'fetches')::integer, 0) + 1)
    returning f.figure_key, f.business_date, f.dims, f.value, f.currency, f.cma_value
  )
  select jsonb_build_object(
           'inserted',  count(*) filter (where o.figure_key is null),
           'updated',   count(*) filter (where o.figure_key is not null
                                         and (o.value, o.currency, o.cma_value) is distinct from (w.value, w.currency, w.cma_value)),
           'unchanged', count(*) filter (where o.figure_key is not null
                                         and (o.value, o.currency, o.cma_value) is not distinct from (w.value, w.currency, w.cma_value)))
  into v_out
  from w
  left join old o on o.figure_key = w.figure_key and o.business_date = w.business_date and o.dims = w.dims;
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The reads: the comparison and when a day's read is due
-- ---------------------------------------------------------------------------------------------
-- The stored figures of a tenant between two business dates with the comparison (the owner's core: no permission check,
-- the data-quality refresh reads it; executable by the application only). gap is the CMA's value less the source's;
-- gap_pct its size in percent of the source's value (null when that is 0). state: not_compared (renewal_survival, or no
-- CMA value: an amount of several currencies), gap (exceeds source_figures.tolerance_min and source_figures.tolerance_pct
-- of the source's value, both), within otherwise. store and market are the connection's store (null without one)
create or replace function cma.source_figure_rows_of(p_tenant_id uuid, p_from date, p_to date)
returns table (connection_id uuid, store text, market text, figure_key text, kind text, business_date date, dims jsonb, unit text,
               currency text, source_value numeric, cma_value numeric, gap numeric, gap_pct numeric, state text,
               fetched_at timestamptz, cma_at timestamptz)
language sql stable
rows 500
as $$
  -- the two tolerances once (scalar subqueries, never a cross join a per-row loop would repeat: CLAUDE.md, N06), and the
  -- stores once: a join on the stores' function itself was run again for every row (5,355 loops, 409 ms on the volume
  -- fixture with about 10,000 rows)
  with s as materialized (
    select cma.setting_of(p_tenant_id, 'source_figures.tolerance_pct')::numeric as pct,
           cma.setting_of(p_tenant_id, 'source_figures.tolerance_min')::numeric as mn
  ), sm as materialized (
    select x.connection_id, x.handle, x.market from cma.flash_subscription_stores_of(p_tenant_id) x
  )
  select f.connection_id, sm.handle, sm.market, f.figure_key, k.kind, f.business_date, f.dims, f.unit, f.currency,
         f.value, f.cma_value, f.cma_value - f.value,
         case when f.value > 0 and f.cma_value is not null then round(abs(f.cma_value - f.value) * 100 / f.value, 2) end,
         case when not k.compared or f.cma_value is null then 'not_compared'
              when abs(f.cma_value - f.value) > (select s.mn from s)
                   and abs(f.cma_value - f.value) * 100 > (select s.pct from s) * f.value then 'gap'
              else 'within' end,
         f.fetched_at, f.cma_at
  from cma.source_figure f
  join cma.source_figure_keys() k on k.figure_key = f.figure_key
  left join sm on sm.connection_id = f.connection_id
  -- keyed by p_tenant_id alone: cma_read.data_quality_rows() (a definer) reads every tenant a reader sees through
  -- cma.data_quality_of; under the application row-level security keeps the current tenant's rows
  where f.tenant_id = p_tenant_id and f.business_date between p_from and p_to
$$;

-- One business date's comparison for the current tenant: reports.view or tenant.configure (CMA06 otherwise, and for
-- another tenant), in store, figure and dims order
create or replace function cma.source_figure_compare_of(p_tenant_id uuid, p_date date)
returns table (connection_id uuid, store text, market text, figure_key text, kind text, business_date date, dims jsonb, unit text,
               currency text, source_value numeric, cma_value numeric, gap numeric, gap_pct numeric, state text,
               fetched_at timestamptz, cma_at timestamptz)
language plpgsql stable
rows 100
as $$
begin
  perform cma.assert_any_permission(array['reports.view', 'tenant.configure']);
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() or p_date is null then
    raise exception 'the source figures are compared for the current tenant and a date only' using errcode = 'CMA06';
  end if;
  return query
    select r.* from cma.source_figure_rows_of(p_tenant_id, p_date, p_date) r
    join cma.source_figure_keys() k on k.figure_key = r.figure_key
    order by r.store collate "C" nulls last, r.connection_id, k.sort_order, r.dims::text collate "C";
end
$$;

-- Whether a connection's daily read of the source's figures is due (ingest.write; the connection active and the current
-- tenant's): due from source_figures.local_time in the tenant's zone, once a day, until a run of the job source_figures
-- of the connection started after that time has succeeded (a failed run leaves it due: the next hourly run reads again).
-- Answers the business dates the read takes (yesterday and today in the tenant's zone) and the zone for the source
create or replace function cma.source_figures_due_of(p_connection_id uuid)
returns table (due boolean, today date, yesterday date, timezone text, due_at timestamptz)
language plpgsql stable
rows 1
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_zone   text;
  v_today  date;
  v_due_at timestamptz;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if not exists (select 1 from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id and c.kind = 'subscriptions') then
    raise exception 'connection % is not a subscriptions connection', p_connection_id using errcode = 'CMA02';
  end if;
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;
  v_today := (now() at time zone v_zone)::date;
  v_due_at := (v_today + cma.setting_of(v_tenant, 'source_figures.local_time')::time) at time zone v_zone;
  return query
    select now() >= v_due_at
           -- min() over the job's time index, a bounded range, never exists() (CLAUDE.md, Performance, N06)
           and (select min(r.started_at) from cma.sync_run r
                where r.tenant_id = v_tenant and r.job = 'source_figures' and r.connection_id = p_connection_id
                  and r.started_at >= v_due_at and r.status = 'succeeded') is null,
           v_today, v_today - 1, v_zone, v_due_at;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Data quality: source_figure_gap (B.3)
-- ---------------------------------------------------------------------------------------------
-- As 0009ze's (210), with the check of 0009zg
-- based on: 210_subscription_facts.sql
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
    ('field_device_on_non_holding_subscription', 370, 'Devices in the field linked to a subscription in a status that is neither device-holding nor ended (flash.device_holding_statuses, flash.ended_subscription_statuses), with its status'),
    ('subscription_variant_unmapped',            380, 'Product variants on an active subscription line (not canceled, of a subscription in a device-holding status) without a variant mapping, with the active lines'),
    ('subscription_device_units_mismatch',       390, 'Subscriptions in a device-holding status whose device units differ from the devices in the field linked to them (more_paid or more_placed); one without any such device is active_subscription_without_device''s'),
    ('source_figure_gap',                        400, 'The subscription app''s own figures that differ from the CMA''s by more than source_figures.tolerance_pct and source_figures.tolerance_min both, per store, figure and status, on the latest date read (a flow''s latest complete day), with the date and both values')
$$;

-- As 0009ze's (210), with the check of 0009zg
-- based on: 210_subscription_facts.sql
create or replace function cma.data_quality_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_start   timestamptz;
  -- 0009o: read once per call, not per row: the market map (every value a record, contact, line or store writes, with
  -- the code the market rule gives it, cma.market_codes_of), the device-holding and the ended statuses
  v_codes   jsonb := (select coalesce(jsonb_object_agg(c.value, c.code), '{}'::jsonb) from cma.market_codes_of(p_tenant_id) c);
  v_holding text[] := cma.flash_holding_statuses_of(p_tenant_id);
  v_ended   text[] := cma.flash_ended_statuses_of(p_tenant_id);
  -- 0009zg: the tenant's today once, for the source figures' check (a function that reads a table, never inlined: a
  -- filter on it would call it once per row)
  v_today   date := cma.tenant_today_of(p_tenant_id);
begin
  select cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone into v_start
  from cma.tenant t where t.id = p_tenant_id;

  return query
  -- 0009o: the open tickets once (two checks read them)
  with ot as materialized (select * from cma.open_tickets_of(p_tenant_id))
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
    and nullif(btrim(cr.market), '') is not null and (v_codes ->> cr.market) is null
  union all
  select 'market_not_in_catalog', k.connection_id, 'contact', k.source_id, k.country
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and nullif(btrim(k.country), '') is not null and (v_codes ->> k.country) is null
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
         (v_codes ->> k.country) || '/' || st.market
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id
  join cma.commerce_customer cu
    on cu.tenant_id = r.tenant_id and cu.source_system = r.system and cu.source_id = r.external_id and cu.source_deleted_at is null
  join cma.commerce_store st on st.tenant_id = cu.tenant_id and st.connection_id = cu.connection_id
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and (v_codes ->> k.country) is distinct from st.market
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
  from ot t
  where t.owner_ref is null and cma.follow_up_configured_of(p_tenant_id)
  union all
  select 'ticket_no_market', t.connection_id, 'ticket', t.ticket_source_id, t.pipeline_id
  from ot t
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
  -- devices in a status in the field without a subscription reference (0008zi): the rule's one implementation, which
  -- the Installed base's list reads too (0009f)
  select 'field_device_without_subscription_ref', u.connection_id, 'device', u.source_id, null::text
  from cma.field_devices_without_subscription_ref_of(p_tenant_id) u
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
    and sb.status = any (v_holding) and cma.assets_set_up_of(p_tenant_id)
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
        where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.status = any (v_ended)
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
    and not (sb.status = any (v_holding)) and not (sb.status = any (v_ended));

  -- variants on an active line without a mapping (0009ze): per variant the active lines (not canceled, still held, of a
  -- present subscription in a device-holding status); fixed in the CMA (the variant mapping)
  return query
  select 'subscription_variant_unmapped'::text, l.connection_id, 'variant'::text, l.variant_source_id, count(*)::text
  from cma.subscription_line l
  join cma.subscription s on s.tenant_id = l.tenant_id and s.connection_id = l.connection_id and s.source_id = l.subscription_source_id
  where l.tenant_id = p_tenant_id and l.canceled_at is null and l.source_deleted_at is null and l.variant_source_id is not null
    and s.source_deleted_at is null and s.status = any (v_holding)
    and not exists (select 1 from cma.subscription_variant_mapping m
                    where m.tenant_id = l.tenant_id and m.connection_id = l.connection_id and m.variant_source_id = l.variant_source_id)
  group by l.connection_id, l.variant_source_id;

  -- device units against the devices in the field (0009ze): a subscription in a device-holding status whose device units
  -- (known: no unmapped line) differ from the devices in the field linked to it as the installed base links them (its
  -- market and the device's subscription reference). One without any such device is active_subscription_without_device's,
  -- so none is listed twice. The value more_paid or more_placed; fixed in the asset register
  return query
  select 'subscription_device_units_mismatch'::text, sb.connection_id, 'subscription'::text, sb.source_id,
         case when sb.device_units > d.n then 'more_paid' else 'more_placed' end
  from (select x.connection_id, x.source_id, x.device_units, sm.market
        from cma.subscription x
        join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = x.connection_id
        where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.device_units is not null and x.status = any (v_holding)) sb
  join (select dv.market, dv.subscription_ref, count(*) as n
        from cma.device dv
        join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
        where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
        group by 1, 2) d on d.market = sb.market and d.subscription_ref = sb.source_id
  where d.n <> sb.device_units;

  -- the subscription app's own figures against the CMA's (0009zg): per connection, figure and dims the latest date read
  -- in the last seven days (a stock figure's latest read, a flow's latest complete day, before today in the tenant's
  -- zone), listed when its gap exceeds both tolerances (cma.source_figure_rows_of). The id the figure and its status; the
  -- value the date and both values. Fixed in the subscriptions source (a missed read or a rule shows here first)
  return query
  select 'source_figure_gap'::text, g.connection_id, 'source_figure'::text,
         g.figure_key || coalesce(':' || (g.dims ->> 'status'), ''),
         g.business_date::text || ' source ' || trim_scale(g.source_value)::text || ' cma ' || trim_scale(g.cma_value)::text
  from (select distinct on (r.connection_id, r.figure_key, r.dims) r.connection_id, r.figure_key, r.dims, r.business_date,
               r.source_value, r.cma_value, r.state
        from cma.source_figure_rows_of(p_tenant_id, v_today - 7, v_today) r
        where r.kind = 'stock' or (r.kind = 'flow' and r.business_date < v_today)
        order by r.connection_id, r.figure_key, r.dims, r.business_date desc) g
  where g.state = 'gap';

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
alter function cma.data_quality_of(uuid) set jit = off;

-- As 0009ze's (210): the check of 0009zg while subscriptions are set up
-- based on: 210_subscription_facts.sql
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
         or (fc.check_key in ('subscription_customer_unmatched', 'subscription_variant_unmapped', 'source_figure_gap') and (s.src -> 'subscriptions' ->> 'set_up')::boolean)
         or (fc.check_key in ('active_subscription_without_device', 'device_subscription_ref_unknown', 'field_device_on_ended_subscription',
                              'field_device_on_non_holding_subscription', 'subscription_device_units_mismatch')
             and (s.src -> 'subscriptions' ->> 'set_up')::boolean and (s.src -> 'assets' ->> 'set_up')::boolean)
    )
    select c.check_key, c.description,
           case when c.check_key = 'writeback_parked' and to_regclass('cma.outbox_action') is null then null
                else coalesce((select q.n from q where q.check_key = c.check_key), 0) end
    from c
    order by c.sort_order;
end
$$;

-- As 0009ze's (210): source_figure_gap is fixed in the subscriptions source
-- based on: 210_subscription_facts.sql
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
                         'device_subscription_ref_unknown', 'field_device_on_ended_subscription', 'field_device_on_non_holding_subscription',
                         'subscription_device_units_mismatch') then 'assets'
    -- the subscription app's own figures (0009zg): a missed read or a rule of the subscriptions source
    when p_check_key = 'source_figure_gap' then 'subscriptions'
    else 'cma' end
$$;

-- As 0009o's (178): a source figure's finding takes its store's market
-- based on: 178_job_reads.sql
create or replace function cma.flash_findings_compute_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text, market text, fix_in text, fix_adapter text)
language sql stable
as $$
  with f as materialized (
    select q.* from cma.data_quality_of(p_tenant_id) q
  ), mm as materialized (
    -- 0009o: the market map once per call (each value with the code the market rule gives it), not a read per finding
    select coalesce(jsonb_object_agg(x.value, x.code), '{}'::jsonb) as m from cma.market_codes_of(p_tenant_id) x
  ), c as materialized (
    select ic.id, ic.adapter, coalesce(ic.kind, (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1]) as kind, ic.status
    from cma.integration_connection ic where ic.tenant_id = p_tenant_id
  ), ka as materialized (
    select distinct on (c.kind) c.kind, c.adapter from c where c.status = 'active' and c.kind is not null order by c.kind, c.id
  ), st as materialized (
    select x.connection_id, x.market from cma.commerce_store x where x.tenant_id = p_tenant_id
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  )
  select f.check_key, f.connection_id, f.object_type, f.object_id, f.value,
         coalesce(case f.object_type
                    when 'commerce_customer' then st.market
                    when 'subscription' then sm.market
                    when 'source_figure' then sm.market
                    when 'market' then f.object_id
                    when 'device' then (select d.market from cma.device d
                                        where d.tenant_id = p_tenant_id and d.connection_id = f.connection_id and d.source_id = f.object_id)
                    when 'contact' then (select (select mm.m from mm) ->> k.country from cma.crm_contact k
                                         where k.tenant_id = p_tenant_id and k.connection_id = f.connection_id and k.source_id = f.object_id)
                    when 'form' then (select cf.market from cma.connection_form cf
                                      where cf.tenant_id = p_tenant_id and cf.connection_id = f.connection_id and cf.source_form_id = f.object_id)
                    when 'review_channel' then (select ch.market from cma.review_channel ch
                                                where ch.tenant_id = p_tenant_id and ch.connection_id = f.connection_id and ch.source_id = f.object_id)
                    when 'deal' then (select coalesce((select mm.m from mm) ->> r.market, (select mm.m from mm) ->> rk.country)
                                      from cma.crm_record r
                                      left join cma.crm_contact rk
                                        on rk.tenant_id = r.tenant_id and rk.connection_id = r.connection_id and rk.source_id = r.contact_source_id
                                      where r.tenant_id = p_tenant_id and r.connection_id = f.connection_id and r.record_type = 'deal'
                                        and r.source_id = f.object_id)
                    when 'ticket' then (select coalesce((select mm.m from mm) ->> r.market, (select mm.m from mm) ->> rk.country)
                                        from cma.crm_record r
                                        left join cma.crm_contact rk
                                          on rk.tenant_id = r.tenant_id and rk.connection_id = r.connection_id and rk.source_id = r.contact_source_id
                                        where r.tenant_id = p_tenant_id and r.connection_id = f.connection_id and r.record_type = 'ticket'
                                          and r.source_id = f.object_id) end, 'unknown'),
         x.fix_in,
         case when x.fix_in = 'cma' then null when c1.kind = x.fix_in then c1.adapter else ka.adapter end
  from f
  cross join lateral (select cma.data_quality_fix_in(f.check_key, f.value) as fix_in) x
  left join c c1 on c1.id = f.connection_id
  left join ka on ka.kind = x.fix_in
  left join st on f.object_type = 'commerce_customer' and st.connection_id = f.connection_id
  left join sm on f.object_type in ('subscription', 'source_figure') and sm.connection_id = f.connection_id
$$;
alter function cma.flash_findings_compute_of(uuid) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 6. The Flash watch: the figures job's own stale check (B.3)
-- ---------------------------------------------------------------------------------------------
-- As 0009e's (158): the source figures' job watched on its own
-- based on: 158_flash_current_take.sql
create or replace function cma.flash_watch_of(p_tenant_id uuid, p_date date, p_now timestamptz)
returns jsonb
language plpgsql
as $$
declare
  v_pct      numeric := cma.setting_of(p_tenant_id, 'flash.watch_jump_pct')::numeric;
  v_min      numeric := cma.setting_of(p_tenant_id, 'flash.watch_jump_min')::numeric;
  v_floor    numeric := cma.setting_of(p_tenant_id, 'flash.watch_stale_min_minutes')::numeric;
  v_prev_ok  boolean;
  v_flow_ok  boolean;
  v_opened   integer;
  v_resolved integer;
begin
  perform cma.assert_permission('flash.snapshot');
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() or p_date is null or p_now is null then
    raise exception 'the watch runs for the current tenant only' using errcode = 'CMA06';
  end if;
  v_prev_ok := exists (select 1 from cma.flash_snapshot_run r where r.tenant_id = p_tenant_id and r.snapshot_date = p_date - 1 and r.status = 'succeeded');
  v_flow_ok := (select count(*) from cma.flash_snapshot_run r
                where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date between p_date - 7 and p_date - 1) = 7;
  with sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  ), m as (
    select o.key as overview, unnest(o.count_measures) as measure, o.kind from cma.flash_overviews() o
  ), day_rows as (
    -- the [market] rows of the stock overviews and the [check] rows of data quality, on p_date and the date before
    select s.snapshot_date, s.overview, s.dims, e.key as measure, (e.value #>> '{}')::numeric as v
    from cma.flash_snapshot s
    cross join lateral jsonb_each(s.measures) e
    join m on m.overview = s.overview and m.measure = e.key and m.kind = 'stock'
    where s.tenant_id = p_tenant_id and s.snapshot_date in (p_date, p_date - 1) and jsonb_typeof(e.value) = 'number'
      and ((s.overview <> 'data_quality' and s.dims ? 'market' and (select count(*) from jsonb_object_keys(s.dims)) = 1)
           or (s.overview = 'data_quality' and s.dims ? 'check' and (select count(*) from jsonb_object_keys(s.dims)) = 1))
  ), na as (
    -- a count measure left out of an overview's totals row on either date does not apply that day (with_required_refs
    -- while no contact reference is required): it is not compared, so switching a requirement on or off is no jump
    select distinct s.overview, m.measure
    from cma.flash_snapshot s
    join m on m.overview = s.overview and m.kind = 'stock'
    where s.tenant_id = p_tenant_id and s.snapshot_date in (p_date, p_date - 1) and s.dims = '{}'::jsonb and not (s.measures ? m.measure)
    union
    -- an overview whose definition changed between the two dates (its totals stored under two versions, 0008zu): none of
    -- its measures is compared, so a change of what a figure counts is no jump
    select x.overview, m.measure
    from (select s.overview from cma.flash_snapshot s
          where s.tenant_id = p_tenant_id and s.snapshot_date in (p_date, p_date - 1) and s.dims = '{}'::jsonb
          group by s.overview having count(distinct s.definition_version) > 1) x
    join m on m.overview = x.overview and m.kind = 'stock'
  ), j as (
    select coalesce(t.overview, y.overview) as overview, coalesce(t.dims, y.dims) as dims, coalesce(t.measure, y.measure) as measure,
           coalesce(t.v, 0) as v, coalesce(y.v, 0) as p
    from (select * from day_rows where snapshot_date = p_date) t
    full join (select * from day_rows where snapshot_date = p_date - 1) y on y.overview = t.overview and y.dims = t.dims and y.measure = t.measure
    where not exists (select 1 from na where na.overview = coalesce(t.overview, y.overview) and na.measure = coalesce(t.measure, y.measure))
  ), prev as (
    -- a flow overview's [market] rows above 0 on each of the 7 dates before p_date
    select s.overview, s.dims, e.key as measure
    from cma.flash_snapshot s
    cross join lateral jsonb_each(s.measures) e
    join m on m.overview = s.overview and m.measure = e.key and m.kind = 'flow'
    where s.tenant_id = p_tenant_id and s.snapshot_date between p_date - 7 and p_date - 1
      and s.dims ? 'market' and (select count(*) from jsonb_object_keys(s.dims)) = 1
      and jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric > 0
    group by 1, 2, 3
    having count(*) = 7
  ), c as (
    select ic.id, ic.adapter, ic.settings,
           case when ic.kind is not null then ic.kind
                when exists (select 1 from cma.commerce_store x where x.tenant_id = ic.tenant_id and x.connection_id = ic.id) then 'commerce'
                else (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1] end as kind,
           coalesce((select st.handle from cma.commerce_store st where st.tenant_id = ic.tenant_id and st.connection_id = ic.id),
                    (select sm.handle from sm where sm.connection_id = ic.id)) as store
    from cma.integration_connection ic
    where ic.tenant_id = p_tenant_id and ic.status = 'active'
  ), win as (
    -- the succeeded runs of the 7 days before p_now of the active connections of a source Flash reads, backfills aside
    -- (started by hand: no cadence), each with the gap since the run before of the same job and stream in those days
    select x.connection_id, x.job, x.stream, x.finished_at,
           extract(epoch from x.finished_at - lag(x.finished_at) over (partition by x.connection_id, x.job, x.stream order by x.finished_at)) / 60 as gap
    from cma.sync_run x
    where x.tenant_id = p_tenant_id and x.status = 'succeeded' and x.job <> 'backfill'
      and x.finished_at > p_now - interval '7 days' and x.finished_at <= p_now
      and x.connection_id in (select c.id from c where c.kind in ('commerce', 'subscriptions', 'assets', 'crm', 'reviews'))
  ), sets as (
    -- a connection's poll interval settings: <job>_interval_minutes is the cadence of that job (assets_poll_interval_minutes
    -- of assets_poll), the smallest when two name one job
    select c.id as connection_id, left(e.key, length(e.key) - length('_interval_minutes')) as job,
           min((e.value #>> '{}')::numeric) as minutes
    from c
    cross join lateral jsonb_each(c.settings) e
    where c.kind in ('commerce', 'subscriptions', 'assets', 'crm', 'reviews')
      and e.key like '%\_poll\_interval\_minutes'
      and case when (e.value #>> '{}') ~ '^[0-9]{1,5}$' then (e.value #>> '{}')::numeric > 0 else false end
    group by 1, 2
  ), cand as (
    -- every job and stream with a cadence: its setting (its age from its last succeeded run of any time), else the median
    -- gap of its runs of the 7 days (raw), at least flash.watch_stale_min_minutes (cadence)
    select s.connection_id, x.job, x.stream, max(x.finished_at) as last_at, s.minutes as raw, s.minutes as cadence, 'setting'::text as basis
    from sets s
    join cma.sync_run x on x.tenant_id = p_tenant_id and x.connection_id = s.connection_id and x.job = s.job
                       and x.status = 'succeeded' and x.finished_at <= p_now
    group by s.connection_id, x.job, x.stream, s.minutes
    union all
    select w.connection_id, w.job, w.stream, max(w.finished_at),
           (percentile_cont(0.5) within group (order by w.gap) filter (where w.gap > 0))::numeric,
           greatest((percentile_cont(0.5) within group (order by w.gap) filter (where w.gap > 0))::numeric, v_floor), 'runs'
    from win w
    where not exists (select 1 from sets s where s.connection_id = w.connection_id and s.job = w.job)
    group by w.connection_id, w.job, w.stream
    having count(*) filter (where w.gap > 0) > 0
  ), gov as (
    -- a connection's most frequent job and stream: the smallest cadence before the floor (on a tie the latest read, then
    -- the names), so a job measured at 1 minute governs one set at 5 even though the floor makes both 5
    -- the same connection's source figures (0009zg: job source_figures, daily) are watched on their own as the source
    -- source_figures, so the poll every five minutes does not hide a day without figures; every other job as before
    (select distinct on (k.connection_id) k.connection_id, k.job, k.stream, k.last_at, k.cadence, k.basis, c.kind, c.adapter, c.store
     from cand k
     join c on c.id = k.connection_id
     where k.job <> 'source_figures'
     order by k.connection_id, k.raw, k.last_at desc, k.job collate "C", k.stream collate "C" nulls first)
    union all
    (select distinct on (k.connection_id) k.connection_id, k.job, k.stream, k.last_at, k.cadence, k.basis, 'source_figures'::text, c.adapter, c.store
     from cand k
     join c on c.id = k.connection_id
     where k.job = 'source_figures'
     order by k.connection_id, k.last_at desc, k.stream collate "C" nulls first)
  ), cur as (
    -- jump and dq_rise
    select case when j.overview = 'data_quality' then 'dq_rise' else 'jump' end as kind, j.overview, j.dims, j.measure, j.v as value,
           j.p as previous, round(greatest(v_min, v_pct * j.p / 100), 2) as threshold, jsonb_build_object('jump_pct', v_pct, 'jump_min', v_min) as detail
    from j
    where v_prev_ok and abs(j.v - j.p) > v_min and abs(j.v - j.p) * 100 > v_pct * j.p
      and (j.overview <> 'data_quality' or j.v > j.p)
    union all
    -- flow_zero
    select 'flow_zero', prev.overview, prev.dims, prev.measure, coalesce((s.measures ->> prev.measure)::numeric, 0), null::numeric, 0::numeric,
           jsonb_build_object('previous_days', 7)
    from prev
    left join cma.flash_snapshot s
      on s.tenant_id = p_tenant_id and s.snapshot_date = p_date and s.overview = prev.overview and s.dims = prev.dims
    where v_flow_ok and coalesce((s.measures ->> prev.measure)::numeric, 0) = 0
    union all
    -- source_stale: per source, adapter and store, the stale connection with the oldest read of its most frequent job and
    -- stream, and how many are stale
    select 'source_stale', null::text, z.dims, null::text, z.value, null::numeric, z.threshold,
           z.detail || jsonb_build_object('connections', z.n)
    from (select distinct on (st.dims) st.dims, st.value, st.threshold, st.detail, count(*) over (partition by st.dims) as n
          from (select jsonb_strip_nulls(jsonb_build_object('source', g.kind, 'adapter', g.adapter, 'store', g.store)) as dims,
                       round(extract(epoch from p_now - g.last_at) / 60) as value,
                       -- 0009zg: the daily figures job is stale after one and a half of its cadences, so a day without
                       -- figures shows at the next morning's snapshot (three cadences of a day would be three days)
                       round((case when g.kind = 'source_figures' then 1.5 else 3 end) * g.cadence) as threshold,
                       jsonb_build_object('cadence_minutes', round(g.cadence, 1), 'cadence_basis', g.basis,
                                          'age_minutes', round(extract(epoch from p_now - g.last_at) / 60), 'last_read_at', g.last_at)
                       || jsonb_strip_nulls(jsonb_build_object('job', g.job, 'stream', g.stream)) as detail,
                       g.last_at
                from gov g
                where extract(epoch from p_now - g.last_at) / 60 > (case when g.kind = 'source_figures' then 1.5 else 3 end) * g.cadence) st
          order by st.dims, st.last_at, st.value desc) z
    union all
    -- snapshot_missing
    select 'snapshot_missing', null::text, '{}'::jsonb, null::text, ((p_date - 1) - x.last_before)::numeric, null::numeric, null::numeric,
           jsonb_build_object('missing_from', x.last_before + 1, 'missing_to', p_date - 1, 'days', (p_date - 1) - x.last_before)
    from (select max(r.snapshot_date) as last_before from cma.flash_snapshot_run r
          where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date < p_date - 1) x
    where x.last_before is not null and not v_prev_ok
    union all
    -- current_stale (0009e): an overview of flash.current_overviews whose stored current take exists but is older than
    -- three times flash.current_refresh_minutes at p_now, so the page computes its now live: the refresh is failing. The
    -- value its age in minutes, the threshold three times the setting. No take at all is no finding (a source not set up
    -- keeps none); a take younger than that is none either, even when a change of definition or setting has made it
    -- unreadable until the next refresh
    select 'current_stale', k.overview, '{}'::jsonb, null::text, round(extract(epoch from p_now - k.computed_at) / 60), null::numeric,
           3 * cma.setting_of(p_tenant_id, 'flash.current_refresh_minutes')::numeric,
           jsonb_build_object('age_minutes', round(extract(epoch from p_now - k.computed_at) / 60))
    from (select c.overview, max(c.computed_at) as computed_at from cma.flash_current_take c
          where c.tenant_id = p_tenant_id group by c.overview) k
    where k.overview = any (cma.flash_current_overviews_of(p_tenant_id))
      and k.computed_at <= p_now - make_interval(mins => 3 * cma.setting_of(p_tenant_id, 'flash.current_refresh_minutes')::integer)
  ), res as (
    -- every open finding whose condition no longer holds
    update cma.flash_watch_finding f set state = 'resolved', resolved_on = p_date
    where f.tenant_id = p_tenant_id and f.state = 'open'
      and not exists (select 1 from cur n
                      where n.kind = f.kind and coalesce(n.overview, '') = coalesce(f.overview, '') and n.dims = f.dims
                        and coalesce(n.measure, '') = coalesce(f.measure, ''))
    returning 1
  ), ins as (
    -- every condition that holds without an open finding, once per key (a condition that holds twice is one finding, so
    -- a take never fails on the open findings' unique index)
    insert into cma.flash_watch_finding (tenant_id, snapshot_date, kind, overview, dims, measure, value, previous, threshold, detail)
    select distinct on (n.kind, coalesce(n.overview, ''), n.dims, coalesce(n.measure, ''))
           p_tenant_id, p_date, n.kind, n.overview, n.dims, n.measure, n.value, n.previous, n.threshold, n.detail
    from cur n
    where not exists (select 1 from cma.flash_watch_finding f
                      where f.tenant_id = p_tenant_id and f.state = 'open' and f.kind = n.kind
                        and coalesce(f.overview, '') = coalesce(n.overview, '') and f.dims = n.dims
                        and coalesce(f.measure, '') = coalesce(n.measure, ''))
    returning 1
  )
  select (select count(*) from res), (select count(*) from ins) into v_resolved, v_opened;
  return jsonb_build_object('watch_opened', v_opened, 'watch_resolved', v_resolved,
                            'watch_open', (select count(*) from cma.flash_watch_finding f where f.tenant_id = p_tenant_id and f.state = 'open'));
end
$$;
alter function cma.flash_watch_of(uuid, date, timestamptz) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 7. Readers and grants
-- ---------------------------------------------------------------------------------------------
-- Every column but raw: codes, dates and figures, no id of a customer or a subscription
create or replace view cma_read.source_figure as
  select tenant_id, connection_id, figure_key, source_metric, business_date, dims, value, unit, currency, cma_value, cma_at,
         fetched_at, run_id
  from cma.source_figure
  where cma_read.reader_sees(tenant_id);
comment on view cma_read.source_figure is
  'The subscription app''s own figures per connection, figure, business date and dims of every tenant the reader sees (addition 0009zg), with the CMA''s value of the same scope taken at cma_at: codes, dates and figures only, never an id of a customer or a subscription';

create or replace view cma_read.dq_source_figure_gap as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'source_figure_gap';

do $$
declare
  f text;
begin
  -- the application's: the catalog, the checks of a figure, the write, the reads (each checks its permission inside;
  -- the core is the data-quality refresh's, which runs under the application)
  foreach f in array array[
    'cma.source_figure_keys()', 'cma.source_figure_dims_ok(text,jsonb)', 'cma.ingest_upsert_source_figures(uuid,uuid,jsonb)',
    'cma.source_figure_rows_of(uuid,date,date)', 'cma.source_figure_compare_of(uuid,date)', 'cma.source_figures_due_of(uuid)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- JIT off on the plpgsql reads and the write: on the volume fixture JIT compiled the write's statement on each of a
  -- session's first five calls (1.2 s a call; 12 ms without it), and the job's calls are each a session's first
  foreach f in array array['cma.ingest_upsert_source_figures(uuid,uuid,jsonb)', 'cma.source_figure_compare_of(uuid,date)',
                           'cma.source_figures_due_of(uuid)'] loop
    execute format('alter function %s set jit = off', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. sync_run's constraints, last: the lock they take is held to the commit
-- ---------------------------------------------------------------------------------------------
-- The job source_figures joins the list, with a connection (as 172's section 9). An alter table that adds a constraint
-- takes an ACCESS EXCLUSIVE lock on cma.sync_run that the transaction keeps until it commits: placed here, directly
-- before the record and the commit, the lock lasts the two validations alone (CLAUDE.md, Performance). The job's first
-- run comes only after the commit
alter table cma.sync_run drop constraint if exists sync_run_job_check;
alter table cma.sync_run add constraint sync_run_job_check
  check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls', 'email_poll', 'close_forgotten_workdays',
                 'refresh_follow_up', 'reviews_poll', 'legacy_call_import', 'assets_import', 'assets_poll', 'subscriptions_poll',
                 'flash_snapshot', 'refresh_data_quality', 'refresh_active_customers', 'source_figures')) not valid;
alter table cma.sync_run validate constraint sync_run_job_check;

-- ---------------------------------------------------------------------------------------------
-- 9. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zg', 'The subscription app''s own figures beside the CMA''s (brief B39 continued, Part B39b): the settings source_figures.tolerance_pct (1), source_figures.tolerance_min (2) and source_figures.local_time (05:00), checked by cma.check_tenant_setting(); cma.source_figure (per connection, figure, business date and dims: the source''s value, unit and currency, the CMA''s value of the same scope taken when written, the latest fetch and its run; no audit trigger) with cma.source_figure_keys() and cma.source_figure_dims_ok(); cma.ingest_upsert_source_figures (ingest.write); cma.source_figure_rows_of, cma.source_figure_compare_of (reports.view or tenant.configure) and cma.source_figures_due_of (ingest.write); data quality source_figure_gap (fixed in subscriptions; the store''s market); the Flash watch''s source_stale watches the job source_figures on its own; sync_run job source_figures; readers cma_read.source_figure and cma_read.dq_source_figure_gap')
on conflict (version) do nothing;

commit;
reset role;
