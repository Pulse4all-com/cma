-- =============================================================================================
-- 172_active_customers.sql: addition 0009l, Customers → Active (the active customer base: its state and its movement)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: the statuses a figure counts, the segments, the ages, the history's
-- length, the refresh's cadence and the indicative rates are the tenant's settings; the stores, markets and models its
-- catalogs. Runs unchanged in every database, after 170_live_inbound_talk.sql (0009k). Rerunnable, forward-only, in one
-- transaction with a lock timeout; an earlier form of this script (the pull request's first rounds, dev only) is
-- replaced by it. Run as your own IAM login: dev first, then 173_verify_active_customers.sql there (normal, then
-- provoked), then the verifies that read what this script re-creates:
--   cma.check_tenant_setting() (from 150): by name 73_verify_follow_up.sql, 101_verify_definitions_calls.sql,
--     113_verify_assets.sql, 121_verify_lead_cohorts.sql, 123_verify_flash.sql and 137_verify_flash_insights.sql (each
--     reads the function's source for the branches 172 keeps); through its trigger check_value on cma.tenant_setting
--     14_verify_tenant_settings.sql and 151_verify_courtesy.sql
--   cma.ensure_scheduler_user(uuid) (from 168): 27_verify_configuration.sql (edited by this change: its list of the
--     jobs' permissions gains customers.refresh), 123_verify_flash.sql and 169_verify_pledge_lists.sql
--   cma.job_permission_of(text) and cma.job_run_start(text) (from 132): 81_verify_follow_up_snapshot.sql,
--     123_verify_flash.sql and 133_verify_perf.sql
--   sync_run's constraints sync_run_job_check and sync_run_connection_check (as 132's section 10 wrote them, with one more
--     job): 79_verify_system_health.sql, 81, 105_verify_reviews.sql, 109_verify_legacy_call_outcome.sql, 113,
--     115_verify_asset_sync.sql, 119_verify_subscriptions.sql and 123
-- All but 27 unchanged, still PASS: each function keeps every earlier rule in its order and gains one name, the
-- constraints one job. 85_verify_first_orders.sql is optional (cma.first_orders_of is read here, not re-created). Then
-- seed 02 (Pulse4all's customers settings and the empty rates) and, in dev, seed 03 (the test rates and the synthetic
-- base); then 131_time_all.sql part b, which gains a row per read of the page and one for the refresh, and refuses to
-- run before 0009l. Then the job: docs/scheduler/deploy-active-customers.sh with the merge's image.
-- Prod: this script and 173 before the merge (docs/RUNBOOK.md's usual order). The web of main runs unchanged on it:
-- nothing main reads changes. The web of this change reads cma.active_top, cma.active_rest and cma.active_rows, and the
-- merge deploys it. The job's image is the merge's, so the job is deployed right after the merge; until its first run a
-- tenant has no take and the page says "History is being prepared" with the tiles' live figures (never zeros). A first
-- take can be made by hand before the merge (the pull request's steps: cma.active_refresh() as the scheduler).
--
-- Why (Martin, 11 November 2026, brief B35 with addenda A and B; Decision log): the sales director, Kira, Peter and Bas
-- open one page first for the state and the movement of the customer base: who the active customers are, in which
-- markets and segments, direct or indirect, how long they stay, what they are worth, how the base grows and shrinks,
-- how cohorts retain. One fact one source: the store's customers (commerce, 0007b) with their CRM contact (0008h) and
-- its segment (0008zt), the subscription app's subscriptions and events (0008zl), the asset register's devices (0008zi),
-- First orders' attribution (0008u) and the tenant's settings. Flash's population unchanged (0008zu): an Active customer
-- is a store customer with a subscription in a device-holding status; Total subscriptions are the subscriptions in one.
-- Addendum B (decisions D13 to D15): reconstructing the history on every request took 1.4 to 2.0 s at three times
-- prod's volume, so the history is read from a stored take the scheduler refreshes, the present stays live, and the
-- page reads in three layers (above the fold, below it, the list), each its own transaction.
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
--   Take               the stored results the history is read from, with the moment they were computed (History as of)
--
-- What it adds
--   settings          customers.cohort_ages_months (3,6,12,24,36; one to eight increasing, each at most 120),
--                     customers.age_months (12,24,36,48,60; one to ten), customers.history_months (60; 12 to 120),
--                     customers.refresh_minutes (5; 1 to 1440: how old a take may be before the next minute refreshes
--                     it), customers.history_notice_minutes (15; 1 to 1440: from when the page says its history is old),
--                     reports.fx_eur_rates ({}; a JSON object of currency codes with the euros one unit is worth and an
--                     as_of date; cma.active_fx_ok); cma.check_tenant_setting() as 0009a's (150) with the six
--   pure functions    cma.active_spells_from, cma.active_month_cube_from, cma.active_cohort_cube_from, cma.active_km_from
--                     (arrays in, rows out: no table read, so 173 proves them on hand-made arrays against brute force),
--                     cma.active_month_factor_of, cma.active_billing_of, cma.active_eur_of, cma.active_km_json
--   fresh reads       cma.active_base_of (the subscriptions with their holding interval, their store customer with
--                     Flash's own figures of it, its devices per model and its acquisition channel: First orders'
--                     attribution is read here alone), cma.active_customers_of, cma.active_spells_of(tenant),
--                     cma.active_channel_of(tenant), cma.active_spell_lengths_of, cma.active_survival_of(tenant, split),
--                     cma.active_months_of, cma.active_cohorts_of: what the refresh stores and 173 compares it with
--   the stored take   six tenant tables (cma.setup_tenant_table(): row-level security, the application's grants; no audit
--                     trigger, as 0008s's and 0008zr's stored results): cma.active_take (one row per tenant: History as
--                     of, stale), cma.active_base, cma.active_customer (with an index per sort key of the list),
--                     cma.active_spell, cma.active_month, cma.active_cohort. Ids, codes, amounts and times only
--   refresh           cma.active_refresh_of(tenant, force, now) and the job's entry cma.active_refresh() (the new
--                     permission customers.refresh, the scheduler's system user only): set-based, the base read once,
--                     only what changed written; the trigger mark_active_take_stale on cma.tenant_setting marks a take
--                     stale when a setting the stored rows depend on changes (cma.active_setting_marks_stale: attribution.*,
--                     customers.*, crm.customer_segments, the three flash.*_statuses settings and intake.start_date) and
--                     never refreshes there; the job refresh_active_customers in the run registry
--                     (cma.job_permission_of, cma.job_run_start, sync_run's two constraints)
--   page              three reads (reports.view or performance.team, CMA06), each its own transaction:
--                     cma.active_top(from_month, market, segment, channel): the tiles' live present
--                     (cma.active_present_of, which reads cma.flash_customer_figures_of) with the take's history;
--                     cma.active_rest(from_month, market, segment, channel, grouping): from the take alone;
--                     cma.active_rows(market, segment, channel, sort, descending, after, before, limit, file): keyset
--                     paging through the sort key's index, the worst payment state live for the page's rows;
--                     cma.active_markets() (the market filter's catalog), cma.active_file_record (the audit row of a
--                     file read)
--   readers           cma_read.active_customer_month and cma_read.customer_cohort, plain views of the stored take:
--                     counts per month or cohort, market, segment and acquisition channel; no customer, no contact
-- Indexes: on the new tables only (created with them, empty). No index on an existing table.
--
-- Everything is SECURITY INVOKER and executable by the application only, but the trigger function
-- cma.active_take_mark_stale() (SECURITY DEFINER, owned by cma_owner, search path pinned, nobody's to call).
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
  ('customers.refresh_minutes', 'integer', null, '5',
     'The minutes a tenant''s stored take of Customers → Active may be old before the scheduler''s next minute refreshes it, 1 to 1440'),
  ('customers.history_notice_minutes', 'integer', null, '15',
     'The minutes after which Customers → Active says its history is older than it should be, 1 to 1440'),
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
-- 2. Earlier forms of this script (the pull request's first rounds; they may have run in dev, never in prod)
-- ---------------------------------------------------------------------------------------------
-- A function whose arguments or answer changed since cannot be replaced in place, and one that is gone would stay behind:
-- they are dropped here, so a database that ran an earlier form ends up as one that never did. Nothing main reads
drop view if exists cma_read.active_customer_month;
drop view if exists cma_read.customer_cohort;
drop function if exists cma_read.active_customer_month_rows();
drop function if exists cma_read.customer_cohort_rows();
drop function if exists cma.active_page(date, text, text, text, text);
drop function if exists cma.active_page_of(uuid, date, text, text, text, text, timestamptz);
drop function if exists cma.active_rows(text, text, text, text, boolean, integer, integer, boolean);
drop function if exists cma.active_rows_of(uuid, text, text, text, text, boolean, integer, integer, timestamptz);
drop function if exists cma.active_survival_of(uuid, text);
drop function if exists cma.active_km_json(integer[], boolean[]);
drop function if exists cma.active_km_from(integer[], boolean[]);
drop function if exists cma.active_months_of(uuid, timestamptz);
drop function if exists cma.active_cohorts_of(uuid, text, timestamptz);
drop function if exists cma.active_spell_lengths_of(uuid, timestamptz, boolean);
drop function if exists cma.active_channel_of(uuid);
drop function if exists cma.active_spells_of(uuid);
drop function if exists cma.active_customers_of(uuid, timestamptz, boolean);
drop function if exists cma.active_base_of(uuid, timestamptz, boolean, date, boolean);

-- ---------------------------------------------------------------------------------------------
-- 3. The settings as values, and the pure functions (no table read: arrays in, rows out)
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
-- 3b. The base: the subscriptions with their holding interval, their store customer and its acquisition channel
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
               clv_currency text, channel text, level text, unknown_reason text, first_order_at timestamptz, device_models jsonb)
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
    -- a subscription's devices in the field, and how many of each model (the subscription mix's models)
    select q.subscription_ref, q.market, sum(q.n_field)::integer as n_field,
           jsonb_object_agg(q.model_key, q.n_field) filter (where q.n_field > 0) as models
    from (select d.subscription_ref, d.market, coalesce(d.model_key, 'unknown') as model_key,
                 count(*) filter (where coalesce(ds.is_in_field, false))::integer as n_field
          from cma.device d
          left join cma.device_status ds on ds.tenant_id = d.tenant_id and ds.key = d.device_status_key
          where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.subscription_ref is not null
          group by 1, 2, 3) q
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
           coalesce(dev.n_field, 0) as devices_in_field, dev.models as device_models
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
         a.created_at, sb.device_models
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
-- 4. The stored take: the history read from stored results (decision D13, addendum B)
-- ---------------------------------------------------------------------------------------------
-- The history of Customers → Active is read from stored results, refreshed by the scheduler every minute where a
-- tenant's take is older than customers.refresh_minutes or marked stale; the present stays live (cma.active_present_of).
-- Six tenant tables, ids, codes, amounts and times only (no name, address, email or phone; the contact's id as Flash's
-- customer list already shows it), each with cma.setup_tenant_table() (row-level security, the tenant policy, the
-- application's grants) and without the audit trigger (as 0008s's and 0008zr's stored results: a row image per row per
-- refresh would fill the audit log with computed values; the sources they are computed from are audited where they are
-- written):
--   cma.active_take       one row per tenant: when the take was computed ("History as of"), the business date its ages
--                         and lengths are of, how long the refresh took, whether a settings change marked it stale
--   cma.active_base       the base as cma.active_base_of answers it: one row per subscription with its holding interval,
--                         its store customer and that customer's figures and acquisition channel
--   cma.active_customer   one row per store customer of the base: the list's columns, with an index per sort key
--   cma.active_spell      a store customer's active spells with their length in whole months as of the take
--   cma.active_month      the month ends: per month, market, segment and acquisition channel the customers (kind
--                         customers), the subscriptions (subscriptions), the Monthly recurring amount per currency
--                         (amount), for the two month ends a change line compares with the customers with a
--                         subscription in a currency (currency_customers), and Flash's churn count of the last 30
--                         business dates (churned_30d)
--   cma.active_cohort     the customer cohorts per month and per quarter, market, segment, channel and age
-- A refresh writes only what changed: the base and the customers row by row (a row that reads the same is not written
-- again), the spells, the month ends and the cohorts only when the part of the base they are computed from, the
-- business date or a setting they read changed. So a quiet tenant costs a read every five minutes, not a rewrite.
create table if not exists cma.active_take (
  tenant_id         uuid primary key default cma.current_tenant_id() references cma.tenant (id),
  computed_at       timestamptz not null,
  business_date     date not null,
  duration_ms       integer not null check (duration_ms >= 0),
  history_key       text not null,
  customers         integer not null check (customers >= 0),
  subscriptions     integer not null check (subscriptions >= 0),
  attribution_start date,
  stale             boolean not null default false,
  stale_since       timestamptz
);
comment on table cma.active_take is 'When one tenant''s stored take of Customers → Active was computed (addition 0009l; History as of), the business date its ages are of, how long the refresh took and whether a settings change marked it stale';

create table if not exists cma.active_base (
  tenant_id uuid not null default cma.current_tenant_id() references cma.tenant (id),
  subscription_id uuid,
  connection_id uuid,
  source_id text,
  store text,
  market text,
  status text,
  is_holding boolean,
  is_paying boolean,
  payment_state text,
  currency text,
  monthly_amount numeric,
  billing text,
  devices_in_field integer,
  started_at timestamptz,
  ended_at timestamptz,
  in_history boolean,
  left_out text,
  customer_id uuid,
  customer_connection_id uuid,
  customer_source_id text,
  segment text,
  crm_connection_id uuid,
  contact_source_id text,
  customer_start timestamptz,
  customer_holding integer,
  customer_devices integer,
  clv numeric,
  clv_currency text,
  channel text,
  level text,
  unknown_reason text,
  first_order_at timestamptz,
  device_models jsonb,
  primary key (tenant_id, subscription_id)
);
comment on table cma.active_base is 'The base of Customers → Active as stored by the refresh (addition 0009l): one row per subscription with its holding interval, its store customer, that customer''s figures and its acquisition channel; ids, codes, amounts and times only';
create index if not exists active_base_customer_idx on cma.active_base (tenant_id, customer_id);

create table if not exists cma.active_customer (
  tenant_id uuid not null default cma.current_tenant_id() references cma.tenant (id),
  customer_id uuid,
  connection_id uuid,
  source_id text,
  store text,
  market text,
  segment text,
  channel text,
  level text,
  unknown_reason text,
  first_order_at timestamptz,
  customer_start timestamptz,
  age_months integer,
  is_active boolean,
  holding integer,
  devices integer,
  clv numeric,
  clv_currency text,
  crm_connection_id uuid,
  contact_source_id text,
  currency text,
  amount numeric,
  other_amounts jsonb,
  primary key (tenant_id, customer_id)
);
comment on table cma.active_customer is 'The store customers of Customers → Active as stored by the refresh (addition 0009l): Customer start and age, segment, acquisition channel with its level and Unknown reason, realised value and the list''s columns; ids, codes, amounts and times only';
-- the list's keyset paging: an index per sort key over the active customers, each ending in the customer's ids
create index if not exists active_customer_amount_idx on cma.active_customer (tenant_id, (coalesce(currency, '')), (coalesce(amount, -1)), source_id, customer_id) where is_active;
create index if not exists active_customer_clv_idx on cma.active_customer (tenant_id, (coalesce(clv_currency, '')), (coalesce(clv, -1)), source_id, customer_id) where is_active;
create index if not exists active_customer_source_idx on cma.active_customer (tenant_id, source_id, customer_id) where is_active;
create index if not exists active_customer_store_idx on cma.active_customer (tenant_id, store, source_id, customer_id) where is_active;
create index if not exists active_customer_market_idx on cma.active_customer (tenant_id, market, source_id, customer_id) where is_active;
create index if not exists active_customer_segment_idx on cma.active_customer (tenant_id, segment, source_id, customer_id) where is_active;
create index if not exists active_customer_start_idx on cma.active_customer (tenant_id, (coalesce(customer_start, '-infinity'::timestamptz)), source_id, customer_id) where is_active;
create index if not exists active_customer_age_idx on cma.active_customer (tenant_id, (coalesce(age_months, -1)), source_id, customer_id) where is_active;
create index if not exists active_customer_holding_idx on cma.active_customer (tenant_id, holding, source_id, customer_id) where is_active;
create index if not exists active_customer_devices_idx on cma.active_customer (tenant_id, devices, source_id, customer_id) where is_active;
create index if not exists active_customer_channel_idx on cma.active_customer (tenant_id, channel, source_id, customer_id) where is_active;
create index if not exists active_customer_level_idx on cma.active_customer (tenant_id, (coalesce(level, '')), source_id, customer_id) where is_active;

create table if not exists cma.active_spell (
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  customer_id    uuid not null,
  market         text not null,
  segment        text not null,
  channel        text not null,
  customer_start timestamptz,
  customer_start_on date,
  spell_start    timestamptz not null,
  spell_end      timestamptz,
  len            integer not null,
  ended          boolean not null,
  primary key (tenant_id, customer_id, spell_start)
);
comment on table cma.active_spell is 'The active spells of a store customer as stored by the refresh (addition 0009l): a maximal stretch in which at least one of its subscriptions holds, with its length in whole months as of the take and the Customer start as a date in the tenant''s zone';

create table if not exists cma.active_month (
  tenant_id uuid not null default cma.current_tenant_id() references cma.tenant (id),
  kind      text not null check (kind in ('customers', 'subscriptions', 'amount', 'currency_customers', 'churned_30d')),
  month     date not null,
  market    text not null,
  segment   text not null,
  channel   text not null,
  currency  text not null default '',
  inflow    numeric not null,
  outflow   numeric not null,
  at_end    numeric not null,
  primary key (tenant_id, kind, month, market, segment, channel, currency)
);
comment on table cma.active_month is 'The month ends of Customers → Active as stored by the refresh (addition 0009l): per month, market, segment and acquisition channel the customers, the subscriptions and the Monthly recurring amount per currency that started, ended and held';

create table if not exists cma.active_cohort (
  tenant_id    uuid not null default cma.current_tenant_id() references cma.tenant (id),
  period       text not null check (period in ('month', 'quarter')),
  cohort       date not null,
  market       text not null,
  segment      text not null,
  channel      text not null,
  age_months   integer not null,
  started      bigint not null,
  still_active bigint not null,
  mature       boolean not null,
  primary key (tenant_id, period, cohort, market, segment, channel, age_months)
);
comment on table cma.active_cohort is 'The customer cohorts of Customers → Active as stored by the refresh (addition 0009l): per month or quarter of the Customer start, market, segment, acquisition channel and age, the customers started, those still active at the age and whether the row is Mature';

select cma.setup_tenant_table('cma.active_take');
select cma.setup_tenant_table('cma.active_base');
select cma.setup_tenant_table('cma.active_customer');
select cma.setup_tenant_table('cma.active_spell');
select cma.setup_tenant_table('cma.active_month');
select cma.setup_tenant_table('cma.active_cohort');
drop trigger if exists audit on cma.active_take;
drop trigger if exists audit on cma.active_base;
drop trigger if exists audit on cma.active_customer;
drop trigger if exists audit on cma.active_spell;
drop trigger if exists audit on cma.active_month;
drop trigger if exists audit on cma.active_cohort;

-- A settings change the stored rows depend on marks the tenant's take stale, in the setting's own transaction; it never
-- refreshes there. The refresh that follows (the job's next minute) rewrites the take and clears the mark. Owner's
-- rights with a pinned search path, as 0009e's cma.flash_current_forget: a settings write of any role marks the take
create or replace function cma.active_setting_marks_stale(p_key text)
returns boolean
language sql immutable
as $$
  select p_key like 'attribution.%' or p_key like 'customers.%'
      or p_key in ('crm.customer_segments', 'flash.device_holding_statuses', 'flash.ended_subscription_statuses',
                   'flash.active_subscription_statuses', 'intake.start_date')
$$;

create or replace function cma.active_take_mark_stale()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, cma, pg_temp
as $$
declare
  v_tenant uuid := coalesce(new.tenant_id, old.tenant_id);
  v_key    text := coalesce(new.key, old.key);
begin
  if cma.active_setting_marks_stale(v_key) and (tg_op <> 'UPDATE' or new.value is distinct from old.value) then
    update cma.active_take t set stale = true, stale_since = coalesce(t.stale_since, now()) where t.tenant_id = v_tenant;
  end if;
  return null;
end
$$;
alter function cma.active_take_mark_stale() owner to cma_owner;
revoke execute on function cma.active_take_mark_stale() from public;
drop trigger if exists mark_active_take_stale on cma.tenant_setting;
create trigger mark_active_take_stale after insert or update or delete on cma.tenant_setting
  for each row execute function cma.active_take_mark_stale();

-- The permission of the refresh: the scheduler's system user only, as follow_up.refresh and data_quality.refresh
insert into cma.permission (key, description) values
  ('customers.refresh', 'Recompute the stored take of Customers → Active (the scheduler''s system user only; no default role)')
on conflict (key) do update set description = excluded.description;

-- 0005a's scheduler user, now with its six permissions
-- based on: 168_pledge_lists.sql
create or replace function cma.ensure_scheduler_user(p_tenant_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_role uuid;
  v_user uuid;
begin
  insert into cma.app_role (tenant_id, key, name, is_system, is_assignable)
  values (p_tenant_id, 'scheduler', 'Scheduler', true, false)
  on conflict (tenant_id, key) do update set is_assignable = false, is_system = true
  returning id into v_role;
  if v_role is null then
    select id into v_role from cma.app_role where tenant_id = p_tenant_id and key = 'scheduler';
  end if;
  insert into cma.role_permission (tenant_id, role_id, permission_key)
  values (p_tenant_id, v_role, 'workday.close_forgotten'), (p_tenant_id, v_role, 'follow_up.refresh'), (p_tenant_id, v_role, 'flash.snapshot'),
         (p_tenant_id, v_role, 'data_quality.refresh'), (p_tenant_id, v_role, 'pledges.snapshot'), (p_tenant_id, v_role, 'customers.refresh')
  on conflict do nothing;

  insert into cma.app_user (tenant_id, email, display_name, status, kind)
  values (p_tenant_id, 'scheduler@system.invalid', 'Scheduler', 'active', 'system')
  on conflict (tenant_id, email) do update set kind = 'system', status = 'active'
  returning id into v_user;
  if v_user is null then
    select id into v_user from cma.app_user where tenant_id = p_tenant_id and email = 'scheduler@system.invalid';
  end if;
  insert into cma.user_role (tenant_id, user_id, role_id)
  values (p_tenant_id, v_user, v_role)
  on conflict do nothing;
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
  values (p_tenant_id, v_user, 'scheduler', 'scheduler')
  on conflict do nothing;
  return v_user;
end
$$;
revoke execute on function cma.ensure_scheduler_user(uuid) from public;

do $$
declare
  t record;
begin
  for t in select id from cma.tenant loop
    perform cma.ensure_scheduler_user(t.id);
  end loop;
end
$$;

-- The job refresh_active_customers joins the list, without a connection (as 0008s, 0008zn and 0008zr); sync_run's two
-- constraints come last in this script (section 10: the lock they take is held to the commit)
-- based on: 132_perf.sql
create or replace function cma.job_permission_of(p_job text)
returns text
language sql immutable
as $$
  select case p_job when 'close_forgotten_workdays' then 'workday.close_forgotten' when 'refresh_follow_up' then 'follow_up.refresh'
                    when 'flash_snapshot' then 'flash.snapshot' when 'refresh_data_quality' then 'data_quality.refresh'
                    when 'refresh_active_customers' then 'customers.refresh' end
$$;

-- 0008s's start, its message naming the fifth job
-- based on: 132_perf.sql
create or replace function cma.job_run_start(p_job text)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  if cma.job_permission_of(p_job) is null then
    raise exception 'job must be close_forgotten_workdays, refresh_follow_up, flash_snapshot, refresh_data_quality or refresh_active_customers' using errcode = 'CMA04';
  end if;
  perform cma.assert_permission(cma.job_permission_of(p_job));
  insert into cma.sync_run (tenant_id, connection_id, job, stream, from_at, to_at, started_at)
  values (cma.current_tenant_id(), null, p_job, null, clock_timestamp(), clock_timestamp(), clock_timestamp())
  returning id into v_id;
  return v_id;
end
$$;

create or replace function cma.active_take_lock_key(p_tenant_id uuid)
returns bigint
language sql immutable
as $$
  select hashtextextended(p_tenant_id::text || '/active_take', 0)
$$;

-- The refresh of one tenant's take, in the caller's transaction (the caller's tenant only: row-level security holds every
-- write to it). p_force: also when the take is fresh, and everything is written again. p_now: the moment the take is
-- of (now when left out; a verify script pins it). Answers refreshed (false with the reason fresh, running or not_set_up),
-- the rows written per table and duration_ms. Set-based: the base is read once (cma.active_base_of, First orders'
-- attribution among it) and everything else is computed from the rows just stored.
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
  v_ages   integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'customers.cohort_ages_months'));
  v_every  integer := cma.setting_of(p_tenant_id, 'customers.refresh_minutes')::integer;
  v_attr   date;
  v_take   cma.active_take;
  v_found  boolean;
  v_all    boolean;
  v_key    text;
  n_base   integer := 0;
  n_gone   integer := 0;
  n_cust   integer := 0;
  n_hist   integer := 0;
  n_subs   integer;
  n_active integer;
begin
  if p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a take is refreshed for the current tenant only' using errcode = 'CMA04';
  end if;
  select * into v_take from cma.active_take t where t.tenant_id = p_tenant_id;
  v_found := found;
  if not (coalesce(cma.flash_source_set_up_of(p_tenant_id, 'commerce'), false)
          and coalesce(cma.flash_source_set_up_of(p_tenant_id, 'subscriptions'), false)) then
    -- nothing to take: a tenant whose sources are not set up holds no rows (the page says Not set up, never zeros)
    if v_found then
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
  v_today := (v_now at time zone v_zone)::date;
  v_month := date_trunc('month', v_today)::date;
  v_prev := (v_month - interval '1 month')::date;
  v_year := (v_month - interval '13 months')::date;
  v_attr := (select h.history_start from cma.first_orders_history_start_of(p_tenant_id) h);
  -- everything is written again when asked, on a first take, after a settings change and on a new business date
  v_all := p_force or not v_found or v_take.stale or v_take.business_date is distinct from v_today;

  -- 1. the base, row by row: a row that reads the same is not written again; a subscription no longer in it goes
  with n as materialized (
    select * from cma.active_base_of(p_tenant_id, v_now, true, v_attr, true)
  ), up as (
    insert into cma.active_base as a (tenant_id, subscription_id, connection_id, source_id, store, market, status, is_holding, is_paying,
                                      payment_state, currency, monthly_amount, billing, devices_in_field, started_at, ended_at,
                                      in_history, left_out, customer_id, customer_connection_id, customer_source_id, segment,
                                      crm_connection_id, contact_source_id, customer_start, customer_holding, customer_devices, clv,
                                      clv_currency, channel, level, unknown_reason, first_order_at, device_models)
    select p_tenant_id, n.subscription_id, n.connection_id, n.source_id, n.store, n.market, n.status, n.is_holding, n.is_paying,
           n.payment_state, n.currency, n.monthly_amount, n.billing, n.devices_in_field, n.started_at, n.ended_at,
           n.in_history, n.left_out, n.customer_id, n.customer_connection_id, n.customer_source_id, n.segment,
           n.crm_connection_id, n.contact_source_id, n.customer_start, n.customer_holding, n.customer_devices, n.clv,
           n.clv_currency, n.channel, n.level, n.unknown_reason, n.first_order_at, n.device_models
    from n
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
           coalesce(b.customer_holding, 0) > 0 as is_active, coalesce(b.customer_holding, 0) as holding, coalesce(b.customer_devices, 0) as devices,
           b.clv, b.clv_currency, b.crm_connection_id, b.contact_source_id, a.currency, a.amount, coalesce(oth.j, '{}'::jsonb) as other_amounts
    from b
    left join amt a on a.customer_id = b.customer_id and a.rn = 1
    left join oth on oth.customer_id = b.customer_id
    order by b.customer_id
  ), up as (
    insert into cma.active_customer as a (tenant_id, customer_id, connection_id, source_id, store, market, segment, channel, level, unknown_reason,
                                          first_order_at, customer_start, age_months, is_active, holding, devices, clv, clv_currency,
                                          crm_connection_id, contact_source_id, currency, amount, other_amounts)
    select p_tenant_id, n.customer_id, n.connection_id, n.source_id, n.store, n.market, n.segment, n.channel, n.level,
           n.unknown_reason, n.first_order_at, n.customer_start, n.age_months, n.is_active, n.holding, n.devices, n.clv,
           n.clv_currency, n.crm_connection_id, n.contact_source_id, n.currency, n.amount, n.other_amounts
    from n
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
  end if;

  select count(*) filter (where b.is_holding), count(distinct b.customer_id) filter (where coalesce(b.customer_holding, 0) > 0)
  into n_subs, n_active
  from cma.active_base b where b.tenant_id = p_tenant_id;
  insert into cma.active_take as t (tenant_id, computed_at, business_date, duration_ms, history_key, customers, subscriptions, attribution_start, stale, stale_since)
  values (p_tenant_id, v_now, v_today, (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer, v_key, n_active, n_subs, v_attr, false, null)
  on conflict (tenant_id) do update
    set computed_at = excluded.computed_at, business_date = excluded.business_date, duration_ms = excluded.duration_ms,
        history_key = excluded.history_key, customers = excluded.customers, subscriptions = excluded.subscriptions,
        attribution_start = excluded.attribution_start, stale = false, stale_since = null;
  return jsonb_build_object('refreshed', true, 'base_rows', n_base + n_gone, 'customer_rows', n_cust, 'history_rows', n_hist,
                            'rows', n_base + n_gone + n_cust + n_hist,
                            'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
end
$$;
alter function cma.active_refresh_of(uuid, boolean, timestamptz) set jit = off;

-- The job's entry: the scheduler's system user (customers.refresh) refreshes the current tenant
create or replace function cma.active_refresh()
returns jsonb
language plpgsql
as $$
begin
  perform cma.assert_permission('customers.refresh');
  return cma.active_refresh_of(cma.current_tenant_id());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Customers → Active in three reads (decision D15): above the fold, below it, and the list (section 6)
-- ---------------------------------------------------------------------------------------------
-- The present, live (decisions D2 and D13): the subscriptions in a device-holding status, each with its amount turned
-- into a month, its store's market and Flash's own figures of its store customer (cma.flash_customer_figures_of: the
-- customer, its segment and whether it is an Active customer). No event, no device and no attribution is read: those are
-- the take's. A subscription whose customer the store does not hold has no customer and the segment unknown
create or replace function cma.active_present_of(p_tenant_id uuid)
returns table (subscription_id uuid, status text, is_paying boolean, currency text, monthly_amount numeric, customer_id uuid,
               is_active boolean, market text, segment text)
language sql stable
rows 10000
as $$
  with s as materialized (
    select cma.flash_holding_statuses_of(p_tenant_id) as holding, cma.flash_active_statuses_of(p_tenant_id) as paying
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  ), s0 as materialized (
    select x.id, x.connection_id, x.customer_source_id, x.status, x.currency,
           x.amount_per_cycle * cma.active_month_factor_of(x.billing_interval, x.billing_interval_count) as monthly_amount,
           x.status = any ((select s.paying from s)::text[]) as is_paying
    from cma.subscription x
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.status = any ((select s.holding from s)::text[])
  ), cust as materialized (
    -- the store customers of these subscriptions
    select distinct c.id
    from s0 x
    join sm on sm.connection_id = x.connection_id
    join cma.commerce_customer c
      on c.tenant_id = p_tenant_id and c.connection_id = sm.store_connection_id and c.source_id = x.customer_source_id
     and c.source_deleted_at is null
  ), fig as materialized (
    -- Flash's own figures of these customers (D2), read through the customers' primary key: the function is inlined and
    -- the ids reach its scan of the store's customers (as cma.active_base_of reads it)
    select f.customer_id, f.connection_id, f.source_id, f.segment, f.holding_subscriptions
    from cma.flash_customer_figures_of(p_tenant_id) f
    where f.customer_id = any (array(select cust.id from cust))
  )
  select x.id, x.status, x.is_paying, x.currency, x.monthly_amount, f.customer_id, coalesce(f.holding_subscriptions, 0) > 0,
         coalesce(sm.market, 'unknown'), coalesce(f.segment, 'unknown')
  from s0 x
  left join sm on sm.connection_id = x.connection_id
  left join fig f on f.connection_id = sm.store_connection_id and f.source_id = x.customer_source_id
$$;
alter function cma.active_present_of(uuid) set jit = off;

-- A tenant's take as the page states it: when it was computed (History as of), whether a settings change marked it stale,
-- its age in whole minutes and whether the page says so (late: stale, or older than customers.history_notice_minutes);
-- null while there is none yet (the page says the history is being prepared, never zeros)
create or replace function cma.active_take_of(p_tenant_id uuid, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_take jsonb;
begin
  -- plpgsql, not SQL: its statement is planned again when the role changes (a take is read under row-level security)
  select jsonb_build_object(
           'computed_at', t.computed_at, 'business_date', t.business_date, 'stale', t.stale,
           'age_minutes', greatest(0, floor(extract(epoch from p_now - t.computed_at) / 60))::integer,
           'late', t.stale or p_now - t.computed_at
                              > make_interval(mins => cma.setting_of(p_tenant_id, 'customers.history_notice_minutes')::integer))
  into v_take
  from cma.active_take t where t.tenant_id = p_tenant_id;
  return v_take;
end
$$;

-- Above the fold: the headline tiles, the unit economics' one figure and the hero series. The present is live (the
-- tiles' own figures: cma.active_present_of, which reads Flash's customer figures); Flash's churn count, what a tile
-- compares with, the Customer age, the Customer lifetime, the realised value and the series' past month ends are the
-- stored take's. Without a take yet the present is still answered and the take's parts are null (history false)
create or replace function cma.active_top_of(p_tenant_id uuid, p_from_month date, p_market text, p_segment text, p_channel text,
                                             p_now timestamptz)
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
  v_from         date;
  v_head         jsonb;
  v_doc          jsonb;
  v_commerce     boolean := coalesce(cma.flash_source_set_up_of(p_tenant_id, 'commerce'), false);
  v_subs         boolean := coalesce(cma.flash_source_set_up_of(p_tenant_id, 'subscriptions'), false);
  v_take         jsonb := cma.active_take_of(p_tenant_id, p_now);
  v_has          boolean;
  v_attr         date := (select t.attribution_start from cma.active_take t where t.tenant_id = p_tenant_id);
begin
  v_has := v_take is not null;
  v_today := (p_now at time zone v_zone)::date;
  v_month := date_trunc('month', v_today)::date;
  v_prev := (v_month - interval '1 month')::date;
  v_year := (v_month - interval '13 months')::date;
  -- the history's first month: the one asked for, never before customers.history_months back, never after this month
  v_from := least(v_month, greatest(coalesce(p_from_month, date '0001-01-01'), (v_month - make_interval(months => v_hist))::date));
  v_head := jsonb_build_object(
    'set_up', jsonb_build_object('commerce', v_commerce, 'subscriptions', v_subs),
    'computed_at', p_now, 'time_zone', v_zone, 'today', v_today, 'month', v_month, 'from_month', v_from,
    'take', v_take, 'history', v_has,
    'filter', jsonb_build_object('market', p_market, 'segment', p_segment, 'channel', p_channel),
    'settings', jsonb_build_object('cohort_ages_months', to_jsonb(v_ages), 'age_months', to_jsonb(v_bands), 'history_months', v_hist,
                                   'fx', case when v_fx = '{}'::jsonb then null else v_fx end, 'segments', to_jsonb(v_segments),
                                   'statuses', cma.flash_status_settings_of(p_tenant_id),
                                   'attribution', jsonb_build_object(
                                     'assisted_levels', to_jsonb(coalesce(string_to_array(nullif(cma.setting_of(p_tenant_id, 'attribution.assisted_levels'), ''), ','), '{}'::text[])),
                                     'history_start', case when v_has then v_attr
                                                           else (select h.history_start from cma.first_orders_history_start_of(p_tenant_id) h) end)));
  if not (v_commerce and v_subs) then
    return v_head || jsonb_build_object('figures', false);
  end if;

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
  ), ms as materialized (
    -- the subscriptions holding at each month end, by the reconstruction
    select x.month, sum(x.at_end) as at_end
    from mcell x
    where x.kind = 'subscriptions' and x.month >= (select min(y.month) from mcell y where y.kind = 'subscriptions' and y.inflow <> 0)
    group by 1
  ), ma as materialized (
    -- the Monthly recurring amount per month end and currency
    select x.month, x.currency, sum(x.at_end) as at_end
    from mcell x
    where x.kind = 'amount' and x.month >= (select min(y.month) from mcell y where y.kind = 'amount' and (y.inflow <> 0 or y.at_end <> 0))
    group by 1, 2
  ), mk as materialized (
    -- the customers with a subscription in a currency at the two month ends a change line compares with
    select x.month, x.currency, sum(x.at_end) as at_end
    from mcell x
    where x.kind = 'currency_customers' and x.month in (v_prev, v_year)
    group by 1, 2
  ), mt as materialized (
    select mc.month, sum(mc.at_end) as customers, sum(mc.inflow) as inflow, sum(mc.outflow) as outflow from mc group by 1
  ), mseg as (
    select q.month, jsonb_object_agg(q.segment, q.n) as j
    from (select mc.month, mc.segment, sum(mc.at_end) as n from mc group by 1, 2) q group by 1
  ), mam as (
    select ma.month, jsonb_object_agg(ma.currency, round(ma.at_end, 2)) as j,
           bool_and(ma.currency = 'EUR' or coalesce(jsonb_typeof(v_fx -> ma.currency) = 'number', false)) as fx_ok,
           round(sum(cma.active_eur_of(ma.at_end, ma.currency, v_fx)), 2) as eur
    from ma group by 1
  ), ch as materialized (
    -- Flash's Churn (subscription) over the 30 business dates to the take's, as the refresh stored it per market, segment and channel
    select x.market, x.at_end as n
    from mcell x
    where x.kind = 'churned_30d'
  ), lp as materialized (
    -- the present, live (decision D2): the subscriptions in a device-holding status with Flash's own figures of their customer
    select * from cma.active_present_of(p_tenant_id)
  ), lb as materialized (
    -- under the filters; a customer's acquisition channel is the stored take's (unknown until the take holds the customer)
    select x.subscription_id, x.status, x.is_paying, x.currency, x.monthly_amount, x.customer_id, x.is_active, x.market, x.segment,
           coalesce(k.channel, 'unknown') as channel
    from lp x
    left join cma.active_customer k on k.tenant_id = p_tenant_id and k.customer_id = x.customer_id
    where (p_market is null or x.market = p_market) and (p_segment is null or x.segment = p_segment)
      and (p_channel is null or coalesce(k.channel, 'unknown') = p_channel)
  ), lc as materialized (
    -- the active customers, one row each (a customer's subscriptions share its segment and channel)
    select lb.customer_id, min(lb.segment) as segment, min(lb.channel) as channel
    from lb where lb.customer_id is not null and lb.is_active
    group by lb.customer_id
  ), l_amt as materialized (
    select lb.currency, sum(lb.monthly_amount) filter (where lb.is_paying) as amount, count(distinct lb.customer_id) as customers
    from lb where lb.currency is not null
    group by 1
  ), l_now as materialized (
    select (select count(*) from lc) as customers, (select count(*) from lb) as subscriptions,
           (select coalesce(jsonb_object_agg(q.segment, q.n), '{}'::jsonb) from (select lc.segment, count(*) as n from lc group by 1) q) as by_segment
  ), g_all as materialized (
    -- the stored take's active customers over all: how many, their median age and those older than the first three bounds
    select count(*) as customers, percentile_cont(0.5) within group (order by c.age) as median_age,
           count(*) filter (where c.age >= v_bands[1]) as over1, count(*) filter (where c.age >= v_bands[2]) as over2,
           count(*) filter (where c.age >= v_bands[3]) as over3
    from c where c.is_active
  ), clv_all as materialized (
    select jsonb_object_agg(q.currency, jsonb_build_object('average', q.average, 'median', q.median, 'per_month', q.per_month, 'customers', q.n)) as j
    from (select c.clv_currency as currency, count(*) as n, round(avg(c.clv), 2) as average,
                 round((percentile_cont(0.5) within group (order by c.clv))::numeric, 2) as median,
                 round(avg(c.clv / greatest(c.age, 1)), 2) as per_month
          from c where c.is_active and c.clv is not null and c.clv_currency is not null
          group by c.clv_currency) q
  ), km_all as materialized (
    select cma.active_km_json(array_agg(sp.len), array_agg(sp.ended)) as j from sp
  )
  select jsonb_build_object(
    'figures', true,
    'filters', jsonb_build_object(
      'markets', (select coalesce(jsonb_agg(q.market order by q.market = 'unknown', q.market), '[]'::jsonb)
                  from (select distinct lb0.market from lp lb0
                        union select st.market from cma.commerce_store st where st.tenant_id = p_tenant_id
                        union select distinct x.market from cma.active_customer x where x.tenant_id = p_tenant_id) q),
      'segments', to_jsonb(v_segments || array['unknown']),
      'channels', '["indirect", "direct", "unknown"]'::jsonb),
    'tiles', jsonb_build_object(
      'active_customers', jsonb_build_object(
        'value', (select n.customers from l_now n),
        'by_segment', (select n.by_segment from l_now n),
        'by_channel', (select jsonb_build_object('indirect', count(*) filter (where lc.channel = 'indirect'),
                                                 'direct', count(*) filter (where lc.channel = 'direct'),
                                                 'unknown', count(*) filter (where lc.channel = 'unknown')) from lc),
        'prev_month', (select mt.customers from mt where mt.month = v_prev),
        'prev_year', (select mt.customers from mt where mt.month = v_year)),
      'total_subscriptions', jsonb_build_object(
        'value', (select n.subscriptions from l_now n),
        'by_status', (select coalesce(jsonb_object_agg(q.status, q.n), '{}'::jsonb)
                      from (select lb.status, count(*) as n from lb group by 1) q),
        'prev_month', (select ms.at_end from ms where ms.month = v_prev),
        'prev_year', (select ms.at_end from ms where ms.month = v_year)),
      'amounts', (select coalesce(jsonb_agg(jsonb_build_object(
                           'currency', a.currency, 'amount', round(coalesce(a.amount, 0), 2), 'customers', a.customers,
                           'average', case when a.customers > 0 then round(coalesce(a.amount, 0) / a.customers, 2) end,
                           'prev_month', (select round(ma.at_end, 2) from ma where ma.month = v_prev and ma.currency = a.currency),
                           'prev_year', (select round(ma.at_end, 2) from ma where ma.month = v_year and ma.currency = a.currency),
                           'average_prev_month', (select case when mk.at_end > 0 then round(ma.at_end / mk.at_end, 2) end
                                                  from ma join mk on mk.month = ma.month and mk.currency = ma.currency
                                                  where ma.month = v_prev and ma.currency = a.currency),
                           'average_prev_year', (select case when mk.at_end > 0 then round(ma.at_end / mk.at_end, 2) end
                                                 from ma join mk on mk.month = ma.month and mk.currency = ma.currency
                                                 where ma.month = v_year and ma.currency = a.currency)) order by a.currency), '[]'::jsonb)
                  from l_amt a),
      'eur', (select case when v_fx <> '{}'::jsonb and count(*) > 0
                               and bool_and(q.currency = 'EUR' or coalesce(jsonb_typeof(v_fx -> q.currency) = 'number', false))
                          then jsonb_build_object(
                                 'amount', round(sum(cma.active_eur_of(q.amount, q.currency, v_fx)), 2), 'as_of', v_fx ->> 'as_of',
                                 'prev_month', (select case when m.fx_ok then m.eur end from mam m where m.month = v_prev),
                                 'prev_year', (select case when m.fx_ok then m.eur end from mam m where m.month = v_year)) end
              from l_amt q),
      'customer_age', case when v_has then
                      (select jsonb_build_object(
                         'median', round(g.median_age::numeric, 1),
                         'over', (select coalesce(jsonb_agg(jsonb_build_object('months', x.m, 'customers', x.n,
                                                                             'share', case when g.customers > 0 then round(x.n::numeric / g.customers, 4) end)
                                                           order by x.m), '[]'::jsonb)
                                  from (values (v_bands[1], g.over1), (v_bands[2], g.over2), (v_bands[3], g.over3)) x(m, n) where x.m is not null),
                         -- the ages at a past month's end, as cma.flash_age_months_of counts them, from the Customer start's stored date
                         'prev_month', (select round((percentile_cont(0.5) within group (
                                                        order by (extract(year from a.g) * 12 + extract(month from a.g))::integer))::numeric, 1)
                                        from sp
                                        cross join lateral (select age((v_month - 1)::timestamp, sp.customer_start_on::timestamp) as g) a
                                        where sp.spell_start < (v_month::timestamp at time zone v_zone)
                                          and (sp.spell_end is null or sp.spell_end >= (v_month::timestamp at time zone v_zone))
                                          and exists (select 1 from mt where mt.month = v_prev)),
                         'prev_year', (select round((percentile_cont(0.5) within group (
                                                       order by (extract(year from a.g) * 12 + extract(month from a.g))::integer))::numeric, 1)
                                       from sp
                                       cross join lateral (select age(((v_year + interval '1 month')::date - 1)::timestamp, sp.customer_start_on::timestamp) as g) a
                                       where sp.spell_start < ((v_year + interval '1 month')::timestamp at time zone v_zone)
                                         and (sp.spell_end is null or sp.spell_end >= ((v_year + interval '1 month')::timestamp at time zone v_zone))
                                         and exists (select 1 from mt where mt.month = v_year)))
                       from g_all g) end,
      'lifetime', case when v_has then (select k.j - 'curve' from km_all k) end,
      'clv', case when v_has then coalesce((select g.j from clv_all g), '{}'::jsonb) end),
    'unit_economics', jsonb_build_object(
      'churned_30d', (select coalesce(sum(ch.n), 0) from ch),
      'slots', (select jsonb_agg(jsonb_build_object('key', x.key, 'status', 'pending') order by x.ord)
                from (values ('churn_rate', 1), ('cac', 2), ('cost_per_subscription', 3), ('clv_projected', 4), ('clv_to_cac', 5),
                             ('payback_months', 6)) x(key, ord))),
    'months', (select coalesce(jsonb_agg(jsonb_build_object(
                        'month', mt.month, 'is_now', mt.month = v_month,
                        'customers', case when mt.month = v_month then (select n.customers from l_now n) else mt.customers end,
                        'by_segment', case when mt.month = v_month then (select n.by_segment from l_now n) else coalesce(mseg.j, '{}'::jsonb) end,
                        'subscriptions', case when mt.month = v_month then (select n.subscriptions from l_now n)::numeric else coalesce(ms.at_end, 0) end)
                        order by mt.month), '[]'::jsonb)
               from mt
               left join mseg on mseg.month = mt.month
               left join ms on ms.month = mt.month
               where mt.month >= v_from),
    'notes', case when v_has then jsonb_build_object(
      'no_ended_time', (select count(*) from b where b.left_out = 'no_ended_time'),
      'no_created_time', (select count(*) from b where b.left_out = 'no_created_time'),
      'unmatched_subscriptions', (select count(*) from b where b.is_holding and b.customer_id is null),
      'reconstruction_gap', coalesce((select mt.customers from mt where mt.month = v_month), 0) - (select n.customers from l_now n),
      'history_starts', (select coalesce(jsonb_agg(jsonb_build_object('store', q.store, 'market', q.market, 'date', q.d) order by q.d, q.store), '[]'::jsonb)
                         from (select b.store, b.market, (min(b.started_at) at time zone v_zone)::date as d
                               from b where b.started_at is not null group by 1, 2) q)) end)
  into v_doc;
  return v_head || v_doc;
end
$$;
-- JIT off (as cma.courtesy_page_of, 150): the statement is one of many small joins and aggregates, and a session's first
-- compiled call costs more than the read
alter function cma.active_top_of(uuid, date, text, text, text, timestamptz) set jit = off;

-- Below the fold, from the stored take alone: inflow and outflow and the Monthly recurring amount per month end, the
-- markets, the two segments compared, the survival curves, the Customer age bands, the customer cohorts, the
-- subscription mix and the notes that go with them; nothing live. Without a take: history false and nothing else (the page says the history is being prepared)
create or replace function cma.active_rest_of(p_tenant_id uuid, p_from_month date, p_market text, p_segment text, p_channel text,
                                              p_grouping text, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone         text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_today        date;
  v_month        date;
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
  v_take         jsonb := cma.active_take_of(p_tenant_id, p_now);
  v_attr         date := (select t.attribution_start from cma.active_take t where t.tenant_id = p_tenant_id);
begin
  v_today := (p_now at time zone v_zone)::date;
  v_month := date_trunc('month', v_today)::date;
  v_from := least(v_month, greatest(coalesce(p_from_month, date '0001-01-01'), (v_month - make_interval(months => v_hist))::date));
  -- the settings ride with this read too (as the top's), so the panels below the fold wait for one read alone
  v_head := jsonb_build_object(
    'set_up', jsonb_build_object('commerce', v_commerce, 'subscriptions', v_subs),
    'take', v_take, 'history', v_take is not null, 'month', v_month, 'from_month', v_from, 'grouping', p_grouping,
    'settings', jsonb_build_object('cohort_ages_months', to_jsonb(v_ages), 'age_months', to_jsonb(v_bands), 'history_months', v_hist,
                                   'fx', case when v_fx = '{}'::jsonb then null else v_fx end, 'segments', to_jsonb(v_segments),
                                   'statuses', cma.flash_status_settings_of(p_tenant_id),
                                   'attribution', jsonb_build_object(
                                     'assisted_levels', to_jsonb(coalesce(string_to_array(nullif(cma.setting_of(p_tenant_id, 'attribution.assisted_levels'), ''), ','), '{}'::text[])),
                                     'history_start', v_attr)));
  if not (v_commerce and v_subs) then
    return v_head || jsonb_build_object('figures', false);
  end if;
  if v_take is null then
    return v_head || jsonb_build_object('figures', true);
  end if;

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
  ), cc as materialized (
    select x.cohort, x.segment, x.channel, x.age_months, x.started, x.still_active, x.mature
    from cma.active_cohort x
    where x.tenant_id = p_tenant_id and x.period = p_grouping and (p_market is null or x.market = p_market) and (p_segment is null or x.segment = p_segment)
      and (p_channel is null or x.channel = p_channel)
      and x.cohort >= date_trunc(p_grouping, v_from::timestamp)::date
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
    'age_over', (select coalesce(jsonb_agg(jsonb_build_object('months', x.m, 'customers', x.n,
                                                           'share', case when g.customers > 0 then round(x.n::numeric / g.customers, 4) end)
                                         order by x.m), '[]'::jsonb)
                 from g_c g
                 cross join lateral (values (v_bands[1], g.over1), (v_bands[2], g.over2), (v_bands[3], g.over3)) x(m, n)
                 where g.dim = 'all' and x.m is not null),
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
                          group by 1) q)),
      'dominant_cohort', (select jsonb_build_object('cohort', co.cohort, 'share', round(co.started / (select sum(x.started) from co x), 4))
                          from co
                          where (select sum(x.started) from co x) > 0 and co.started / (select sum(x.started) from co x) > 0.4
                          order by co.started desc limit 1)))
  into v_doc;
  return v_head || v_doc;
end
$$;
alter function cma.active_rest_of(uuid, date, text, text, text, text, timestamptz) set jit = off;

-- The markets of the tenant's stores, for the page's market filter: a tenant catalog (the web keeps it in its per-instance
-- cache), so the page's frame is drawn without reading a figure (decision D15). reports.view or performance.team
create or replace function cma.active_markets()
returns text[]
language plpgsql stable
as $$
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  return coalesce((select array_agg(distinct st.market order by st.market) from cma.commerce_store st where st.tenant_id = cma.current_tenant_id()),
                  '{}'::text[]);
end
$$;

-- The page's two reads of the report (reports.view or performance.team, CMA06), each its own transaction. p_from_month
-- the history's first month (a month's first day; null: as far back as customers.history_months allows, which also caps
-- an earlier one), p_market a market's code or unknown, p_segment a segment's code or unknown, p_channel indirect, direct
-- or unknown, p_grouping month or quarter (the customer cohorts); anything else CMA04. Team figures only
create or replace function cma.active_top(p_from_month date default null, p_market text default null, p_segment text default null,
                                          p_channel text default null)
returns jsonb
language plpgsql stable
as $$
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_active_filter(p_market, p_segment, p_channel);
  if p_from_month is not null and p_from_month <> date_trunc('month', p_from_month)::date then
    raise exception 'the history starts on the first day of a month' using errcode = 'CMA04';
  end if;
  return cma.active_top_of(cma.current_tenant_id(), p_from_month, p_market, p_segment, p_channel, now());
end
$$;

create or replace function cma.active_rest(p_from_month date default null, p_market text default null, p_segment text default null,
                                           p_channel text default null, p_grouping text default 'month')
returns jsonb
language plpgsql stable
as $$
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_active_filter(p_market, p_segment, p_channel);
  if p_from_month is not null and p_from_month <> date_trunc('month', p_from_month)::date then
    raise exception 'the history starts on the first day of a month' using errcode = 'CMA04';
  end if;
  if p_grouping is null or p_grouping not in ('month', 'quarter') then
    raise exception 'the cohorts are grouped by month or quarter' using errcode = 'CMA04';
  end if;
  return cma.active_rest_of(cma.current_tenant_id(), p_from_month, p_market, p_segment, p_channel, p_grouping, now());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The customer list, its file's record
-- ---------------------------------------------------------------------------------------------
-- The active customers under the page's filters, one page of them, from the stored take (cma.active_customer): total
-- (the customers there are) and rows, each the store customer's id, its store, market, segment, acquisition channel with
-- its level, Customer start and age, its subscriptions and devices, its Monthly recurring amount in its largest
-- currency (the others beside it), its realised value and the contact's id and link; ids, codes, dates and amounts only.
-- Keyset paging: the rows after (p_after) or before (p_before) a row's cursor in the sort's order, read through the
-- index of the sort key (never an offset); next and prev are the cursors of the page's ends where there is more. A sort
-- key orders by its value and then by the store customer's id; the amounts sort within their currency (a customer
-- without an amount as the smallest). Only the worst Payment state is read live, for the page's customers alone
create or replace function cma.active_rows_of(p_tenant_id uuid, p_market text, p_segment text, p_channel text, p_sort text,
                                              p_descending boolean, p_after text, p_before text, p_limit integer, p_now timestamptz)
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
begin
  if not (coalesce(cma.flash_source_set_up_of(p_tenant_id, 'commerce'), false)
          and coalesce(cma.flash_source_set_up_of(p_tenant_id, 'subscriptions'), false)) then
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
  -- a cursor is a row's key as this function wrote it: the sort's values, the store customer's id and the customer's id
  if p_after is not null or p_before is not null then
    begin
      v_cursor := convert_from(decode(coalesce(p_after, p_before), 'base64'), 'UTF8')::jsonb;
      if jsonb_typeof(v_cursor -> 'k') <> 'array' or jsonb_array_length(v_cursor -> 'k') <> cardinality(v_keys)
         or (v_cursor ->> 's') is null or (v_cursor ->> 'i')::uuid is null then
        raise exception 'bad cursor';
      end if;
    exception when others then
      raise exception 'a cursor is the next or prev of a page of this list in this sort' using errcode = 'CMA04';
    end;
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
      select c.*, row_number() over (order by %3$s) as pos,
             jsonb_build_object('k', jsonb_build_array(%1$s), 's', c.source_id, 'i', c.customer_id) as cur
      from cma.active_customer c
      where c.tenant_id = $1 and c.is_active
        and ($2::text is null or c.market = $2) and ($3::text is null or c.segment = $3) and ($4::text is null or c.channel = $4)%2$s
      order by %3$s
      limit $5 + 1
    ), ps as (
      -- the worst payment state of each customer on the page: its subscriptions' states, read live for these alone
      select b.customer_id,
             (array['failed', 'in_retry', 'paused', 'paid'])[min(array_position(array['failed', 'in_retry', 'paused', 'paid'], p.payment_state))] as worst
      from cma.active_base b
      join cma.subscription_payment_state_of($1, array(select b2.subscription_id from cma.active_base b2
                                                       where b2.tenant_id = $1 and b2.customer_id in (select page.customer_id from page))) p
        on p.subscription_id = b.subscription_id
      where b.tenant_id = $1 and b.customer_id in (select page.customer_id from page)
      group by 1
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'store_customer', page.source_id, 'store', page.store, 'market', page.market, 'segment', page.segment,
             'customer_start', (page.customer_start at time zone $7)::date, 'age_months', page.age_months,
             'subscriptions', page.holding, 'devices', page.devices, 'currency', page.currency,
             'monthly_amount', round(page.amount, 2), 'other_amounts', page.other_amounts,
             'clv', page.clv, 'clv_currency', page.clv_currency, 'payment_state', ps.worst, 'channel', page.channel, 'level', page.level,
             'contact_id', page.contact_source_id,
             'contact_url', cma.record_url(page.crm_connection_id, 'contact', page.contact_source_id),
             'cursor', translate(encode(convert_to(page.cur::text, 'UTF8'), 'base64'), E'\n', '')) order by page.pos), '[]'::jsonb)
    from page left join ps on ps.customer_id = page.customer_id
  $q$, array_to_string(v_keys, ', '), v_at, v_order)
    into v_rows
    using p_tenant_id, p_market, p_segment, p_channel, p_limit, v_cursor, v_zone;
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
    and (p_market is null or c.market = p_market) and (p_segment is null or c.segment = p_segment) and (p_channel is null or c.channel = p_channel);
  i := jsonb_array_length(v_rows);
  return jsonb_build_object(
    'set_up', true, 'history', true, 'take', v_take, 'as_of', v_take -> 'computed_at', 'time_zone', v_zone, 'total', v_total,
    'next', case when i > 0 and (v_back or v_more) then v_rows -> (i - 1) -> 'cursor' end,
    'prev', case when i > 0 and ((not v_back and v_cursor is not null) or (v_back and v_more)) then v_rows -> 0 -> 'cursor' end,
    'rows', (select coalesce(jsonb_agg(e.value - 'cursor' order by e.ord), '[]'::jsonb) from jsonb_array_elements(v_rows) with ordinality e(value, ord)));
end
$fn$;
alter function cma.active_rows_of(uuid, text, text, text, text, boolean, text, text, integer, timestamptz) set jit = off;

-- The list's page (reports.view or performance.team, CMA06): the filters of the page's reads, a sort key of the list
-- (monthly_amount when left out, descending), the cursor of the row to continue after (p_after, a page's next) or to end
-- before (p_before, a page's prev), never both, and a limit from 1 to 200; for a file (p_file) no cursor and the limit
-- the tenant's flash.file_max_rows. Anything else CMA04
create or replace function cma.active_rows(p_market text default null, p_segment text default null, p_channel text default null,
                                           p_sort text default 'monthly_amount', p_descending boolean default true, p_after text default null,
                                           p_before text default null, p_limit integer default 50, p_file boolean default false)
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
  if p_after is not null and p_before is not null then
    raise exception 'a page continues after a cursor or ends before one, not both' using errcode = 'CMA04';
  end if;
  if coalesce(length(p_after), 0) > 600 or coalesce(length(p_before), 0) > 600 then
    raise exception 'a cursor is the next or prev of a page of this list in this sort' using errcode = 'CMA04';
  end if;
  if coalesce(p_file, false) then
    if p_after is not null or p_before is not null then
      raise exception 'a file takes no cursor' using errcode = 'CMA04';
    end if;
    return cma.active_rows_of(v_tenant, p_market, p_segment, p_channel, p_sort, coalesce(p_descending, true), null, null,
                              cma.setting_of(v_tenant, 'flash.file_max_rows')::integer, now());
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'a list page holds 1 to 200 rows' using errcode = 'CMA04';
  end if;
  return cma.active_rows_of(v_tenant, p_market, p_segment, p_channel, p_sort, coalesce(p_descending, true), p_after, p_before, p_limit, now());
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
-- 7. The month ends and the customer cohorts computed afresh, and the readers' views of the stored ones
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

-- For readers (BigQuery, analytics): plain views of the stored take (as cma_read.flash_current_take, 158), each tenant
-- the reader sees: counts per month, market, segment and acquisition channel, and per customer cohort; no customer, no
-- contact and no attribution level. The two functions above stay the fresh computation the stored rows are verified
-- against (173)
create or replace view cma_read.active_customer_month as
  select m.tenant_id, m.month, m.market, m.segment, m.channel as acquisition_channel,
         coalesce(sum(m.at_end) filter (where m.kind = 'customers'), 0)::bigint as active_customers,
         coalesce(sum(m.at_end) filter (where m.kind = 'subscriptions'), 0)::bigint as holding_subscriptions,
         coalesce(sum(m.inflow) filter (where m.kind = 'customers'), 0)::bigint as inflow,
         coalesce(sum(m.outflow) filter (where m.kind = 'customers'), 0)::bigint as outflow
  from cma.active_month m
  where m.kind in ('customers', 'subscriptions') and cma_read.reader_sees(m.tenant_id)
  group by m.tenant_id, m.month, m.market, m.segment, m.channel;
comment on view cma_read.active_customer_month is
  'Per tenant, calendar month (the tenant''s zone), market, customer segment and acquisition channel (0009l): the active customers and the holding subscriptions at the month''s end as reconstructed from the subscriptions'' created and ended times (the running month as of now; a past pause counts as holding), and the customers'' inflow and outflow of the month (active spells starting and ending). Counts only: no customer and no contact';

create or replace view cma_read.customer_cohort as
  select h.tenant_id, h.cohort, h.period as grouping, h.market, h.segment, h.channel as acquisition_channel, h.started, h.age_months,
         h.still_active, h.mature
  from cma.active_cohort h
  where cma_read.reader_sees(h.tenant_id);
comment on view cma_read.customer_cohort is
  'Per tenant, customer cohort (the first day of the month or quarter of the Customer start, see grouping), market, customer segment, acquisition channel and age in months of customers.cohort_ages_months (0009l): the customers started, those still in an active spell at their own start plus the age, and whether every customer of the row is that old (mature; until then still_active counts those who are). Counts only: no customer and no contact';

-- ---------------------------------------------------------------------------------------------
-- 8. Grants: the application only (a function made again keeps its grants)
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
    'cma.assert_active_filter(text,text,text)', 'cma.active_setting_marks_stale(text)', 'cma.active_take_lock_key(uuid)',
    'cma.active_refresh_of(uuid,boolean,timestamptz)', 'cma.active_refresh()', 'cma.active_present_of(uuid)', 'cma.active_take_of(uuid,timestamptz)',
    'cma.active_top_of(uuid,date,text,text,text,timestamptz)', 'cma.active_top(date,text,text,text)',
    'cma.active_rest_of(uuid,date,text,text,text,text,timestamptz)', 'cma.active_rest(date,text,text,text,text)', 'cma.active_markets()',
    'cma.active_rows_of(uuid,text,text,text,text,boolean,text,text,integer,timestamptz)',
    'cma.active_rows(text,text,text,text,boolean,text,text,integer,boolean)', 'cma.active_file_record(text,text,text,integer)',
    'cma.active_months_of(uuid,timestamptz)', 'cma.active_cohorts_of(uuid,text,timestamptz)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. sync_run's constraints, last: the lock they take is held to the commit
-- ---------------------------------------------------------------------------------------------
-- The job refresh_active_customers joins the list, without a connection (as 132's section 10). An alter table that adds
-- a constraint takes an ACCESS EXCLUSIVE lock on cma.sync_run that the transaction keeps until it commits: placed here,
-- directly before the record and the commit, the lock lasts the two validations alone (CLAUDE.md, Performance).
-- cma.job_run_start('refresh_active_customers') is only ever called after the commit (the job's first run)
alter table cma.sync_run drop constraint if exists sync_run_job_check;
alter table cma.sync_run add constraint sync_run_job_check
  check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls', 'email_poll', 'close_forgotten_workdays',
                 'refresh_follow_up', 'reviews_poll', 'legacy_call_import', 'assets_import', 'assets_poll', 'subscriptions_poll',
                 'flash_snapshot', 'refresh_data_quality', 'refresh_active_customers')) not valid;
alter table cma.sync_run validate constraint sync_run_job_check;
alter table cma.sync_run drop constraint if exists sync_run_connection_check;
alter table cma.sync_run add constraint sync_run_connection_check
  check ((connection_id is null) = (job in ('close_forgotten_workdays', 'refresh_follow_up', 'flash_snapshot', 'refresh_data_quality',
                                            'refresh_active_customers'))) not valid;
alter table cma.sync_run validate constraint sync_run_connection_check;

-- ---------------------------------------------------------------------------------------------
-- ---------------------------------------------------------------------------------------------
-- 10. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009l', 'Customers → Active: the settings customers.cohort_ages_months (3,6,12,24,36), customers.age_months (12,24,36,48,60), customers.history_months (60), customers.refresh_minutes (5), customers.history_notice_minutes (15) and reports.fx_eur_rates ({}), checked by cma.check_tenant_setting(); the pure functions cma.active_spells_from, cma.active_month_cube_from, cma.active_cohort_cube_from and cma.active_km_from; the fresh reads cma.active_base_of and its wrappers; the stored take in cma.active_take, cma.active_base, cma.active_customer, cma.active_spell, cma.active_month and cma.active_cohort, refreshed by cma.active_refresh() (customers.refresh, the job refresh_active_customers) and marked stale by a change of a setting it depends on; the page in three reads, cma.active_top (the live present with the take''s history), cma.active_rest (the take alone) and cma.active_rows (keyset paging), with cma.active_markets and cma.active_file_record; the readers'' views cma_read.active_customer_month and cma_read.customer_cohort over the stored take')
on conflict (version) do nothing;

commit;
reset role;
