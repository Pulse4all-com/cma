-- =============================================================================================
-- 210_subscription_facts.sql: addition 0009ze, the subscription facts (brief B39 continued, Part B39c): the variant
-- mapping and device units, the payment state's second version (Charged back, Awaiting payment), renewal outcomes,
-- recurring amount movements, the churn rate and the failed rate, renewal survival, the original start (estimated) and
-- the device check, stored in takes the minute job refreshes
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 206_subscription_full_read_guard.sql (0009zc); 208/209 (0009zd, brief B39b) may run before or after it. Rerunnable,
-- forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 211_verify_subscription_facts.sql there (normal, then provoked), then the verifies that read what this script re-creates:
--   cma.subscription_payment_state_of (both forms, dropped and created: four more columns): 119_verify_subscriptions.sql,
--     149_verify_installed_base_list.sql, 161_verify_installed_base_now.sql, 173_verify_active_customers.sql,
--     177_verify_active_attribution_present.sql;
--   cma.active_rest_body_of, cma.active_rows_of and cma.active_inputs_key_of (Customers → Active): 173, 175_verify_active_refresh_quiet.sql,
--     177 and 185_verify_active_device_bands.sql;
--   cma.flash_definition_version (subscriptions and installed_base move to 0009ze): 123_verify_flash.sql,
--     137_verify_flash_insights.sql, 139_verify_flash_totals.sql, 143_verify_reviews_all_order_kinds.sql,
--     147_verify_installed_base_models.sql, 159_verify_flash_current_take.sql, 181_verify_flash_stored_cards.sql;
--   cma.data_quality_of, cma.data_quality(), cma.data_quality_flash_checks() and cma.data_quality_fix_in: 41, 69, 73, 75,
--     101, 105, 113, 117, 123, 133_verify_perf.sql, 137, 161, 179_verify_job_reads.sql;
--   through cma.flash_rows_of (the payment state of a list's page): 149, 161, 189_verify_fleet_management.sql and
--     193_verify_fleet_page.sql;
--   cma.check_tenant_setting(): 73, 101, 113, 121, 123, 137, 179; through its trigger 14 and 27;
--   131_time_all.sql (edited by this change: the facts' rows).
-- Prod: this script and 211 before the merge of its pull request (main's web runs unchanged on it: the new columns of the
-- payment state come after the old ones, and no page reads a new object before the merge).
--
-- Why (Martin, 20 November 2026, brief B39 continued, Part B39c; Decision log, 20 Nov 2026): Part A (0009za) mirrors the
-- subscription app's lines, catalog and billing events, and the audit (0009zb, 0009zc) settled how the app behaves
-- (C.0, which wins where it differs from C.1 to C.10):
--   chargebacks   the app moves most charged-back subscriptions to failed itself: Failed stays status-based, with the
--                 chargeback's return code as its reason; Charged back is an active subscription whose latest renewal's
--                 store order (else its purchase's) was charged back;
--   linking       chargebacks link by store order; purchases stored before 0009zc carry no order, so the ingest's
--                 backfill --object purchase_order fills them once (cma.ingest_fill_purchase_orders);
--   invoices      Awaiting payment is built from invoice events, which exist in some stores only (GB, DE, NL on 20 Nov):
--                 a store without them never has the state;
--   start         no migrated subscription has a store order the CMA holds, so the original start's basis is first_order
--                 or created; migration_cycles is not built until Martin's hand check of migrated subscriptions against
--                 the stores' first orders, and Customers → Active's customer start is unchanged (customers.start_basis
--                 comes with that check);
--   minimum term  the app holds none: nothing is built for it.
-- Amounts are never summed across currencies; counts reach back to each store's first event, amounts only from the
-- first load of each connection (rule 12); a store's months count for the rates from the month after its last month of
-- migrated events (Martin, 20 November 2026: the starting base then holds the store's migrated subscriptions), else
-- from the first complete month after its first event; a later month with a small share of migrated events
-- (subscriptions.migration_bulk_min_pct) is a straggler, reported in cma.subscription_store_start, never moving the start.
--
-- What it adds
--   settings   subscriptions.migration_bulk_min_pct (5), subscriptions.propositions (empty; Pulse4all's seed hs1,frx,buurt_aed,outdoor in 02_seed_pulse4all.sql, for
--              Kira to confirm), subscriptions.take_refresh_minutes (15)
--   table      cma.subscription_variant_mapping (tenant configuration, audited): line kind, model, devices per unit,
--              proposition per connection and variant; cma.set_subscription_variant_mapping (tenant.configure),
--              cma.subscription_variants_of / cma.subscription_variants (the panel's list)
--   functions  cma.payment_states() (the states' order and worst rank), cma.subscription_device_units_of,
--              cma.inputs_markers_of (the inputs' markers per table, each in a statement of its own, so in parallel),
--              cma.subscription_interval_group_of, cma.subscription_amount_at, cma.subscription_moves_of,
--              cma.renewal_outcomes_of, cma.subscription_facts_inputs_key_of, cma.subscription_facts_refresh_of and its
--              job entry cma.subscription_facts_refresh() (customers.refresh), cma.ingest_fill_purchase_orders
--   takes      cma.subscription_take_state, cma.subscription_take, cma.subscription_month_take, cma.renewal_outcome,
--              cma.subscription_survival_take, cma.subscription_store_start (row-level security and grants, no audit
--              trigger); cma.subscription_rate_start_of (when each store's rates start)
--   readers    cma_read.subscription_take, subscription_month_take, subscription_churn_month, renewal_outcome,
--              subscription_survival, subscription_store_start, dq_subscription_variant_unmapped, dq_subscription_device_units_mismatch
--   checks     data quality subscription_variant_unmapped (fixed in cma) and subscription_device_units_mismatch (assets)
-- What it re-creates (each from its latest definition, with its -- based on: line)
--   cma.check_tenant_setting()                     202: the three settings
--   cma.subscription_payment_state_of(uuid)        118: dropped and created (Charged back, Awaiting payment, four columns)
--   cma.subscription_payment_state_of(uuid,uuid[]) 148: the same, narrowed first
--   cma_read.subscription_payment_state(_rows)     118: the new columns
--   cma.active_rest_body_of, cma.active_rows_of    184: the mix and the worst state over cma.payment_states(); JIT off
--   cma.flash_definition_version(text)             138: subscriptions and installed_base 0009ze
--   cma.active_inputs_key_of(uuid)                 174: 174's markers, in parallel, and the billing events
--   cma.data_quality_flash_checks(), cma.data_quality(), cma.data_quality_fix_in(text,text)   136; cma.data_quality_of 178
-- Not built here (named in the pull request): Flash's breakdowns by proposition, model and interval group, the
-- installed base's devices paid for, customers.start_basis and the basis migration_cycles, the comparison with the app's
-- own figures (B39b), the page (B39d).
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
  if not exists (select 1 from cma.schema_migration where version = '0009zc') then
    raise exception 'addition 0009zc (206_subscription_full_read_guard.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings (C.1, C.9)
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('subscriptions.propositions', 'text', null, '',
     'The propositions a subscription line can belong to through the variant mapping: up to twenty codes (a lower case letter, then lower case letters, digits and _, at most 40 each), comma-separated without spaces, such as hs1,frx; empty means none yet'),
  ('subscriptions.migration_bulk_min_pct', 'integer', null, '5',
     'The share (1 to 100 percent) of a store''s migrated events a month must hold to count toward its migration: the Churn rate and the Failed rate start the month after the last such month; a later month below it is a straggler, reported and never moving the start (addition 0009ze)'),
  ('subscriptions.take_refresh_minutes', 'integer', null, '15',
     'The age in minutes (1 to 1440) after which the minute job computes the subscription facts again (addition 0009ze); a run whose inputs did not change since the last take computes nothing')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0009za's (202), with the three settings of the subscription facts
-- based on: 202_subscription_lines.sql
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
-- 2. The variant mapping (C.1): tenant configuration per subscriptions connection and variant
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.subscription_variant_mapping (
  id                 uuid primary key default uuidv7(),
  tenant_id          uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id      uuid not null,
  variant_source_id  text not null check (cma.subscription_id_ok(variant_source_id)),
  line_kind          text not null check (line_kind in ('device', 'accessory', 'service', 'other')),
  model_key          text,
  devices_per_unit   integer not null check (devices_per_unit between 0 and 20),
  proposition        text check (proposition ~ '^[a-z][a-z0-9_]{0,39}$'),
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  unique (tenant_id, id),
  unique (tenant_id, connection_id, variant_source_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id),
  foreign key (tenant_id, model_key) references cma.device_model (tenant_id, key),
  check ((line_kind = 'device') = (model_key is not null)),
  check (line_kind = 'device' or devices_per_unit = 0)
);
comment on table cma.subscription_variant_mapping is
  'The variant mapping (addition 0009ze): per subscriptions connection and product variant of the subscription app, what a line of it is (device, accessory, service, other), the device model of the tenant''s catalog a device line holds, the devices per unit (0 to 20; only a device line holds any) and its proposition (a code of subscriptions.propositions). Tenant configuration, set under tenant.configure through cma.set_subscription_variant_mapping and audited';
select cma.setup_tenant_table('cma.subscription_variant_mapping');

-- Set or remove one variant's mapping (C.1): under tenant.configure; a line kind of null removes the row. The connection
-- is a subscriptions connection of the tenant and holds the variant (its catalog or one of its lines); a device line
-- names a model of the tenant's catalog, the others none; devices per unit defaults to 1 for a device line and is 0 for
-- the others; a proposition is one of the tenant's subscriptions.propositions. Answers the stored row (null once removed)
create or replace function cma.set_subscription_variant_mapping(p_connection_id uuid, p_variant_source_id text, p_line_kind text,
                                                               p_model_key text default null, p_devices_per_unit integer default null,
                                                               p_proposition text default null)
returns cma.subscription_variant_mapping
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_units  integer;
  r        cma.subscription_variant_mapping;
begin
  perform cma.assert_permission('tenant.configure');
  if not exists (select 1 from cma.integration_connection c
                 where c.tenant_id = v_tenant and c.id = p_connection_id and c.kind = 'subscriptions') then
    raise exception 'No subscriptions connection % in this tenant', p_connection_id using errcode = 'CMA02';
  end if;
  if p_variant_source_id is null
     or (not exists (select 1 from cma.subscription_product_variant v
                     where v.tenant_id = v_tenant and v.connection_id = p_connection_id and v.variant_source_id = p_variant_source_id)
         and not exists (select 1 from cma.subscription_line l
                         where l.tenant_id = v_tenant and l.connection_id = p_connection_id and l.variant_source_id = p_variant_source_id)) then
    raise exception 'The connection holds no variant %', p_variant_source_id using errcode = 'CMA02';
  end if;
  if p_line_kind is null then
    delete from cma.subscription_variant_mapping m
    where m.tenant_id = v_tenant and m.connection_id = p_connection_id and m.variant_source_id = p_variant_source_id;
    return null;
  end if;
  if p_line_kind not in ('device', 'accessory', 'service', 'other') then
    raise exception 'A line kind is one of device, accessory, service and other' using errcode = 'CMA04';
  end if;
  if p_line_kind = 'device' then
    if p_model_key is null or not exists (select 1 from cma.device_model m where m.tenant_id = v_tenant and m.key = p_model_key) then
      raise exception 'A device line names a model of the tenant''s device models' using errcode = 'CMA04';
    end if;
  elsif p_model_key is not null then
    raise exception 'Only a device line names a model' using errcode = 'CMA04';
  end if;
  v_units := coalesce(p_devices_per_unit, case when p_line_kind = 'device' then 1 else 0 end);
  if v_units not between 0 and 20 or (p_line_kind <> 'device' and v_units <> 0) then
    raise exception 'Devices per unit is a whole number from 0 to 20, and 0 for a line that is not a device' using errcode = 'CMA04';
  end if;
  if p_proposition is not null
     and not (p_proposition = any (cma.flash_list_of(cma.setting_of(v_tenant, 'subscriptions.propositions')))) then
    raise exception 'A proposition is one of the tenant''s propositions (subscriptions.propositions)' using errcode = 'CMA04';
  end if;
  insert into cma.subscription_variant_mapping as m
    (tenant_id, connection_id, variant_source_id, line_kind, model_key, devices_per_unit, proposition, updated_at, updated_by)
  values (v_tenant, p_connection_id, p_variant_source_id, p_line_kind, p_model_key, v_units, p_proposition, now(), cma.current_user_id())
  on conflict (tenant_id, connection_id, variant_source_id) do update
    set line_kind = excluded.line_kind, model_key = excluded.model_key, devices_per_unit = excluded.devices_per_unit,
        proposition = excluded.proposition, updated_at = excluded.updated_at, updated_by = excluded.updated_by
  returning * into r;
  return r;
end
$$;

-- The variants of the tenant's subscriptions connections with their mapping (C.1, the panel's list): every variant of
-- the catalog and every variant a line names that the catalog does not hold, with the catalog's texts (merchant text,
-- never a customer's), the active lines (lines not canceled and still held, of a present subscription in a
-- device-holding status, flash.device_holding_statuses) and the mapping; unmapped variants on an active line first.
-- The caller's rights: the application reads its tenant's rows
create or replace function cma.subscription_variants_of(p_tenant_id uuid, p_connection_id uuid default null)
returns table (connection_id uuid, market text, variant_source_id text, product_source_id text, product_title text,
               variant_title text, sku text, product_status text, in_catalog boolean, active_lines integer, line_kind text,
               model_key text, devices_per_unit integer, proposition text, updated_at timestamptz)
language sql stable
rows 200
as $$
  with h as materialized (
    select cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.device_holding_statuses')) as holding
  ), c as materialized (
    select x.id from cma.integration_connection x
    where x.tenant_id = p_tenant_id and x.kind = 'subscriptions' and (p_connection_id is null or x.id = p_connection_id)
  ), v as (
    select v.connection_id, v.variant_source_id from cma.subscription_product_variant v
    where v.tenant_id = p_tenant_id and v.connection_id in (select c.id from c)
    union
    select l.connection_id, l.variant_source_id from cma.subscription_line l
    where l.tenant_id = p_tenant_id and l.connection_id in (select c.id from c) and l.variant_source_id is not null
  ), a as (
    select l.connection_id, l.variant_source_id, count(*)::integer as n
    from cma.subscription_line l
    join cma.subscription s on s.tenant_id = l.tenant_id and s.connection_id = l.connection_id and s.source_id = l.subscription_source_id
    where l.tenant_id = p_tenant_id and l.connection_id in (select c.id from c)
      and l.canceled_at is null and l.source_deleted_at is null and l.variant_source_id is not null
      and s.source_deleted_at is null and s.status = any ((select h.holding from h)::text[])
    group by 1, 2
  )
  select v.connection_id, sm.market, v.variant_source_id, p.product_source_id, p.product_title, p.variant_title, p.sku, p.product_status,
         p.id is not null, coalesce(a.n, 0), m.line_kind, m.model_key, m.devices_per_unit, m.proposition, m.updated_at
  from v
  left join cma.subscription_product_variant p
    on p.tenant_id = p_tenant_id and p.connection_id = v.connection_id and p.variant_source_id = v.variant_source_id
  left join a on a.connection_id = v.connection_id and a.variant_source_id = v.variant_source_id
  left join cma.subscription_variant_mapping m
    on m.tenant_id = p_tenant_id and m.connection_id = v.connection_id and m.variant_source_id = v.variant_source_id
  left join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y) sm on sm.connection_id = v.connection_id
  order by sm.market collate "C" nulls last, v.connection_id, (m.line_kind is null and coalesce(a.n, 0) > 0) desc, coalesce(a.n, 0) desc,
           p.product_title collate "C" nulls last, p.variant_title collate "C" nulls last, v.variant_source_id collate "C"
$$;

-- The page's entries (the API): the variants for the caller's tenant under tenant.configure
create or replace function cma.subscription_variants(p_connection_id uuid default null)
returns table (connection_id uuid, market text, variant_source_id text, product_source_id text, product_title text,
               variant_title text, sku text, product_status text, in_catalog boolean, active_lines integer, line_kind text,
               model_key text, devices_per_unit integer, proposition text, updated_at timestamptz)
language plpgsql
rows 200
as $$
begin
  perform cma.assert_permission('tenant.configure');
  if p_connection_id is not null and not exists (select 1 from cma.integration_connection c
                                                 where c.tenant_id = cma.current_tenant_id() and c.id = p_connection_id and c.kind = 'subscriptions') then
    raise exception 'No subscriptions connection % in this tenant', p_connection_id using errcode = 'CMA02';
  end if;
  return query select * from cma.subscription_variants_of(cma.current_tenant_id(), p_connection_id);
end
$$;

-- Device units and propositions per subscription (C.1): over its recurring lines (not one-time: recurring_cycle_limit is
-- not 1) not canceled and still held, the sum of quantity × the mapping's devices per unit; null while such a line has no
-- variant or an unmapped one; a subscription without such a line holds 0. The propositions of its mapped lines, sorted
create or replace function cma.subscription_device_units_of(p_tenant_id uuid)
returns table (subscription_id uuid, device_units integer, propositions text[], models text[])
language sql stable
rows 10000
as $$
  select s.id,
         case when count(l.id) filter (where m.id is null) > 0 then null
              else coalesce(sum(coalesce(l.quantity, 1) * m.devices_per_unit), 0) end::integer,
         coalesce(array_agg(distinct m.proposition order by m.proposition) filter (where m.proposition is not null), '{}'),
         coalesce(array_agg(distinct m.model_key order by m.model_key) filter (where m.model_key is not null), '{}')
  from cma.subscription s
  left join cma.subscription_line l
    on l.tenant_id = s.tenant_id and l.connection_id = s.connection_id and l.subscription_source_id = s.source_id
   and l.canceled_at is null and l.source_deleted_at is null and l.recurring_cycle_limit is distinct from 1
  left join cma.subscription_variant_mapping m
    on m.tenant_id = s.tenant_id and m.connection_id = l.connection_id and m.variant_source_id = l.variant_source_id
  where s.tenant_id = p_tenant_id and s.source_deleted_at is null
  group by s.id
$$;
alter function cma.subscription_device_units_of(uuid) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 3. Payment state, second version (C.2, as C.0 settled it)
-- ---------------------------------------------------------------------------------------------
-- The payment states in their order (C.2): key, the order a mix shows them in, and the rank of the worst state of a
-- customer (1 the worst). One list, read by Customers → Active's mix and its customer list instead of their own literals
create or replace function cma.payment_states()
returns table (key text, sort_order integer, worst_rank integer)
language sql immutable
rows 7
as $$
  values ('paid', 1, 6), ('in_retry', 2, 3), ('charged_back', 3, 2), ('awaiting_payment', 4, 4), ('failed', 5, 1), ('paused', 6, 5),
         ('canceled', 7, 7)
$$;

-- The return type gains state_since, overdue, chargeback_return_code, amount_at_risk and currency, so both forms are
-- dropped and created (create or replace cannot change a function's columns); the reader view and its function are
-- dropped first and made again in section 9
drop view if exists cma_read.subscription_payment_state;
drop function if exists cma_read.subscription_payment_state_rows();
drop function if exists cma.subscription_payment_state_of(uuid);
drop function if exists cma.subscription_payment_state_of(uuid, uuid[]);

-- The invoice renewals are read by connection and renewal (Awaiting payment): billing_event is not a busy table, so its
-- index is made here
create index if not exists billing_event_renewal_idx on cma.billing_event (tenant_id, connection_id, renewal_source_id)
  where renewal_source_id is not null;

-- Per subscription, its payment state (C.2, C.0): Failed, Paused and Canceled by its status (a failed subscription keeps
-- the return code of a chargeback on its latest renewal's store order as its reason); for an active one, in this order,
-- In retry (a failed renewal no renewal of its cycle or a later one followed, as before), Charged back (a chargeback on
-- the store order of its latest renewal, else of its purchase: C.0, Juo left it active), Awaiting payment (its latest
-- invoice placed for a renewal has no paid invoice of that renewal; overdue once an overdue one came: only stores with
-- invoice events have it), else Paid. state_since: since when it holds the state; amount_at_risk: the amount per cycle
-- while In retry, Failed, Charged back or overdue Awaiting payment, in its currency. Every subscription of the tenant
-- based on: 118_subscriptions.sql
create function cma.subscription_payment_state_of(p_tenant_id uuid)
returns table (subscription_id uuid, connection_id uuid, source_id text, customer_source_id text, status text, payment_state text,
               retry_cycle integer, retry_since timestamptz, last_attempt integer, state_since timestamptz, overdue boolean,
               chargeback_return_code text, amount_at_risk numeric, currency text)
language sql stable
rows 10000
as $$
  with s as materialized (
    select s.id, s.connection_id, s.source_id, s.customer_source_id, s.status, s.amount_per_cycle, s.currency, s.paused_at, s.canceled_at
    from cma.subscription s
    where s.tenant_id = p_tenant_id and s.source_deleted_at is null
      and s.status in ('active', 'paused', 'canceled', 'expired', 'failed')
  ),
  open_failure as (
    select f.connection_id, f.subscription_source_id, f.cycle_index, f.occurred_at, f.attempt
    from cma.subscription_event f
    join s on s.connection_id = f.connection_id and s.source_id = f.subscription_source_id and s.status = 'active'
    where f.tenant_id = p_tenant_id and f.event_type = 'renew_failed'
      and not exists (select 1 from cma.subscription_event r
                      where r.tenant_id = f.tenant_id and r.connection_id = f.connection_id
                        and r.subscription_source_id = f.subscription_source_id and r.event_type = 'renewed'
                        and case when f.cycle_index is not null and r.cycle_index is not null then r.cycle_index >= f.cycle_index
                                 else r.occurred_at > f.occurred_at end)
  ),
  retry as (
    select o.connection_id, o.subscription_source_id,
           (array_agg(o.cycle_index order by o.cycle_index desc nulls last, o.occurred_at desc))[1] as cycle_index
    from open_failure o
    group by 1, 2
  ),
  retry_detail as (
    select r.connection_id, r.subscription_source_id, r.cycle_index, min(o.occurred_at) as since, max(o.attempt) as last_attempt
    from retry r
    join open_failure o on o.connection_id = r.connection_id and o.subscription_source_id = r.subscription_source_id
                       and o.cycle_index is not distinct from r.cycle_index
    group by 1, 2, 3
  ),
  last_renewal as (
    -- each active or failed subscription's latest renewal (its highest cycle) and that renewal's store order; without a
    -- renewal, its purchase's store order (0009zc)
    select s.id, r.occurred_at, coalesce(r.order_source_id, case when r.source_id is null then p.purchase_order end) as order_source_id
    from s
    left join lateral (
      select e.source_id, e.occurred_at, e.order_source_id from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
        and e.event_type = 'renewed' and e.cycle_index is not null
      order by e.cycle_index desc limit 1) r on true
    left join lateral (
      select e.raw ->> 'orderId' as purchase_order from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
        and e.event_type = 'purchased' and (e.raw ->> 'orderId') ~ '^\d{1,30}$'
        -- only for a subscription without any renewal (conditions on the outer row: a one-time filter, no scan otherwise)
        and r.source_id is null
        and not exists (select 1 from cma.subscription_event z
                        where z.tenant_id = p_tenant_id and z.connection_id = s.connection_id and z.subscription_source_id = s.source_id
                          and z.event_type = 'renewed')
      order by e.occurred_at, e.source_id collate "C" limit 1) p on true
    where s.status in ('active', 'failed')
  ),
  last_order as (
    select l.id, l.order_source_id from last_renewal l
  ),
  charge as (
    -- the latest chargeback on that order (C.0: linked by the store order; no renewal can follow it, the renewal being
    -- the latest)
    select distinct on (o.id) o.id, b.occurred_at, b.return_code
    from last_order o
    join s on s.id = o.id
    join cma.billing_event b on b.tenant_id = p_tenant_id and b.connection_id = s.connection_id and b.kind = 'chargeback'
                            and b.order_source_id = o.order_source_id
    where o.order_source_id is not null
    order by o.id, b.occurred_at desc, b.source_id collate "C" desc
  ),
  ren as materialized (
    -- the invoice renewals of the active subscriptions' connections, one row per renewal in one pass: the subscription an
    -- event of it names, the customer, the latest invoice placed, and whether a paid or an overdue invoice of it came
    select b.connection_id, b.renewal_source_id,
           max(b.subscription_source_id) as subscription_source_id, min(b.customer_source_id) as customer_source_id,
           max(b.occurred_at) filter (where b.kind = 'invoice_placed') as placed_at,
           bool_or(b.kind = 'invoice_paid') as paid, bool_or(b.kind = 'invoice_overdue') as overdue
    from cma.billing_event b
    where b.tenant_id = p_tenant_id and b.kind in ('invoice_placed', 'invoice_paid', 'invoice_overdue') and b.renewal_source_id is not null
      and b.connection_id in (select s.connection_id from s where s.status = 'active')
    group by b.connection_id, b.renewal_source_id
  ),
  sole as (
    -- a customer's one active subscription of the connection, for a renewal whose events name no subscription
    select x.connection_id, x.customer_source_id, min(x.source_id) as source_id
    from cma.subscription x
    join (select distinct r.connection_id, r.customer_source_id from ren r
          where r.subscription_source_id is null and r.customer_source_id is not null) c
      on c.connection_id = x.connection_id and c.customer_source_id = x.customer_source_id
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.status = 'active'
    group by 1, 2
    having count(*) = 1
  ),
  awaiting as (
    -- an active subscription's latest invoice placed for a renewal that no paid invoice of that renewal followed; overdue
    -- once an overdue invoice of that renewal came
    select distinct on (s.id) s.id, r.placed_at as occurred_at, r.overdue, r.paid
    from ren r
    left join sole o on o.connection_id = r.connection_id and o.customer_source_id = r.customer_source_id and r.subscription_source_id is null
    join s on s.connection_id = r.connection_id and s.source_id = coalesce(r.subscription_source_id, o.source_id) and s.status = 'active'
    where r.placed_at is not null
    order by s.id, r.placed_at desc, r.renewal_source_id collate "C" desc
  ),
  since as (
    -- a failed subscription, and a paused or ended one without its own paused or canceled time: its latest event into
    -- its status
    select s.id, m.at
    from s
    cross join lateral (
      select max(e.occurred_at) as at from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
        and e.event_type in ('status_changed', 'canceled', 'paused') and e.status_to = s.status) m
    where s.status = 'failed' or (s.status = 'paused' and s.paused_at is null)
       or (s.status in ('canceled', 'expired') and s.canceled_at is null)
  )
  select s.id, s.connection_id, s.source_id, s.customer_source_id, s.status, x.state,
         d.cycle_index, d.since, d.last_attempt,
         case x.state when 'in_retry' then d.since when 'charged_back' then c.occurred_at when 'awaiting_payment' then a.occurred_at
                      when 'paused' then coalesce(s.paused_at, n.at) when 'canceled' then coalesce(s.canceled_at, n.at)
                      when 'failed' then n.at else lr.occurred_at end,
         case when x.state = 'awaiting_payment' then a.overdue end,
         case when x.state in ('charged_back', 'failed') then c.return_code end,
         case when x.state in ('in_retry', 'failed', 'charged_back') or (x.state = 'awaiting_payment' and a.overdue) then s.amount_per_cycle end,
         s.currency
  from s
  left join retry_detail d on d.connection_id = s.connection_id and d.subscription_source_id = s.source_id
  left join charge c on c.id = s.id
  left join awaiting a on a.id = s.id and not a.paid
  left join since n on n.id = s.id
  left join last_renewal lr on lr.id = s.id
  cross join lateral (
    select case when s.status = 'failed' then 'failed'
                when s.status = 'paused' then 'paused'
                when s.status in ('canceled', 'expired') then 'canceled'
                when d.subscription_source_id is not null then 'in_retry'
                when c.id is not null then 'charged_back'
                when a.id is not null then 'awaiting_payment'
                else 'paid' end as state) x
$$;
alter function cma.subscription_payment_state_of(uuid) set jit = off;

-- The same for the given subscriptions (148's narrowing first): a list's page
-- based on: 148_installed_base_list.sql
create function cma.subscription_payment_state_of(p_tenant_id uuid, p_subscription_ids uuid[])
returns table (subscription_id uuid, connection_id uuid, source_id text, customer_source_id text, status text, payment_state text,
               retry_cycle integer, retry_since timestamptz, last_attempt integer, state_since timestamptz, overdue boolean,
               chargeback_return_code text, amount_at_risk numeric, currency text)
language sql stable
rows 500   -- a list's page of subscriptions
as $$
  with s as materialized (
    select s.id, s.connection_id, s.source_id, s.customer_source_id, s.status, s.amount_per_cycle, s.currency, s.paused_at, s.canceled_at
    from cma.subscription s
    where s.tenant_id = p_tenant_id and s.source_deleted_at is null
      and s.status in ('active', 'paused', 'canceled', 'expired', 'failed')
      and s.id = any (p_subscription_ids)
  ),
  open_failure as (
    select f.connection_id, f.subscription_source_id, f.cycle_index, f.occurred_at, f.attempt
    from cma.subscription_event f
    join s on s.connection_id = f.connection_id and s.source_id = f.subscription_source_id and s.status = 'active'
    where f.tenant_id = p_tenant_id and f.event_type = 'renew_failed'
      and not exists (select 1 from cma.subscription_event r
                      where r.tenant_id = f.tenant_id and r.connection_id = f.connection_id
                        and r.subscription_source_id = f.subscription_source_id and r.event_type = 'renewed'
                        and case when f.cycle_index is not null and r.cycle_index is not null then r.cycle_index >= f.cycle_index
                                 else r.occurred_at > f.occurred_at end)
  ),
  retry as (
    select o.connection_id, o.subscription_source_id,
           (array_agg(o.cycle_index order by o.cycle_index desc nulls last, o.occurred_at desc))[1] as cycle_index
    from open_failure o
    group by 1, 2
  ),
  retry_detail as (
    select r.connection_id, r.subscription_source_id, r.cycle_index, min(o.occurred_at) as since, max(o.attempt) as last_attempt
    from retry r
    join open_failure o on o.connection_id = r.connection_id and o.subscription_source_id = r.subscription_source_id
                       and o.cycle_index is not distinct from r.cycle_index
    group by 1, 2, 3
  ),
  last_renewal as (
    -- each active or failed subscription's latest renewal (its highest cycle) and that renewal's store order; without a
    -- renewal, its purchase's store order (0009zc)
    select s.id, r.occurred_at, coalesce(r.order_source_id, case when r.source_id is null then p.purchase_order end) as order_source_id
    from s
    left join lateral (
      select e.source_id, e.occurred_at, e.order_source_id from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
        and e.event_type = 'renewed' and e.cycle_index is not null
      order by e.cycle_index desc limit 1) r on true
    left join lateral (
      select e.raw ->> 'orderId' as purchase_order from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
        and e.event_type = 'purchased' and (e.raw ->> 'orderId') ~ '^\d{1,30}$'
        -- only for a subscription without any renewal (conditions on the outer row: a one-time filter, no scan otherwise)
        and r.source_id is null
        and not exists (select 1 from cma.subscription_event z
                        where z.tenant_id = p_tenant_id and z.connection_id = s.connection_id and z.subscription_source_id = s.source_id
                          and z.event_type = 'renewed')
      order by e.occurred_at, e.source_id collate "C" limit 1) p on true
    where s.status in ('active', 'failed')
  ),
  last_order as (
    select l.id, l.order_source_id from last_renewal l
  ),
  charge as (
    -- the latest chargeback on that order (C.0: linked by the store order; no renewal can follow it, the renewal being
    -- the latest)
    select distinct on (o.id) o.id, b.occurred_at, b.return_code
    from last_order o
    join s on s.id = o.id
    join cma.billing_event b on b.tenant_id = p_tenant_id and b.connection_id = s.connection_id and b.kind = 'chargeback'
                            and b.order_source_id = o.order_source_id
    where o.order_source_id is not null
    order by o.id, b.occurred_at desc, b.source_id collate "C" desc
  ),
  ren as materialized (
    -- the invoice renewals of the active subscriptions' connections, one row per renewal in one pass: the subscription an
    -- event of it names, the customer, the latest invoice placed, and whether a paid or an overdue invoice of it came
    select b.connection_id, b.renewal_source_id,
           max(b.subscription_source_id) as subscription_source_id, min(b.customer_source_id) as customer_source_id,
           max(b.occurred_at) filter (where b.kind = 'invoice_placed') as placed_at,
           bool_or(b.kind = 'invoice_paid') as paid, bool_or(b.kind = 'invoice_overdue') as overdue
    from cma.billing_event b
    where b.tenant_id = p_tenant_id and b.kind in ('invoice_placed', 'invoice_paid', 'invoice_overdue') and b.renewal_source_id is not null
      and b.connection_id in (select s.connection_id from s where s.status = 'active')
    group by b.connection_id, b.renewal_source_id
  ),
  sole as (
    -- a customer's one active subscription of the connection, for a renewal whose events name no subscription
    select x.connection_id, x.customer_source_id, min(x.source_id) as source_id
    from cma.subscription x
    join (select distinct r.connection_id, r.customer_source_id from ren r
          where r.subscription_source_id is null and r.customer_source_id is not null) c
      on c.connection_id = x.connection_id and c.customer_source_id = x.customer_source_id
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.status = 'active'
    group by 1, 2
    having count(*) = 1
  ),
  awaiting as (
    -- an active subscription's latest invoice placed for a renewal that no paid invoice of that renewal followed; overdue
    -- once an overdue invoice of that renewal came
    select distinct on (s.id) s.id, r.placed_at as occurred_at, r.overdue, r.paid
    from ren r
    left join sole o on o.connection_id = r.connection_id and o.customer_source_id = r.customer_source_id and r.subscription_source_id is null
    join s on s.connection_id = r.connection_id and s.source_id = coalesce(r.subscription_source_id, o.source_id) and s.status = 'active'
    where r.placed_at is not null
    order by s.id, r.placed_at desc, r.renewal_source_id collate "C" desc
  ),
  since as (
    -- a failed subscription, and a paused or ended one without its own paused or canceled time: its latest event into
    -- its status
    select s.id, m.at
    from s
    cross join lateral (
      select max(e.occurred_at) as at from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
        and e.event_type in ('status_changed', 'canceled', 'paused') and e.status_to = s.status) m
    where s.status = 'failed' or (s.status = 'paused' and s.paused_at is null)
       or (s.status in ('canceled', 'expired') and s.canceled_at is null)
  )
  select s.id, s.connection_id, s.source_id, s.customer_source_id, s.status, x.state,
         d.cycle_index, d.since, d.last_attempt,
         case x.state when 'in_retry' then d.since when 'charged_back' then c.occurred_at when 'awaiting_payment' then a.occurred_at
                      when 'paused' then coalesce(s.paused_at, n.at) when 'canceled' then coalesce(s.canceled_at, n.at)
                      when 'failed' then n.at else lr.occurred_at end,
         case when x.state = 'awaiting_payment' then a.overdue end,
         case when x.state in ('charged_back', 'failed') then c.return_code end,
         case when x.state in ('in_retry', 'failed', 'charged_back') or (x.state = 'awaiting_payment' and a.overdue) then s.amount_per_cycle end,
         s.currency
  from s
  left join retry_detail d on d.connection_id = s.connection_id and d.subscription_source_id = s.source_id
  left join charge c on c.id = s.id
  left join awaiting a on a.id = s.id and not a.paid
  left join since n on n.id = s.id
  left join last_renewal lr on lr.id = s.id
  cross join lateral (
    select case when s.status = 'failed' then 'failed'
                when s.status = 'paused' then 'paused'
                when s.status in ('canceled', 'expired') then 'canceled'
                when d.subscription_source_id is not null then 'in_retry'
                when c.id is not null then 'charged_back'
                when a.id is not null then 'awaiting_payment'
                else 'paid' end as state) x
$$;
alter function cma.subscription_payment_state_of(uuid, uuid[]) set jit = off;


-- ---------------------------------------------------------------------------------------------
-- 4. Customers → Active and Flash follow the payment states (C.2)
-- ---------------------------------------------------------------------------------------------
-- As 0009r's (184), with the payment state mix over cma.payment_states() (Charged back and Awaiting payment included)
-- based on: 184_active_device_bands.sql
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
                        from (select p.key as state, p.sort_order as ord from cma.payment_states() p where p.key <> 'canceled') x
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

-- As 0009r's (184), with a customer's worst payment state by cma.payment_states()'s rank
-- based on: 184_active_device_bands.sql
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
             (array(select w.key from cma.payment_states() w order by w.worst_rank))[min(array_position(array(select w.key from cma.payment_states() w order by w.worst_rank), p.payment_state))] as worst
      from cma.active_base b
      join cma.subscription_payment_state_of($1, array(select b2.subscription_id from cma.active_base b2
                                                       where b2.tenant_id = $1 and b2.customer_id in (select page.customer_id from page))) p
        on p.subscription_id = b.subscription_id
      where b.tenant_id = $1 and b.customer_id in (select page.customer_id from page)
      group by 1 $ps$
     else $ps$
      -- a file's rows (more than a page's 200): the worst payment state as the take holds it, of the file's as_of moment
      select b.customer_id,
             (array(select w.key from cma.payment_states() w order by w.worst_rank))[min(array_position(array(select w.key from cma.payment_states() w order by w.worst_rank), b.payment_state))] as worst
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

-- Flash's subscriptions and installed base count payment states that include Charged back and Awaiting payment from this
-- addition on: their definition version moves, so the watch compares no overview across the change
-- based on: 138_flash_totals.sql
create or replace function cma.flash_definition_version(p_overview text)
returns text
language sql immutable
as $$
  select case when p_overview in ('subscriptions', 'installed_base') then '0009ze'
              when p_overview = 'customers' then '0008zu'
              when p_overview in (select o.key from cma.flash_overviews() o) then '0008zn' end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The inputs' change markers, per table and in parallel (C.9)
-- ---------------------------------------------------------------------------------------------
-- 174's markers, each table's computed by a statement of its own (execute: a one-shot plan, which may run in parallel
-- workers; a static statement of a function, or a scalar subquery of one statement, never does), in the order asked.
-- Each part's text is 174's own, so a digest over 174's twelve parts is 174's digest (211 proves it). Five more parts for
-- the subscription facts: billing events, lines and the catalog (their mirrors move synced_at only when a row reads
-- differently, 202), the variant mapping and the observed changes by their rows. The caller's rights: the application
-- reads its tenant's rows. An unknown part is refused
create or replace function cma.inputs_markers_of(p_tenant_id uuid, p_parts text[])
returns text[]
language plpgsql
stable
set parallel_setup_cost = 0
set parallel_tuple_cost = 0
set min_parallel_table_scan_size = 0
as $$
declare
  v_part text;
  v_sql  text;
  v_out  text[] := '{}';
  v      text;
begin
  foreach v_part in array p_parts loop
    v_sql := case v_part
      when 'subscription' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
         from cma.subscription x where x.tenant_id = $1'
      when 'subscription_event' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
         from cma.subscription_event x where x.tenant_id = $1'
      when 'device' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
         from cma.device x where x.tenant_id = $1'
      when 'commerce_customer' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(row(
              x.id, x.connection_id, x.source_system, x.source_id, x.state, x.locale, x.orders_count, x.amount_spent,
              x.amount_currency, x.source_created_at, x.source_updated_at, x.source_deleted_at, x.phone_hash,
              x.crm_connection_id, x.crm_contact_source_id, x.matched_at), 0)))
         from cma.commerce_customer x where x.tenant_id = $1'
      when 'commerce_order' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(row(
              x.id, x.connection_id, x.source_system, x.source_id, x.order_name, x.customer_source_id, x.source_created_at,
              x.processed_at, x.source_updated_at, x.cancelled_at, x.cancel_reason, x.is_test, x.currency, x.total_amount,
              x.subtotal_amount, x.tax_amount, x.discount_amount, x.refunded_amount, x.financial_status,
              x.fulfillment_status, x.source_name, x.app_ref, x.landing_host, x.landing_path, x.utm, x.referring_host,
              x.tags, x.prior_orders_count, x.prior_count_exact, x.order_kind, x.source_deleted_at, x.phone_hash), 0)))
         from cma.commerce_order x where x.tenant_id = $1'
      when 'crm_contact' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(row(
              x.id, x.connection_id, x.source_system, x.source_id, x.country, x.language, x.source_updated_at,
              x.source_deleted_at, x.currency, x.store, x.country_source, x.source_created_at, x.segment), 0)))
         from cma.crm_contact x where x.tenant_id = $1'
      when 'commerce_store' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(x, 0))) from cma.commerce_store x where x.tenant_id = $1'
      when 'device_status' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(x, 0))) from cma.device_status x where x.tenant_id = $1'
      when 'device_model' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(x, 0))) from cma.device_model x where x.tenant_id = $1'
      when 'market' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(x, 0))) from cma.market x where x.tenant_id = $1'
      when 'integration_connection' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(row(x.id, x.key, x.adapter, x.kind, x.external_account_id, x.status), 0)))
         from cma.integration_connection x where x.tenant_id = $1'
      when 'timezone' then
        'select t.timezone from cma.tenant t where t.id = $1'
      when 'billing_event' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
         from cma.billing_event x where x.tenant_id = $1'
      when 'subscription_line' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
         from cma.subscription_line x where x.tenant_id = $1'
      when 'subscription_product_variant' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
         from cma.subscription_product_variant x where x.tenant_id = $1'
      when 'subscription_variant_mapping' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(x, 0))) from cma.subscription_variant_mapping x where x.tenant_id = $1'
      when 'subscription_change' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.observed_at)), sum((extract(epoch from x.observed_at) * 1000000)::bigint))
         from cma.subscription_change x where x.tenant_id = $1'
      end;
    if v_sql is null then
      raise exception 'Unknown input %', v_part using errcode = 'CMA04';
    end if;
    execute v_sql into v using p_tenant_id;
    v_out := v_out || v;
  end loop;
  return v_out;
end
$$;

-- Customers → Active's digest (174's twelve markers in 174's order, then the billing events): a chargeback or an invoice
-- changes a subscription's payment state (C.2), which the take stores, so a new billing event is a change of its inputs.
-- 174's parts joined as 174 joined them (concat_ws leaves out a null, as array_to_string does)
-- based on: 174_active_refresh_quiet.sql
create or replace function cma.active_inputs_key_of(p_tenant_id uuid)
returns text
language sql stable
as $$
  select md5(array_to_string(cma.inputs_markers_of(p_tenant_id,
    array['subscription', 'subscription_event', 'device', 'commerce_customer', 'commerce_order', 'crm_contact', 'commerce_store',
          'device_status', 'device_model', 'market', 'integration_connection', 'timezone', 'billing_event']), '|'))
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The facts' building blocks (C.3 to C.7)
-- ---------------------------------------------------------------------------------------------
-- A billing interval's group (C.6): monthly (every month), quarterly (every three months), yearly (every year or twelve
-- months), other (any other cycle), unknown without one
create or replace function cma.subscription_interval_group_of(p_interval text, p_count integer)
returns text
language sql immutable
as $$
  select case when p_interval is null or p_count is null then 'unknown'
              when p_interval = 'month' and p_count = 1 then 'monthly'
              when p_interval = 'month' and p_count = 3 then 'quarterly'
              when (p_interval = 'year' and p_count = 1) or (p_interval = 'month' and p_count = 12) then 'yearly'
              else 'other' end
$$;

-- A subscription's amount as of a moment (C.4): its stored amount, interval and currency taken back through the observed
-- changes after the moment (the first change after it holds the value before it). Correct only from the first load on:
-- the observed changes start then (rule 12), and nothing before is reconstructed. The monthly amount by Customers →
-- Active's month factor
create or replace function cma.subscription_amount_at(p_tenant_id uuid, p_connection_id uuid, p_source_id text, p_at timestamptz,
                                                      p_amount numeric, p_currency text, p_interval text, p_count integer)
returns table (monthly_amount numeric, currency text)
language sql stable
rows 1
as $$
  select coalesce((select c.old_value::numeric from cma.subscription_change c
                   where c.tenant_id = p_tenant_id and c.connection_id = p_connection_id and c.subscription_source_id = p_source_id
                     and c.field = 'amount_per_cycle' and c.observed_at > p_at
                   order by c.observed_at, c.id limit 1), p_amount)
         * cma.active_month_factor_of(
             coalesce((select c.old_value from cma.subscription_change c
                       where c.tenant_id = p_tenant_id and c.connection_id = p_connection_id and c.subscription_source_id = p_source_id
                         and c.field = 'billing_interval' and c.observed_at > p_at
                       order by c.observed_at, c.id limit 1), p_interval),
             coalesce((select c.old_value::integer from cma.subscription_change c
                       where c.tenant_id = p_tenant_id and c.connection_id = p_connection_id and c.subscription_source_id = p_source_id
                         and c.field = 'billing_interval_count' and c.observed_at > p_at
                       order by c.observed_at, c.id limit 1), p_count)),
         coalesce((select c.old_value from cma.subscription_change c
                   where c.tenant_id = p_tenant_id and c.connection_id = p_connection_id and c.subscription_source_id = p_source_id
                     and c.field = 'currency' and c.observed_at > p_at
                   order by c.observed_at, c.id limit 1), p_currency)
$$;

-- The status moves of every present subscription (C.4, C.5), reconstructed from the app's events up to a moment: its
-- entry at its creation in the app (kind new, or migrated when the app migrated it) in the status the first status event
-- names as its previous one (else active); every event that sets a status (status_changed, canceled, paused, resumed,
-- reactivated) that moves it; and, when the last of them does not end in the subscription's current status (the audit's
-- status_chain: a pause without an event), a last move into the current status at the latest of the last event, the
-- subscription's paused or canceled time and its last update at the source. A move's kind: churned (into an ended status,
-- flash.ended_subscription_statuses, from one that is not), moved_to_failed (into failed, while failed is not an ended
-- status), paused, resumed (paused to active), reactivated (any other status to active), none otherwise
create or replace function cma.subscription_moves_of(p_tenant_id uuid, p_now timestamptz)
returns table (subscription_id uuid, connection_id uuid, at timestamptz, status_from text, status_to text, kind text)
language sql stable
rows 100000
as $$
  with st as materialized (
    select cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.ended_subscription_statuses')) as ended
  ), s as materialized (
    select x.id, x.connection_id, x.source_id, x.status, x.source_created_at, x.paused_at, x.canceled_at, x.source_updated_at
    from cma.subscription x
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null
  ), ev as materialized (
    select s.id, e.occurred_at, e.source_id, e.event_type, e.status_from,
           case e.event_type when 'status_changed' then e.status_to when 'canceled' then 'canceled' when 'paused' then 'paused'
                             when 'resumed' then 'active' when 'reactivated' then 'active' end as status_to
    from s
    join cma.subscription_event e on e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
    where e.occurred_at <= p_now
      and e.event_type in ('status_changed', 'canceled', 'paused', 'resumed', 'reactivated', 'migrated', 'purchased', 'created')
  ), first_ev as (
    select ev.id, min(ev.occurred_at) as first_at,
           (array_agg(ev.status_from order by ev.occurred_at, ev.source_id collate "C")
              filter (where ev.status_to is not null and ev.status_from is not null))[1] as first_from,
           bool_or(ev.event_type = 'migrated') as migrated
    from ev
    group by ev.id
  ), seq as (
    -- the entry, then the status events in their order
    select s.id, coalesce(s.source_created_at, f.first_at) as at, 0 as ord, ''::text as src, coalesce(f.first_from, 'active') as status_to,
           coalesce(f.migrated, false) as migrated
    from s left join first_ev f on f.id = s.id
    where coalesce(s.source_created_at, f.first_at) <= p_now
    union all
    select ev.id, ev.occurred_at, 1, ev.source_id, ev.status_to, false
    from ev where ev.status_to is not null
  ), lagged as (
    select q.id, q.at, q.ord, q.src, q.status_to, q.migrated,
           lag(q.status_to) over (partition by q.id order by q.at, q.ord, q.src collate "C") as status_from,
           row_number() over (partition by q.id order by q.at desc, q.ord desc, q.src collate "C" desc) as from_last
    from seq q
  ), moves as (
    select l.id, l.at, l.status_from, l.status_to, l.ord, l.migrated
    from lagged l
    where l.ord = 0 or l.status_from is distinct from l.status_to
    union all
    -- the current status where the events do not end in it
    select s.id,
           greatest(l.at, case when s.status = 'paused' then s.paused_at when s.status in ('canceled', 'expired') then s.canceled_at end,
                    least(s.source_updated_at, p_now)),
           l.status_to, s.status, 2, false
    from s
    join lagged l on l.id = s.id and l.from_last = 1
    where l.status_to is distinct from s.status and s.source_updated_at <= p_now
  )
  select m.id, s.connection_id, m.at, m.status_from, m.status_to,
         case when m.ord = 0 then case when m.status_to = 'active' then case when m.migrated then 'migrated' else 'new' end end
              when m.status_to = any ((select st.ended from st)::text[]) then
                case when m.status_from = any ((select st.ended from st)::text[]) then null else 'churned' end
              when m.status_to = 'failed' then 'moved_to_failed'
              when m.status_to = 'paused' then 'paused'
              when m.status_to = 'active' and m.status_from = 'paused' then 'resumed'
              when m.status_to = 'active' then 'reactivated' end
  from moves m
  join s on s.id = m.id
$$;
alter function cma.subscription_moves_of(uuid, timestamptz) set jit = off;

-- When a store's Churn rate and Failed rate start (C.5, Martin, 20 November 2026): at the first month whose starting
-- base already holds the store's migrated subscriptions, that is the month after the store's last month with migrated
-- events; a store without migrated events at the first complete month after its first event. Derived from the data,
-- never a date in code. A month counts toward the migration when it holds at least subscriptions.migration_bulk_min_pct
-- of the store's migrated events; a later month below that share is a straggler: reported (its months and its events),
-- never a reason to start later. Where no month holds the share, the busiest month is the migration's last. Per
-- subscriptions connection with an event, months in the tenant's zone
create or replace function cma.subscription_rate_start_of(p_tenant_id uuid, p_now timestamptz)
returns table (connection_id uuid, first_event_month date, migration_months jsonb, last_migration_month date,
               straggler_months jsonb, stragglers integer, rate_start_month date)
language sql stable
rows 50
as $$
  with z as materialized (
    select t.timezone as zone, cma.setting_of(p_tenant_id, 'subscriptions.migration_bulk_min_pct')::numeric as pct
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
         (coalesce(lb.last_month, fe.first_month) + interval '1 month')::date
  from fe
  left join lb on lb.connection_id = fe.connection_id
$$;
alter function cma.subscription_rate_start_of(uuid, timestamptz) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 7. The takes (C.9): per subscription, per store and month, renewal outcomes and survival cells
-- ---------------------------------------------------------------------------------------------
-- Stored results, refreshed by the minute job (cma.subscription_facts_refresh_of): tenant-scoped with row-level
-- security and the application's grants, without the audit trigger (as Customers → Active's take, 172: a row image per row
-- per refresh would fill the audit log with computed values; the sources they are computed from are audited)
create table if not exists cma.subscription_take_state (
  tenant_id      uuid primary key default cma.current_tenant_id() references cma.tenant (id),
  computed_at    timestamptz not null,
  business_date  date not null,
  duration_ms    integer not null check (duration_ms >= 0),
  inputs_key     text not null,
  subscriptions  integer not null check (subscriptions >= 0),
  amounts_from   timestamptz
);
comment on table cma.subscription_take_state is
  'One row per tenant (addition 0009ze): when the subscription facts were last computed, how long it took, the digest of their inputs (a due run that finds the same digest computes nothing) and the moment from which amounts are known (the first load of the observed changes, addition 0009za)';

create table if not exists cma.subscription_take (
  tenant_id               uuid not null default cma.current_tenant_id() references cma.tenant (id),
  subscription_id         uuid not null,
  connection_id           uuid not null,
  source_id               text not null,
  market                  text not null,
  status                  text not null,
  payment_state           text,
  state_since             timestamptz,
  overdue                 boolean,
  chargeback_return_code  text,
  amount_at_risk          numeric(14,2),
  currency                text,
  monthly_amount          numeric,
  interval_group          text not null,
  device_units            integer,
  propositions            text[] not null default '{}',
  models                  text[] not null default '{}',
  original_start_at       timestamptz,
  original_start_basis    text check (original_start_basis in ('first_order', 'created')),
  cohort_month            date,
  migrated                boolean not null,
  renewals                integer not null check (renewals >= 0),
  primary key (tenant_id, subscription_id)
);
comment on table cma.subscription_take is
  'Per present subscription (addition 0009ze): its payment state with since, overdue, the chargeback''s return code and the amount at risk, its monthly amount (Customers → Active''s month factor) and interval group, device units and the propositions and models of its mapped lines, its original start (estimated) with the basis (first_order: the store customer''s earliest store order at or before the app''s created date; created: the app''s created date; migration_cycles is not built until the hand check of migrated subscriptions), the start cohort''s month, whether the app migrated it, and its renewals (distinct renewed cycles). Ids, codes, amounts and times only';

create table if not exists cma.subscription_month_take (
  tenant_id       uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id   uuid not null,
  market          text not null,
  month           date not null,
  kind            text not null check (kind in ('start', 'end', 'new', 'migrated', 'reactivated', 'resumed', 'expansion', 'contraction',
                                                'paused', 'churned', 'moved_to_failed')),
  currency        text not null default '',
  subscriptions   integer not null check (subscriptions >= 0),
  amount          numeric(16,2),
  complete        boolean not null,
  primary key (tenant_id, connection_id, month, kind, currency)
);
comment on table cma.subscription_month_take is
  'Per subscriptions connection (store) and calendar month in the tenant''s zone, from the month of the store''s first event (addition 0009ze): the Total subscriptions at the month''s start (kind start, the previous month end) and end (end), and the recurring amount movements by kind. currency empty: counts, from the first event on; per currency: the movements whose monthly amount is known (from the connection''s first load: the later of amounts_from of cma.subscription_take_state and the first time the CMA held one of its subscriptions) and their monthly amount (a positive size; contraction, paused, churned and moved_to_failed reduce the base). complete: the month is over and not before the month the store''s rates start (cma.subscription_store_start), so it counts for the Churn rate and the Failed rate';

create table if not exists cma.subscription_store_start (
  tenant_id             uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id         uuid not null,
  market                text not null,
  first_event_month     date not null,
  migration_months      jsonb not null default '{}',
  last_migration_month  date,
  straggler_months      jsonb not null default '{}',
  stragglers            integer not null check (stragglers >= 0),
  rate_start_month      date not null,
  primary key (tenant_id, connection_id)
);
comment on table cma.subscription_store_start is
  'Per subscriptions connection (store) with an event (addition 0009ze): the month of its first event, its migrated events per month (YYYY-MM: count), the last month that holds at least subscriptions.migration_bulk_min_pct of them, the later months below that share (stragglers, reported, never moving the start) and the month its Churn rate and Failed rate start: the month after that last migration month, else the first complete month after its first event';

create table if not exists cma.renewal_outcome (
  tenant_id                               uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id                           uuid not null,
  subscription_source_id                  text not null,
  renewal_key                             text not null,
  cycle_index                             integer,
  renewal_source_id                       text,
  first_attempt_at                        timestamptz not null,
  outcome                                 text not null check (outcome in ('paid_first_attempt', 'recovered', 'not_recovered', 'charged_back',
                                                                           'invoice_paid', 'invoice_open')),
  attempts                                integer not null check (attempts >= 1),
  recovered_at                            timestamptz,
  days_to_recover                         numeric(7,1),
  error_code                              text,
  instrument_type                         text,
  payment_method_changed_before_recovery  boolean,
  primary key (tenant_id, connection_id, subscription_source_id, renewal_key)
);
comment on table cma.renewal_outcome is
  'Per subscription and cycle with a renewal attempt (renewal_key cycle:<n>), and per invoice renewal (invoice:<renewal id>) (addition 0009ze): the first attempt, the outcome (paid_first_attempt, recovered: renewed after a failed attempt, not_recovered: failed with no renewal of the cycle, charged_back: renewed and its store order charged back, invoice_paid, invoice_open), the attempts, when it recovered and in how many days, the first failure''s error code, the subscription''s payment instrument now, and whether its payment method changed between the first failure and the recovery. Ids, codes and times only';

create table if not exists cma.subscription_survival_take (
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id    uuid not null,
  market           text not null,
  cohort_month     date not null,
  interval_group   text not null,
  renewal_number   integer not null check (renewal_number between 1 and 24),
  started          integer not null check (started >= 0),
  eligible         integer not null check (eligible >= 0),
  survived         integer not null check (survived >= 0),
  primary key (tenant_id, connection_id, cohort_month, interval_group, renewal_number)
);
comment on table cma.subscription_survival_take is
  'Renewal survival (addition 0009ze): per store, start cohort (the month the subscription was created in the app) and interval group, for renewal 1 to 24: the subscriptions started (purchased in the app; migrated ones are left out, their renewals before the app not being in its events), those whose own renewal of that number is due by now (eligible: its created date plus that many intervals has passed) and those that survived to it (survived: that many renewed cycles). A cell is mature when every started subscription is eligible; until then the page shows a dash';

select cma.setup_tenant_table('cma.subscription_take_state');
select cma.setup_tenant_table('cma.subscription_take');
select cma.setup_tenant_table('cma.subscription_month_take');
select cma.setup_tenant_table('cma.renewal_outcome');
select cma.setup_tenant_table('cma.subscription_store_start');
select cma.setup_tenant_table('cma.subscription_survival_take');
drop trigger if exists audit on cma.subscription_take_state;
drop trigger if exists audit on cma.subscription_take;
drop trigger if exists audit on cma.subscription_month_take;
drop trigger if exists audit on cma.renewal_outcome;
drop trigger if exists audit on cma.subscription_store_start;
drop trigger if exists audit on cma.subscription_survival_take;

-- The renewal outcomes of a tenant (C.3), computed fresh: one row per subscription and cycle with a renewed or a failed
-- renewal event (events without a cycle are left out), and one per invoice renewal (an invoice placed, by its renewal id)
create or replace function cma.renewal_outcomes_of(p_tenant_id uuid)
returns table (connection_id uuid, subscription_source_id text, renewal_key text, cycle_index integer, renewal_source_id text,
               first_attempt_at timestamptz, outcome text, attempts integer, recovered_at timestamptz, days_to_recover numeric,
               error_code text, instrument_type text, payment_method_changed_before_recovery boolean)
language sql stable
rows 50000
as $$
  with a as (
    select e.connection_id, e.subscription_source_id, e.cycle_index,
           min(e.occurred_at) as first_at,
           min(e.occurred_at) filter (where e.event_type = 'renew_failed') as first_failed_at,
           min(e.occurred_at) filter (where e.event_type = 'renewed') as renewed_at,
           count(*) filter (where e.event_type = 'renew_failed') as failures,
           (array_agg(e.error_code order by e.occurred_at, e.source_id collate "C") filter (where e.event_type = 'renew_failed'))[1] as error_code,
           (array_agg(e.order_source_id order by e.occurred_at, e.source_id collate "C") filter (where e.event_type = 'renewed'))[1] as order_source_id
    from cma.subscription_event e
    where e.tenant_id = p_tenant_id and e.event_type in ('renewed', 'renew_failed') and e.cycle_index is not null
    group by 1, 2, 3
  ), cyc as (
    select a.connection_id, a.subscription_source_id, 'cycle:' || a.cycle_index as renewal_key, a.cycle_index, null::text as renewal_source_id,
           a.first_at,
           case when a.renewed_at is not null and exists (
                       select 1 from cma.billing_event b
                       where b.tenant_id = p_tenant_id and b.connection_id = a.connection_id and b.kind = 'chargeback'
                         and b.order_source_id = a.order_source_id) then 'charged_back'
                when a.renewed_at is not null and a.failures = 0 then 'paid_first_attempt'
                when a.renewed_at is not null then 'recovered'
                else 'not_recovered' end as outcome,
           (a.failures + case when a.renewed_at is not null then 1 else 0 end)::integer as attempts,
           case when a.failures > 0 then a.renewed_at end as recovered_at,
           case when a.failures > 0 and a.renewed_at is not null
                then round((extract(epoch from a.renewed_at - a.first_failed_at) / 86400)::numeric, 1) end as days_to_recover,
           a.error_code,
           case when a.failures > 0 and a.renewed_at is not null then exists (
                  select 1 from cma.subscription_event p
                  where p.tenant_id = p_tenant_id and p.connection_id = a.connection_id and p.subscription_source_id = a.subscription_source_id
                    and p.event_type = 'payment_method_changed' and p.occurred_at > a.first_failed_at and p.occurred_at < a.renewed_at) end as pm_changed
    from a
  ), inv as (
    select b.connection_id, b.renewal_source_id,
           coalesce(max(b.subscription_source_id),
                    (select min(x.source_id) from cma.subscription x
                     where x.tenant_id = p_tenant_id and x.connection_id = b.connection_id and x.customer_source_id = min(b.customer_source_id)
                       and x.source_deleted_at is null
                     having count(*) = 1)) as subscription_source_id,
           min(b.occurred_at) filter (where b.kind = 'invoice_placed') as placed_at,
           min(b.occurred_at) filter (where b.kind = 'invoice_paid') as paid_at,
           count(*) filter (where b.kind = 'invoice_payment_failed') as failures
    from cma.billing_event b
    where b.tenant_id = p_tenant_id and b.kind like 'invoice\_%' and b.renewal_source_id is not null
    group by 1, 2
  )
  select c.connection_id, c.subscription_source_id, c.renewal_key, c.cycle_index, c.renewal_source_id, c.first_at, c.outcome, c.attempts,
         c.recovered_at, c.days_to_recover, c.error_code, s.payment_instrument_type, c.pm_changed
  from cyc c
  left join cma.subscription s on s.tenant_id = p_tenant_id and s.connection_id = c.connection_id and s.source_id = c.subscription_source_id
  union all
  select i.connection_id, i.subscription_source_id, 'invoice:' || i.renewal_source_id, null, i.renewal_source_id, i.placed_at,
         case when i.paid_at is not null then 'invoice_paid' else 'invoice_open' end,
         (1 + i.failures)::integer, null, null, null, s.payment_instrument_type, null
  from inv i
  left join cma.subscription s on s.tenant_id = p_tenant_id and s.connection_id = i.connection_id and s.source_id = i.subscription_source_id
  where i.placed_at is not null and i.subscription_source_id is not null
$$;
alter function cma.renewal_outcomes_of(uuid) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 8. The refresh (C.9): the minute job's second step, after Customers → Active's
-- ---------------------------------------------------------------------------------------------
create or replace function cma.subscription_facts_lock_key(p_tenant_id uuid)
returns bigint
language sql immutable
as $$ select hashtextextended('cma.subscription_facts:' || p_tenant_id::text, 0) $$;

-- The digest of everything the facts are computed from: the tables' markers, the settings they read and the business
-- date (the running month, overdue invoices and the eligible survival cells move with it)
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
    p_today::text))
$$;

-- Compute the tenant's subscription facts again (C.9): skipped while its take is younger than
-- subscriptions.take_refresh_minutes (reason fresh) unless forced, when its subscriptions source is not set up (not_set_up,
-- and the stored rows go), when another refresh of the tenant holds its lock (running), or when the inputs' digest is the
-- take's (unchanged: only the take's moment moves). Otherwise, in this order: each subscription's device units written to
-- cma.subscription where they read differently (C.1); every take row written again. Answers what it did
create or replace function cma.subscription_facts_refresh_of(p_tenant_id uuid, p_force boolean default false, p_now timestamptz default null)
returns jsonb
language plpgsql
as $$
declare
  v_now      timestamptz := coalesce(p_now, clock_timestamp());
  v_t0       timestamptz := clock_timestamp();
  v_zone     text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_today    date;
  v_month    date;
  v_every    integer := cma.setting_of(p_tenant_id, 'subscriptions.take_refresh_minutes')::integer;
  v_holding  text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.device_holding_statuses'));
  v_state    cma.subscription_take_state;
  v_found    boolean;
  v_set_up   boolean;
  v_key      text;
  v_amounts  timestamptz := (select m.applied_at from cma.schema_migration m where m.version = '0009za');
  n_units    integer := 0;
  n_subs     integer := 0;
  n_months   integer := 0;
  n_outcomes integer := 0;
  n_cells    integer := 0;
begin
  if p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a take is refreshed for the current tenant only' using errcode = 'CMA04';
  end if;
  select * into v_state from cma.subscription_take_state t where t.tenant_id = p_tenant_id;
  v_found := found;
  select coalesce(cma.flash_source_set_up_of(p_tenant_id, 'subscriptions'), false) into v_set_up;
  if not v_set_up then
    if v_found then
      if not pg_try_advisory_xact_lock(cma.subscription_facts_lock_key(p_tenant_id)) then
        return jsonb_build_object('refreshed', false, 'reason', 'running');
      end if;
      delete from cma.subscription_survival_take x where x.tenant_id = p_tenant_id;
      delete from cma.renewal_outcome x where x.tenant_id = p_tenant_id;
      delete from cma.subscription_month_take x where x.tenant_id = p_tenant_id;
      delete from cma.subscription_store_start x where x.tenant_id = p_tenant_id;
      delete from cma.subscription_take x where x.tenant_id = p_tenant_id;
      delete from cma.subscription_take_state x where x.tenant_id = p_tenant_id;
    end if;
    return jsonb_build_object('refreshed', false, 'reason', 'not_set_up');
  end if;
  if not p_force and v_found and v_now - v_state.computed_at < make_interval(mins => v_every) then
    return jsonb_build_object('refreshed', false, 'reason', 'fresh');
  end if;
  if not pg_try_advisory_xact_lock(cma.subscription_facts_lock_key(p_tenant_id)) then
    return jsonb_build_object('refreshed', false, 'reason', 'running');
  end if;
  select * into v_state from cma.subscription_take_state t where t.tenant_id = p_tenant_id;
  v_found := found;
  v_today := (v_now at time zone v_zone)::date;
  v_month := date_trunc('month', v_today)::date;
  v_key := cma.subscription_facts_inputs_key_of(p_tenant_id, v_today);
  if not p_force and v_found and v_state.inputs_key = v_key then
    update cma.subscription_take_state t
    set computed_at = v_now, duration_ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer
    where t.tenant_id = p_tenant_id;
    return jsonb_build_object('refreshed', true, 'unchanged', true, 'rows', 0,
                              'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
  end if;

  -- 1. device units (C.1): computed once, written to the mirror where they read differently (step 3 reads them from here)
  create temporary table if not exists subscription_facts_units (subscription_id uuid primary key, device_units integer, propositions text[],
                                                                  models text[]) on commit drop;
  delete from subscription_facts_units;
  insert into subscription_facts_units select * from cma.subscription_device_units_of(p_tenant_id);
  update cma.subscription x
  set device_units = u.device_units
  from subscription_facts_units u
  where x.tenant_id = p_tenant_id and x.id = u.subscription_id and x.device_units is distinct from u.device_units;
  get diagnostics n_units = row_count;

  -- 2. renewal outcomes (C.3), first: the subscriptions' renewals are counted from them
  delete from cma.renewal_outcome x where x.tenant_id = p_tenant_id;
  insert into cma.renewal_outcome (tenant_id, connection_id, subscription_source_id, renewal_key, cycle_index, renewal_source_id, first_attempt_at,
                                   outcome, attempts, recovered_at, days_to_recover, error_code, instrument_type,
                                   payment_method_changed_before_recovery)
  select p_tenant_id, r.* from cma.renewal_outcomes_of(p_tenant_id) r;
  get diagnostics n_outcomes = row_count;

  -- 3. per subscription
  delete from cma.subscription_take x where x.tenant_id = p_tenant_id;
  insert into cma.subscription_take (tenant_id, subscription_id, connection_id, source_id, market, status, payment_state, state_since, overdue,
                                     chargeback_return_code, amount_at_risk, currency, monthly_amount, interval_group, device_units,
                                     propositions, models, original_start_at, original_start_basis, cohort_month, migrated, renewals)
  with sm as materialized (
    select y.connection_id, y.store_connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y
  ), ps as materialized (
    select * from cma.subscription_payment_state_of(p_tenant_id)
  ), du as materialized (
    select * from subscription_facts_units
  ), mig as materialized (
    select distinct e.connection_id, e.subscription_source_id
    from cma.subscription_event e
    where e.tenant_id = p_tenant_id and e.event_type = 'migrated'
  ), ren as materialized (
    -- the cycles renewed (step 2's outcomes that renewed)
    select r.connection_id, r.subscription_source_id, count(*) as renewals
    from cma.renewal_outcome r
    where r.tenant_id = p_tenant_id and r.cycle_index is not null and r.outcome in ('paid_first_attempt', 'recovered', 'charged_back')
    group by 1, 2
  ), fo as materialized (
    -- the store customer's earliest store order (not a test, not deleted), per store and customer
    select o.connection_id, o.customer_source_id, min(o.source_created_at) as first_at
    from cma.commerce_order o
    where o.tenant_id = p_tenant_id and o.is_test is not true and o.source_deleted_at is null and o.customer_source_id is not null
      and o.connection_id in (select sm.store_connection_id from sm)
    group by 1, 2
  ), b as (
    select x.id, x.connection_id, x.source_id, coalesce(sm.market, 'unknown') as market, x.status, ps.payment_state, ps.state_since, ps.overdue,
           ps.chargeback_return_code, ps.amount_at_risk, x.currency,
           x.amount_per_cycle * cma.active_month_factor_of(x.billing_interval, x.billing_interval_count) as monthly_amount,
           cma.subscription_interval_group_of(x.billing_interval, x.billing_interval_count) as interval_group,
           du.device_units, coalesce(du.propositions, '{}') as propositions, coalesce(du.models, '{}') as models,
           case when fo.first_at <= x.source_created_at then fo.first_at else x.source_created_at end as original_start_at,
           case when fo.first_at <= x.source_created_at then 'first_order' when x.source_created_at is not null then 'created' end as basis,
           mig.subscription_source_id is not null as migrated, coalesce(ren.renewals, 0)::integer as renewals
    from cma.subscription x
    left join sm on sm.connection_id = x.connection_id
    left join ps on ps.subscription_id = x.id
    left join du on du.subscription_id = x.id
    left join mig on mig.connection_id = x.connection_id and mig.subscription_source_id = x.source_id
    left join ren on ren.connection_id = x.connection_id and ren.subscription_source_id = x.source_id
    left join fo on fo.connection_id = sm.store_connection_id and fo.customer_source_id = x.customer_source_id
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null
  )
  select p_tenant_id, b.id, b.connection_id, b.source_id, b.market, b.status, b.payment_state, b.state_since, b.overdue,
         b.chargeback_return_code, b.amount_at_risk, b.currency, b.monthly_amount, b.interval_group, b.device_units, b.propositions, b.models,
         b.original_start_at, b.basis, date_trunc('month', b.original_start_at at time zone v_zone)::date, b.migrated, b.renewals
  from b;
  get diagnostics n_subs = row_count;

  -- 4a. when each store's rates start (C.5)
  delete from cma.subscription_store_start x where x.tenant_id = p_tenant_id;
  insert into cma.subscription_store_start (tenant_id, connection_id, market, first_event_month, migration_months, last_migration_month,
                                            straggler_months, stragglers, rate_start_month)
  select p_tenant_id, r.connection_id, coalesce(sm.market, 'unknown'), r.first_event_month, r.migration_months, r.last_migration_month,
         r.straggler_months, r.stragglers, r.rate_start_month
  from cma.subscription_rate_start_of(p_tenant_id, v_now) r
  left join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y) sm on sm.connection_id = r.connection_id;

  -- 4. per store and month (C.4, C.5): the status moves, the base at each month's start and end, the observed amount
  --    changes; months from the store's first event to the current one
  delete from cma.subscription_month_take x where x.tenant_id = p_tenant_id;
  insert into cma.subscription_month_take (tenant_id, connection_id, market, month, kind, currency, subscriptions, amount, complete)
  with sm as materialized (
    select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y
  ), mv as materialized (
    select * from cma.subscription_moves_of(p_tenant_id, v_now)
  ), first_ev as materialized (
    -- the store's first event's month and the month its rates start (step 4a)
    select x.connection_id, x.first_event_month as first_month, x.rate_start_month as first_complete
    from cma.subscription_store_start x
    where x.tenant_id = p_tenant_id
  ), months as materialized (
    select f.connection_id, g::date as month, f.first_complete
    from first_ev f
    cross join lateral generate_series(f.first_month, v_month, interval '1 month') g
  ), spans as materialized (
    -- each subscription's status from each move to the next
    select m.subscription_id, m.connection_id, m.status_to as status, m.at as from_at,
           lead(m.at) over (partition by m.subscription_id order by m.at, m.kind nulls first) as to_at
    from mv m
  ), x as materialized (
    select s.id, s.connection_id, s.source_id, s.amount_per_cycle, s.currency, s.billing_interval, s.billing_interval_count
    from cma.subscription s where s.tenant_id = p_tenant_id and s.source_deleted_at is null
  ), lc as materialized (
    -- each subscription's latest observed change of its amount, interval or currency: before it the amount is taken back
    -- through the changes (cma.subscription_amount_at), after it (or without one) it is the stored one
    select c.connection_id, c.subscription_source_id, max(c.observed_at) as last_at
    from cma.subscription_change c
    where c.tenant_id = p_tenant_id and c.field in ('amount_per_cycle', 'billing_interval', 'billing_interval_count', 'currency')
    group by 1, 2
  ), af as materialized (
    -- amounts are known from each connection's first load on (rule 12): the later of the observed changes' start (0009za)
    -- and the first time the CMA held a subscription of the connection
    select s.connection_id, greatest(v_amounts, min(s.first_seen_at)) as amounts_from
    from cma.subscription s where s.tenant_id = p_tenant_id
    group by 1
  ), bounds as materialized (
    select mo.connection_id, mo.month, k.kind, k.boundary
    from months mo
    cross join lateral (values ('start', (mo.month::timestamp at time zone v_zone)),
                               ('end', least(((mo.month + interval '1 month')::timestamp at time zone v_zone), v_now))) k(kind, boundary)
  ), base_counts as (
    -- the Total subscriptions (a device-holding status) at each month's start and end: a running sum per store over the
    -- spans in such a status, +1 where one begins, -1 where it ends, read at each boundary before the changes at its
    -- moment (the status just before it: a move at the very start of a month is that month's movement)
    select r.connection_id, r.month, r.kind, r.n
    from (
      select z.connection_id, z.month, z.kind,
             sum(z.d) over (partition by z.connection_id order by z.at, z.kind nulls last rows between unbounded preceding and current row) as n
      from (
        select sp.connection_id, sp.from_at as at, 1 as d, null::text as kind, null::date as month
        from spans sp where sp.status = any (v_holding)
        union all
        select sp.connection_id, sp.to_at, -1, null, null
        from spans sp where sp.status = any (v_holding) and sp.to_at is not null
        union all
        select b.connection_id, b.boundary, 0, b.kind, b.month from bounds b
      ) z
    ) r
    where r.kind is not null
  ), base as (
    -- the members of the Total subscriptions at the boundaries from the first load on, for their monthly amounts
    select b.connection_id, b.month, b.kind, sp.subscription_id, b.boundary
    from bounds b
    join spans sp on sp.connection_id = b.connection_id and sp.from_at < b.boundary and (sp.to_at is null or sp.to_at >= b.boundary)
                 and sp.status = any (v_holding)
    join af on af.connection_id = b.connection_id
    where v_amounts is not null and b.boundary >= af.amounts_from
  ), moved as (
    select m.connection_id, (date_trunc('month', m.at at time zone v_zone))::date as month, m.kind, m.subscription_id,
           case when m.kind in ('new', 'migrated', 'reactivated', 'resumed') then m.at else m.at - interval '1 microsecond' end as boundary
    from mv m
    where m.kind is not null
  ), amounted as (
    -- the observed changes of amount or interval (C.4): expansion or contraction where the monthly amount rose or fell
    -- in one currency, without a status move observed in the same read
    select c.connection_id, x.id as subscription_id, c.observed_at
    from cma.subscription_change c
    join x on x.connection_id = c.connection_id and x.source_id = c.subscription_source_id
    where c.tenant_id = p_tenant_id and c.field in ('amount_per_cycle', 'billing_interval', 'billing_interval_count') and c.observed_at <= v_now
      and not exists (select 1 from cma.subscription_change z
                      where z.tenant_id = p_tenant_id and z.connection_id = c.connection_id and z.subscription_source_id = c.subscription_source_id
                        and z.field = 'status' and z.observed_at = c.observed_at)
    group by 1, 2, 3
  ), changed as (
    select a.connection_id, (date_trunc('month', a.observed_at at time zone v_zone))::date as month,
           case when after.monthly_amount > before.monthly_amount then 'expansion' else 'contraction' end as kind,
           a.subscription_id, after.currency, abs(after.monthly_amount - before.monthly_amount) as amount
    from amounted a
    join x on x.id = a.subscription_id
    cross join lateral cma.subscription_amount_at(p_tenant_id, a.connection_id, x.source_id, a.observed_at - interval '1 microsecond',
                                                  x.amount_per_cycle, x.currency, x.billing_interval, x.billing_interval_count) before
    cross join lateral cma.subscription_amount_at(p_tenant_id, a.connection_id, x.source_id, a.observed_at,
                                                  x.amount_per_cycle, x.currency, x.billing_interval, x.billing_interval_count) after
    where before.currency = after.currency and before.monthly_amount is distinct from after.monthly_amount
      and before.monthly_amount is not null and after.monthly_amount is not null
  ), counted as (
    select b.connection_id, b.month, b.kind, b.subscription_id, b.boundary from base b
    union all
    select m.connection_id, m.month, m.kind, m.subscription_id, m.boundary from moved m
  ), valued as (
    select c.connection_id, c.month, c.kind, c.subscription_id,
           case when l.last_at > c.boundary then am.currency else x.currency end as currency,
           case when l.last_at > c.boundary then am.monthly_amount
                else x.amount_per_cycle * cma.active_month_factor_of(x.billing_interval, x.billing_interval_count) end as monthly_amount
    from counted c
    join x on x.id = c.subscription_id
    left join lc l on l.connection_id = x.connection_id and l.subscription_source_id = x.source_id
    left join lateral (select y.* from cma.subscription_amount_at(p_tenant_id, c.connection_id, x.source_id, c.boundary,
                                                                  x.amount_per_cycle, x.currency, x.billing_interval, x.billing_interval_count) y
                       where l.last_at > c.boundary) am on true
    join af on af.connection_id = c.connection_id
    where v_amounts is not null and c.boundary >= af.amounts_from
    union all
    select ch.connection_id, ch.month, ch.kind, ch.subscription_id, ch.currency, ch.amount from changed ch
  ), rows_ as (
    select bc.connection_id, bc.month, bc.kind, ''::text as currency, bc.n::integer as n, null::numeric as amount
    from base_counts bc
    union all
    select m.connection_id, m.month, m.kind, '', count(*)::integer, null from moved m group by 1, 2, 3
    union all
    select ch.connection_id, ch.month, ch.kind, '', count(*)::integer, null from changed ch group by 1, 2, 3
    union all
    select v.connection_id, v.month, v.kind, v.currency, count(*)::integer, round(sum(v.monthly_amount), 2)
    from valued v where v.currency is not null and v.monthly_amount is not null
    group by 1, 2, 3, 4
  )
  select p_tenant_id, r.connection_id, coalesce(sm.market, 'unknown'), r.month, r.kind, r.currency, r.n, r.amount,
         r.month < v_month and r.month >= f.first_complete
  from rows_ r
  join first_ev f on f.connection_id = r.connection_id
  left join sm on sm.connection_id = r.connection_id
  where r.month >= f.first_month and r.month <= v_month;
  get diagnostics n_months = row_count;

  -- 5. renewal survival (C.6): subscriptions purchased in the app (not migrated) by start cohort and interval group; the
  --    start is the subscription's own in the app (its created date), never the estimated original start, whose first
  --    store order may be another subscription's of the same customer
  delete from cma.subscription_survival_take x where x.tenant_id = p_tenant_id;
  insert into cma.subscription_survival_take (tenant_id, connection_id, market, cohort_month, interval_group, renewal_number, started, eligible, survived)
  select p_tenant_id, t.connection_id, t.market, date_trunc('month', s.source_created_at at time zone v_zone)::date, t.interval_group, n.n, count(*)::integer,
         count(*) filter (where s.source_created_at + make_interval(
                                   months => case s.billing_interval when 'month' then s.billing_interval_count * n.n
                                                                     when 'year' then 12 * s.billing_interval_count * n.n else 0 end,
                                   days => case s.billing_interval when 'day' then s.billing_interval_count * n.n
                                                                   when 'week' then 7 * s.billing_interval_count * n.n else 0 end) <= v_now)::integer,
         count(*) filter (where t.renewals >= n.n)::integer
  from cma.subscription_take t
  join cma.subscription s on s.tenant_id = t.tenant_id and s.id = t.subscription_id
  cross join generate_series(1, 24) n(n)
  where t.tenant_id = p_tenant_id and not t.migrated and s.source_created_at is not null and s.billing_interval is not null
    and s.billing_interval_count is not null
  group by t.connection_id, t.market, date_trunc('month', s.source_created_at at time zone v_zone)::date, t.interval_group, n.n;
  get diagnostics n_cells = row_count;

  -- 6. the take's row
  insert into cma.subscription_take_state as t (tenant_id, computed_at, business_date, duration_ms, inputs_key, subscriptions, amounts_from)
  values (p_tenant_id, v_now, v_today, (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer, v_key, n_subs, v_amounts)
  on conflict (tenant_id) do update
    set computed_at = excluded.computed_at, business_date = excluded.business_date, duration_ms = excluded.duration_ms,
        inputs_key = excluded.inputs_key, subscriptions = excluded.subscriptions, amounts_from = excluded.amounts_from;

  return jsonb_build_object('refreshed', true, 'unchanged', false, 'device_units_written', n_units, 'subscription_rows', n_subs,
                            'month_rows', n_months, 'outcome_rows', n_outcomes, 'survival_rows', n_cells,
                            'rows', n_subs + n_months + n_outcomes + n_cells,
                            'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
end
$$;
alter function cma.subscription_facts_refresh_of(uuid, boolean, timestamptz) set jit = off;

-- The job's entry (the minute job refresh_active_customers, after Customers → Active's take): customers.refresh, as
-- Active's own
create or replace function cma.subscription_facts_refresh()
returns jsonb
language plpgsql
as $$
begin
  perform cma.assert_permission('customers.refresh');
  return cma.subscription_facts_refresh_of(cma.current_tenant_id());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Readers (C.9): plain views of the stored takes for BigQuery and analytics, and the payment state's reader again
-- ---------------------------------------------------------------------------------------------
-- The payment state of every subscription of every tenant the reader sees, with the columns of the second version:
-- SECURITY DEFINER in cma_read, owned by cma_owner, search path pinned, executable by readers only. Ids, states, codes,
-- amounts and times only
-- based on: 118_subscriptions.sql
create or replace function cma_read.subscription_payment_state_rows()
returns table (tenant_id uuid, subscription_id uuid, connection_id uuid, source_id text, customer_source_id text, status text,
               payment_state text, retry_cycle integer, retry_since timestamptz, last_attempt integer, state_since timestamptz,
               overdue boolean, chargeback_return_code text, amount_at_risk numeric, currency text)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, p.subscription_id, p.connection_id, p.source_id, p.customer_source_id, p.status, p.payment_state, p.retry_cycle,
         p.retry_since, p.last_attempt, p.state_since, p.overdue, p.chargeback_return_code, p.amount_at_risk, p.currency
  from cma.tenant t
  cross join lateral cma.subscription_payment_state_of(t.id) p
  where cma_read.reader_sees(t.id)
$$;
revoke execute on function cma_read.subscription_payment_state_rows() from public;
grant execute on function cma_read.subscription_payment_state_rows() to cma_readonly;

create or replace view cma_read.subscription_payment_state as
  select * from cma_read.subscription_payment_state_rows();

create or replace view cma_read.subscription_take as
  select t.tenant_id, t.subscription_id, t.connection_id, t.source_id, t.market, t.status, t.payment_state, t.state_since, t.overdue,
         t.chargeback_return_code, t.amount_at_risk, t.currency, t.monthly_amount, t.interval_group, t.device_units, t.propositions, t.models,
         t.original_start_at, t.original_start_basis, t.cohort_month, t.migrated, t.renewals, st.computed_at
  from cma.subscription_take t
  join cma.subscription_take_state st on st.tenant_id = t.tenant_id
  where cma_read.reader_sees(t.tenant_id);
comment on view cma_read.subscription_take is
  'Per present subscription of every tenant the reader sees (addition 0009ze): payment state and its detail, monthly amount, interval group, device units, propositions and models, the original start (estimated) with its basis, the start cohort, migrated and renewals, as the latest take computed them (computed_at). Ids, codes, amounts and times only: no customer and no contact';

create or replace view cma_read.subscription_month_take as
  select m.tenant_id, m.connection_id, m.market, m.month, m.kind, m.currency, m.subscriptions, m.amount, m.complete
  from cma.subscription_month_take m
  where cma_read.reader_sees(m.tenant_id);
comment on view cma_read.subscription_month_take is
  'Per store and calendar month of every tenant the reader sees (addition 0009ze): the Total subscriptions at the month''s start and end and the recurring amount movements by kind; currency empty holds counts (from the store''s first event), a currency the monthly amounts of the movements known from the first load on; complete marks the months the Churn rate and the Failed rate count. Counts and amounts only';

create or replace view cma_read.subscription_churn_month as
  select m.tenant_id, m.market, m.month,
         sum(m.subscriptions) filter (where m.kind = 'start')::bigint as base,
         coalesce(sum(m.subscriptions) filter (where m.kind = 'churned'), 0)::bigint as churned,
         coalesce(sum(m.subscriptions) filter (where m.kind = 'moved_to_failed'), 0)::bigint as moved_to_failed,
         round(coalesce(sum(m.subscriptions) filter (where m.kind = 'churned'), 0)::numeric
               / nullif(sum(m.subscriptions) filter (where m.kind = 'start'), 0), 4) as churn_rate,
         round(coalesce(sum(m.subscriptions) filter (where m.kind = 'moved_to_failed'), 0)::numeric
               / nullif(sum(m.subscriptions) filter (where m.kind = 'start'), 0), 4) as failed_rate
  from cma.subscription_month_take m
  where m.currency = '' and m.complete and cma_read.reader_sees(m.tenant_id)
  group by m.tenant_id, m.market, m.month;
comment on view cma_read.subscription_churn_month is
  'The Churn rate and the Failed rate per market and complete month of every tenant the reader sees (addition 0009ze): the subscriptions churned and moved to failed in the month over the Total subscriptions at the previous month end, over the stores whose rates have started by it (cma_read.subscription_store_start). A share of 1 is 100 %';

create or replace view cma_read.subscription_store_start as
  select x.tenant_id, x.connection_id, x.market, x.first_event_month, x.migration_months, x.last_migration_month, x.straggler_months,
         x.stragglers, x.rate_start_month
  from cma.subscription_store_start x
  where cma_read.reader_sees(x.tenant_id);
comment on view cma_read.subscription_store_start is
  'Per store of every tenant the reader sees (addition 0009ze): its migrated events per month, the last month of its migration, its stragglers and the month its Churn rate and Failed rate start. Counts and months only';

create or replace view cma_read.renewal_outcome as
  select r.tenant_id, r.connection_id, r.subscription_source_id, r.renewal_key, r.cycle_index, r.renewal_source_id, r.first_attempt_at,
         r.outcome, r.attempts, r.recovered_at, r.days_to_recover, r.error_code, r.instrument_type, r.payment_method_changed_before_recovery
  from cma.renewal_outcome r
  where cma_read.reader_sees(r.tenant_id);
comment on view cma_read.renewal_outcome is
  'Per subscription and cycle with a renewal attempt, and per invoice renewal, of every tenant the reader sees (addition 0009ze): the outcome, attempts and recovery. Ids, codes and times only';

create or replace view cma_read.subscription_survival as
  select v.tenant_id, v.connection_id, v.market, v.cohort_month, v.interval_group, v.renewal_number, v.started, v.eligible, v.survived,
         v.eligible = v.started as mature
  from cma.subscription_survival_take v
  where cma_read.reader_sees(v.tenant_id);
comment on view cma_read.subscription_survival is
  'Renewal survival per store, start cohort, interval group and renewal number of every tenant the reader sees (addition 0009ze): started, eligible, survived (renewed that many times) and whether the cell is mature (every started subscription eligible). Counts only';

-- ---------------------------------------------------------------------------------------------
-- 10. The one-time fill of the purchases' store orders (C.0, linking)
-- ---------------------------------------------------------------------------------------------
-- A purchase stored before 0009zc carries no store order (the events table is append-only, and the ingest leaves an
-- event it holds as it is). The ingest's backfill --object purchase_order reads the app's purchase events again and
-- hands their orders here: a purchased event of the connection whose raw holds no orderId gains it and a new synced_at
-- (so the takes' input markers see the change), nothing else of it changes, and an event that holds one keeps it. SECURITY DEFINER (the application may not update an event), after the
-- ingest's own check of the connection and its permission (ingest.write); owned by cma_owner, search path pinned,
-- executable by the application only. Answers the events filled. Audited (the events' audit trigger)
create or replace function cma.ingest_fill_purchase_orders(p_connection_id uuid, p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, cma, pg_temp
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_target record;
  v_n      integer;
begin
  select * into v_target from cma.subscriptions_ingest_target(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500
     or exists (select 1 from jsonb_array_elements(p_items) x
                where jsonb_typeof(x) <> 'object' or not coalesce(cma.subscription_id_ok(x ->> 'sourceId'), false)
                   or coalesce(x ->> 'orderSourceId', '') !~ '^\d{1,30}$') then
    raise exception 'items must be an array of at most 500 purchases, each a sourceId and an orderSourceId of digits' using errcode = 'CMA04';
  end if;
  update cma.subscription_event e
  set raw = e.raw || jsonb_build_object('orderId', x.order_id), synced_at = clock_timestamp()
  from (select distinct on (y ->> 'sourceId') y ->> 'sourceId' as source_id, y ->> 'orderSourceId' as order_id
        from jsonb_array_elements(p_items) y order by y ->> 'sourceId', y ->> 'orderSourceId') x
  where e.tenant_id = v_tenant and e.connection_id = p_connection_id and e.source_id = x.source_id and e.event_type = 'purchased'
    and (e.raw ->> 'orderId') is null;
  get diagnostics v_n = row_count;
  return v_n;
end
$$;
revoke execute on function cma.ingest_fill_purchase_orders(uuid, jsonb) from public;
grant execute on function cma.ingest_fill_purchase_orders(uuid, jsonb) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 11. Grants: the application only (a function made again keeps its grants)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.payment_states()', 'cma.subscription_payment_state_of(uuid)', 'cma.subscription_payment_state_of(uuid,uuid[])',
    'cma.set_subscription_variant_mapping(uuid,text,text,text,integer,text)', 'cma.subscription_variants_of(uuid,uuid)',
    'cma.subscription_variants(uuid)', 'cma.subscription_device_units_of(uuid)', 'cma.inputs_markers_of(uuid,text[])',
    'cma.subscription_interval_group_of(text,integer)',
    'cma.subscription_amount_at(uuid,uuid,text,timestamptz,numeric,text,text,integer)', 'cma.subscription_moves_of(uuid,timestamptz)',
    'cma.renewal_outcomes_of(uuid)', 'cma.subscription_rate_start_of(uuid,timestamptz)', 'cma.subscription_facts_lock_key(uuid)', 'cma.subscription_facts_inputs_key_of(uuid,date)',
    'cma.subscription_facts_refresh_of(uuid,boolean,timestamptz)', 'cma.subscription_facts_refresh()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 12. Data quality: subscription_variant_unmapped and subscription_device_units_mismatch (C.1, C.8)
-- ---------------------------------------------------------------------------------------------
-- As 0008zt's (136), with the two checks of 0009ze
-- based on: 136_flash_insights.sql
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
    ('subscription_device_units_mismatch',       390, 'Subscriptions in a device-holding status whose device units differ from the devices in the field linked to them (more_paid or more_placed); one without any such device is active_subscription_without_device''s')
$$;

-- As 0009o's (178), with the two checks of 0009ze
-- based on: 178_job_reads.sql
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

-- As 0008zt's (136): the variant check while subscriptions are set up, the device check while both sources are
-- based on: 136_flash_insights.sql
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
         or (fc.check_key in ('subscription_customer_unmatched', 'subscription_variant_unmapped') and (s.src -> 'subscriptions' ->> 'set_up')::boolean)
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

-- As 0008zt's (136): the device check is fixed in the asset register; the variant check in the CMA (the default)
-- based on: 136_flash_insights.sql
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
    else 'cma' end
$$;

create or replace view cma_read.dq_subscription_variant_unmapped as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'subscription_variant_unmapped';

create or replace view cma_read.dq_subscription_device_units_mismatch as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'subscription_device_units_mismatch';

-- ---------------------------------------------------------------------------------------------
-- 13. Every stored take of Customers → Active computed again at the job's next run (its payment states changed)
-- ---------------------------------------------------------------------------------------------
-- As 184 did: the mark and its count, so a refresh that is running now does not clear it. Once: a rerun marks nothing
update cma.active_take t
set stale = true, stale_since = coalesce(t.stale_since, now()), stale_marks = t.stale_marks + 1
where not exists (select 1 from cma.schema_migration m where m.version = '0009ze');

-- ---------------------------------------------------------------------------------------------
-- 14. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009ze', 'The subscription facts (brief B39 continued, Part B39c): the settings subscriptions.propositions, subscriptions.take_refresh_minutes and subscriptions.migration_bulk_min_pct; cma.subscription_variant_mapping (line kind, model, devices per unit, proposition; tenant.configure, audited) with cma.set_subscription_variant_mapping and cma.subscription_variants(_of); device units on cma.subscription; cma.subscription_payment_state_of in both forms dropped and created with Charged back and Awaiting payment, state_since, overdue, chargeback_return_code, amount_at_risk and currency (cma.payment_states() orders them; Customers → Active''s mix and worst state read it; Flash''s subscriptions and installed base move to definition version 0009ze); cma.active_inputs_key_of over cma.inputs_markers_of (per table, in parallel) with the billing events; the takes cma.subscription_take_state, subscription_take, subscription_month_take (Total subscriptions at month start and end, recurring amount movements, complete months), renewal_outcome, subscription_survival_take and subscription_store_start (when each store''s rates start: the month after its last month of migrated events, else the first complete month), refreshed by cma.subscription_facts_refresh() after Customers → Active''s take; readers cma_read.subscription_take, subscription_month_take, subscription_churn_month, renewal_outcome, subscription_survival, subscription_store_start and the payment state''s new columns; data quality subscription_variant_unmapped and subscription_device_units_mismatch; cma.ingest_fill_purchase_orders for the one-time fill of purchases'' store orders')
on conflict (version) do nothing;

commit;
reset role;
