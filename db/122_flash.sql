-- =============================================================================================
-- 122_flash.sql: addition 0008zn, Flash: one-click overviews, daily snapshots, data quality and the watch
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: overviews, measures and checks are the CMA's own words, the
-- statuses that make a subscription active, the references a contact or a device must carry and every threshold are
-- tenant settings, and a source's system is named by its connection's kind and adapter (data values). Runs unchanged
-- in every database, after 120_lead_cohorts.sql (0008zm). Rerunnable, forward-only, in one transaction with a lock
-- timeout. Run as your own IAM login: dev first, then 123_verify_flash.sql (dev and prod), then 121_verify_lead_cohorts.sql,
-- 113_verify_assets.sql, 95_verify_attempts_for_sales.sql, 41_verify_lead_metrics.sql, 119_verify_subscriptions.sql,
-- 105_verify_reviews.sql and 81_verify_follow_up_snapshot.sql again (dev; the settings trigger as 0008zm with Flash's
-- settings, the data-quality redefinition, the contact upsert and the scheduler's role are made again here, their checks
-- unchanged); then 02_seed_pulse4all.sql again (Pulse4all Subscriptions' Flash settings); then prod, with 123, 113 and 02.
-- The web and the ingest of main read nothing this adds and run unchanged on it. The snapshot job (web image,
-- jobs/snapshot-flash.mjs) needs it, and the contact hold of the ingest of this change needs it: in prod the script runs
-- before either is deployed.
--
-- Why (Decision log, 1 November 2026): one place where an auditor, the CFO or the COO gets any of ten overviews in one
-- click, on screen and as a file, per market: now from the mirrors the CMA holds, and as of a past date from immutable
-- daily snapshots that start the day this runs (the mirrors keep current state only: history never written can never be
-- rebuilt). The same report shows where the data is incomplete or wrong, with the records to fix in the owning system,
-- and a deterministic watch flags unexpected movements after every snapshot. Ids, statuses, amounts, codes and links
-- only: no email, phone, name or address is stored, shown or put in a file.
--
-- What it adds
--   settings           flash.active_subscription_statuses (active), flash.snapshot_local_time (00:30),
--                      flash.id_list_retention_months (84), flash.watch_jump_pct (20), flash.watch_jump_min (10),
--                      flash.file_max_rows (50000), assets.required_refs and commerce.required_contact_refs (empty),
--                      flash.ended_subscription_statuses (canceled,expired; paused in neither list, no status in both);
--                      cma.check_tenant_setting() checks each (0008zm's branches unchanged)
--   permission         flash.snapshot: the scheduler's system user only (no assignable role), granted to every tenant's
--                      scheduler role here and by cma.ensure_scheduler_user() from now on
--   runs               sync_run.job gains flash_snapshot (no connection, as refresh_follow_up); cma.job_run_start() and
--                      cma.job_run_finish() write its row (flash.snapshot)
--   the overviews      cma.flash_overviews(): the eleven overviews (customers, subscriptions, installed_base, churn,
--                      orders, payments, open_deals, open_tickets, open_tasks, reviews, data_quality), each stock or flow,
--                      its source, its dims, its grouping sets, its measures, its headline and its sort keys. One base set
--                      per overview (cma.flash_customers_of, flash_subscriptions_of, flash_devices_of, flash_churn_of,
--                      flash_orders_of, flash_order_lines_of, flash_payments_of, flash_deals_of, flash_tickets_of,
--                      flash_tasks_of, flash_reviews_of, flash_findings_of) feeds both the figures and the rows, so a figure
--                      and its list never disagree; cma.flash_compute_of(tenant, overview, from, to, on) aggregates it
--                      into one row per grouping set (dims, measures): the totals ({}), per market and the breakdown.
--                      Stock figures are measured against a business date (on: today live, the snapshot's own date in a
--                      take): past due, due within three months, overdue and ages. Amounts are summed per currency only,
--                      never across currencies. A value a source writes freely (a SKU, a warehouse, a pipeline) that a
--                      snapshot cannot hold (an @, over 100 characters) is the value other (cma.flash_dim_of). A source
--                      the tenant has not set up gives no rows (cma.flash_sources_of: commerce, subscriptions, assets,
--                      crm, reviews, set up or not, the last successful read from sync_run)
--   snapshots          cma.flash_snapshot (tenant, business date, overview, dims, measures, definition_version,
--                      computed_at, run_id; one row per grouping set; dims and measures held to each overview's allow-list,
--                      no @), cma.flash_snapshot_ids (month end only: the ids of the active customers, the active
--                      subscriptions and every device, with connection, market and state) and cma.flash_snapshot_run (per
--                      tenant and date: due, started, finished, status succeeded, failed or missed, late, counts per
--                      overview, the sources' state and the settings, the dates missed before it, error, the watch's
--                      error). The application only reads them: every row is written by the take, with the owner's
--                      rights; the id lists' one delete is cma.flash_snapshot_ids_expire_of, in the take, after
--                      flash.id_list_retention_months from the tenant's today, written to the audit log
--   the take           cma.flash_snapshot_take(tenant) (flash.snapshot; SECURITY DEFINER, the application's one way to
--                      write): the latest due date (date D is due at D + 1 at flash.snapshot_local_time in the tenant's
--                      zone, so the hourly job takes each date once whatever the time), computed through
--                      cma.flash_compute_of as of that date and stored; the id lists on a month's last day; the watch
--                      in a subtransaction of its own (its failure is the run's watch_error, never the snapshot's); the
--                      run row, late when it starts more than an hour after the due time. A date that stopped being the
--                      latest due one without a take is recorded as missed by the next take. Idempotent: a date with a
--                      succeeded or missed run is never taken again, and a date missed is never invented
--   the watch          cma.flash_watch_finding: jump (a stock figure per market moved day over day by more than
--                      flash.watch_jump_pct and flash.watch_jump_min), flow_zero (a flow figure of a market that had a flow
--                      on each of the previous 7 days is zero), source_stale (a set-up source's last successful read is
--                      older than three times its cadence: its connection's poll interval setting, else the median gap
--                      of its runs over 7 days), snapshot_missing (the date before the one taken has no snapshot) and
--                      dq_rise (a data-quality check rose by more than the jump thresholds). A finding resolves itself on
--                      the first snapshot where its condition no longer holds; one open finding per kind, overview, dims
--                      and measure (two stale connections alike are one finding, counted)
--   reads              cma.flash_overview(overview, market, as_of, from, to), cma.flash_rows(overview, filters, sort,
--                      descending, limit, offset, as_of, from, to), cma.flash_page(market, as_of, from, to) (the landing:
--                      stored figures only, so it answers at once at any volume), cma.flash_headline(overview, market, from,
--                      to) (one card's live headline, asked per card after the landing), cma.flash_snapshots(from, to) and
--                      cma.flash_file_record(...) (who downloaded which overview with which filters, in the audit log):
--                      reports.view or performance.team (CMA06 otherwise); no figure per person exists. The large reads
--                      and the take run with jit off (section 14)
--   data quality       six checks: customer_required_ref_missing, device_required_ref_missing,
--                      subscription_customer_unmatched, active_subscription_without_device, device_subscription_ref_unknown,
--                      field_device_on_ended_subscription (cma.data_quality_flash_checks(), shown once their source is set
--                      up); cma.data_quality_of() and cma.data_quality() as 0008zi with them; cma.data_quality_rows(check,
--                      market, limit, offset) (reports.view or tenant.configure): every finding's ids with its market, the
--                      kind and adapter of the system where it is fixed and the record's link
--   contacts held      a CRM contact is also taken in while a commerce customer is linked to it (0008h), so its
--                      references stay fresh (cma.ingest_upsert_contacts as 0008u with it); the privacy deletion is
--                      unchanged: the ingest's forget (cma.ingest_contact_forget, then 0008h's
--                      cma.forget_commerce_contact_links) clears the contact and the store customers' link
--   readers            cma_read.flash_snapshot, flash_snapshot_run, flash_snapshot_ids (every column),
--                      cma_read.flash_watch_finding, and a cma_read.dq_ view per new check
--
-- Everything is SECURITY INVOKER and executable by the application only, with its permission checked inside, but
-- cma.flash_snapshot_take (SECURITY DEFINER, owned by cma_owner, search path pinned, the application's only; flash.snapshot
-- and the current tenant checked first) and the take's writers (cma.flash_snapshot_take_at, cma.flash_snapshot_ids_write_of,
-- cma.flash_snapshot_ids_expire_of, cma.flash_watch_of: the owner's alone, each checking flash.snapshot and the current
-- tenant too; a take at an instant other than now is the owner's only, 123). SQLSTATEs as before: CMA01 no acting user,
-- CMA02 not found, CMA03 conflict, CMA04 invalid, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zm') then
    raise exception 'addition 0008zm (120_lead_cohorts.sql) must run before 0008zn';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('flash.active_subscription_statuses', 'text', null, 'active',
     'The subscription statuses that make a subscription, and its store customer, active on Reports → Flash: one to six of active, canceled, expired, failed, merged and never-subscribed (paused never: a paused subscription is counted apart), none of flash.ended_subscription_statuses, comma-separated without spaces'),
  ('flash.ended_subscription_statuses', 'text', null, 'canceled,expired',
     'The subscription statuses that end a subscription on Reports → Flash: churn counts a move into one of them, and a device in the field on one is the data-quality finding field_device_on_ended_subscription. One to six of active, canceled, expired, failed, merged and never-subscribed (paused never), none of flash.active_subscription_statuses, comma-separated without spaces'),
  ('flash.snapshot_local_time', 'time', null, '00:30',
     'The time in the tenant''s zone from which a business date''s Flash snapshot is due: a date is due on the day after it at this time, and the hourly snapshot job takes the latest due date once (00:00 to 23:59). The stock figures are the mirrors'' state at the take, measured against the snapshot''s date'),
  ('flash.id_list_retention_months', 'integer', null, '84',
     'Months a month end''s frozen id lists (active customers, active subscriptions, devices) are kept before the snapshot job removes them (1 to 240)'),
  ('flash.watch_jump_pct', 'integer', null, '20',
     'The Flash watch flags a stock figure per market, or a data-quality check, that moved day over day by more than this share in percent (1 to 1000) and by more than flash.watch_jump_min'),
  ('flash.watch_jump_min', 'integer', null, '10',
     'The Flash watch flags a move only when it is more than this many in absolute terms too (0 to 1000000)'),
  ('flash.file_max_rows', 'integer', null, '50000',
     'The most rows one Flash list read or one Flash file holds (1 to 50000)'),
  ('assets.required_refs', 'text', null, '',
     'Named ids every device the asset register still holds must carry (names of its external_refs, comma-separated without spaces); a device lacking one is the data-quality finding device_required_ref_missing; empty: none'),
  ('commerce.required_contact_refs', 'text', null, '',
     'Reference systems the CRM contact of every store customer with an order must carry (contact ref systems, comma-separated without spaces); a contact lacking one is the data-quality finding customer_required_ref_missing; empty: none')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- A comma-separated list as an array: spaces removed, empty items left out; the empty text is the empty list
create or replace function cma.flash_list_of(p_value text)
returns text[]
language sql immutable
as $$
  select coalesce(array(select x from unnest(string_to_array(regexp_replace(coalesce(p_value, ''), '[[:space:]]+', '', 'g'), ',')) x
                        where x <> ''), '{}'::text[])
$$;

-- A list setting's form: every item matches p_pattern, each once, at most p_max items (none allowed when p_allow_empty)
create or replace function cma.flash_list_ok(p_value text, p_pattern text, p_max integer, p_allow_empty boolean)
returns boolean
language sql immutable
as $$
  select case when coalesce(p_value, '') = '' then p_allow_empty
              else p_value !~ ',,|^,|,$'
                   and cardinality(cma.flash_list_of(p_value)) between 1 and p_max
                   and cardinality(cma.flash_list_of(p_value)) = (select count(distinct x) from unnest(cma.flash_list_of(p_value)) x)
                   and not exists (select 1 from unnest(cma.flash_list_of(p_value)) x where x !~ p_pattern) end
$$;

-- As 0008zm (120_lead_cohorts.sql), with the nine Flash settings: the active and the ended statuses (one to six of the
-- subscription statuses but paused, never one in both lists), the snapshot time (not 24:00), the retention (1 to 240 months), the watch's share (1 to 1000) and minimum (0 to 1000000),
-- the rows of a file (1 to 50000), and the two lists of required references (names, each once, or empty)
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
                 'commerce.required_contact_refs') then
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
  elsif new.key in ('flash.active_subscription_statuses', 'flash.ended_subscription_statuses') then
    if not cma.flash_list_ok(new.value, '^(active|canceled|expired|failed|merged|never-subscribed)$', 6, false) then
      raise exception 'Setting % takes one to six of active, canceled, expired, failed, merged and never-subscribed (never paused), each once, comma-separated without spaces', new.key
        using errcode = 'CMA04';
    end if;
    if cma.flash_list_of(new.value) && cma.flash_list_of(cma.setting_of(new.tenant_id,
         case new.key when 'flash.active_subscription_statuses' then 'flash.ended_subscription_statuses' else 'flash.active_subscription_statuses' end)) then
      raise exception 'Setting % takes no status of %', new.key,
        case new.key when 'flash.active_subscription_statuses' then 'flash.ended_subscription_statuses' else 'flash.active_subscription_statuses' end
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
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The take's permission: the scheduler's system user, in every tenant
-- ---------------------------------------------------------------------------------------------
insert into cma.permission (key, description) values
  ('flash.snapshot', 'Take the daily Flash snapshot of the business date that just ended (the scheduler''s system user only; no default role)')
on conflict (key) do update set description = excluded.description;

-- 0008s's scheduler user, now with its three permissions
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
  values (p_tenant_id, v_role, 'workday.close_forgotten'), (p_tenant_id, v_role, 'follow_up.refresh'), (p_tenant_id, v_role, 'flash.snapshot')
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

-- ---------------------------------------------------------------------------------------------
-- 3. sync_run: the take's run row, without a connection
-- ---------------------------------------------------------------------------------------------
alter table cma.sync_run drop constraint if exists sync_run_job_check;
alter table cma.sync_run add constraint sync_run_job_check
  check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls', 'email_poll', 'close_forgotten_workdays',
                 'refresh_follow_up', 'reviews_poll', 'legacy_call_import', 'assets_import', 'assets_poll', 'subscriptions_poll',
                 'flash_snapshot')) not valid;
alter table cma.sync_run validate constraint sync_run_job_check;
alter table cma.sync_run drop constraint if exists sync_run_connection_check;
alter table cma.sync_run add constraint sync_run_connection_check
  check ((connection_id is null) = (job in ('close_forgotten_workdays', 'refresh_follow_up', 'flash_snapshot'))) not valid;
alter table cma.sync_run validate constraint sync_run_connection_check;

-- As 0008s (80), with flash_snapshot (flash.snapshot)
create or replace function cma.job_permission_of(p_job text)
returns text
language sql immutable
as $$
  select case p_job when 'close_forgotten_workdays' then 'workday.close_forgotten' when 'refresh_follow_up' then 'follow_up.refresh'
                    when 'flash_snapshot' then 'flash.snapshot' end
$$;

create or replace function cma.job_run_start(p_job text)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  if cma.job_permission_of(p_job) is null then
    raise exception 'job must be close_forgotten_workdays, refresh_follow_up or flash_snapshot' using errcode = 'CMA04';
  end if;
  perform cma.assert_permission(cma.job_permission_of(p_job));
  insert into cma.sync_run (tenant_id, connection_id, job, stream, from_at, to_at, started_at)
  values (cma.current_tenant_id(), null, p_job, null, clock_timestamp(), clock_timestamp(), clock_timestamp())
  returning id into v_id;
  return v_id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The overviews: one catalog, read by every function below and by the verify
-- ---------------------------------------------------------------------------------------------
-- Per overview: its order, stock (as of the instant) or flow (a period of business dates), the source whose set-up it
-- needs (data_quality none), its dims (the breakdown's keys), its grouping sets (the totals [] first, then [market],
-- then the breakdowns), its measures (counts, per-currency amounts, ages, sums), the measures that count records (the
-- watch reads them; a list can be narrowed to the records behind one), its headline and its list's sort keys (the first
-- the default)
create or replace function cma.flash_overviews()
returns table (key text, sort_order integer, kind text, source text, dims text[], sets jsonb, measures text[], count_measures text[],
               headline text, sorts text[])
language sql immutable
as $$
  values
    ('customers', 10, 'stock', 'commerce', array['market', 'store'], '[[], ["market"], ["market", "store"]]'::jsonb,
       array['customers_held', 'active_customers', 'paused_customers', 'linked_to_contact', 'with_required_refs'],
       array['customers_held', 'active_customers', 'paused_customers', 'linked_to_contact', 'with_required_refs'], 'active_customers',
       array['lifetime_orders', 'total_spent', 'customer_id', 'store', 'market', 'active_subscriptions', 'devices']),
    ('subscriptions', 20, 'stock', 'subscriptions', array['market', 'store', 'status', 'payment_state'],
       '[[], ["market"], ["market", "store", "status", "payment_state"]]'::jsonb,
       array['subscriptions', 'active_subscriptions', 'paused_subscriptions', 'amount_per_cycle'],
       array['subscriptions', 'active_subscriptions', 'paused_subscriptions'], 'active_subscriptions',
       array['subscription_id', 'store', 'market', 'status', 'payment_state', 'amount_per_cycle', 'next_billing_at', 'retry_since', 'devices']),
    ('installed_base', 30, 'stock', 'assets', array['market', 'status', 'model', 'warehouse', 'link'],
       '[[], ["market"], ["market", "status", "model", "warehouse", "link"]]'::jsonb,
       array['devices', 'in_field', 'in_stock', 'components_past_due', 'items_due_3m'],
       array['devices', 'in_field', 'in_stock', 'components_past_due', 'items_due_3m'], 'in_field',
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
  select case when p_overview in (select o.key from cma.flash_overviews() o) then '0008zn' end
$$;

-- An overview's key, or CMA04
create or replace function cma.assert_flash_overview(p_overview text)
returns void
language plpgsql immutable
as $$
begin
  if p_overview is null or not exists (select 1 from cma.flash_overviews() o where o.key = p_overview) then
    raise exception 'the overview is one of customers, subscriptions, installed_base, churn, orders, payments, open_deals, open_tickets, open_tasks, reviews, data_quality'
      using errcode = 'CMA04';
  end if;
end
$$;

-- A snapshot row's form: dims an object of the overview's dims, each a text of 1 to 100 characters; measures an object
-- of the overview's measures, each a number, or for an amount an object of currency codes to numbers; no @ anywhere
create or replace function cma.flash_row_ok(p_overview text, p_dims jsonb, p_measures jsonb)
returns boolean
language sql immutable
as $$
  select p_dims is not null and jsonb_typeof(p_dims) = 'object' and p_measures is not null and jsonb_typeof(p_measures) = 'object'
     and strpos(p_dims::text, '@') = 0 and strpos(p_measures::text, '@') = 0
     and exists (select 1 from cma.flash_overviews() o where o.key = p_overview)
     and not exists (select 1 from jsonb_each(p_dims) e
                     where not (e.key = any (coalesce((select o.dims from cma.flash_overviews() o where o.key = p_overview), '{}'::text[])))
                        or jsonb_typeof(e.value) <> 'string' or length(e.value #>> '{}') not between 1 and 100)
     and not exists (select 1 from jsonb_each(p_measures) e
                     where not (e.key = any (coalesce((select o.measures from cma.flash_overviews() o where o.key = p_overview), '{}'::text[])))
                        or not (jsonb_typeof(e.value) = 'number'
                                or (jsonb_typeof(e.value) = 'object'
                                    and not exists (select 1 from jsonb_each(e.value) c
                                                    where c.key !~ '^[A-Z]{3}$' or jsonb_typeof(c.value) <> 'number'))))
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Helpers: the active statuses, the stores of the subscriptions, the sources
-- ---------------------------------------------------------------------------------------------
-- The statuses that make a subscription active (flash.active_subscription_statuses)
create or replace function cma.flash_active_statuses_of(p_tenant_id uuid)
returns text[]
language sql stable
as $$
  select cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.active_subscription_statuses'))
$$;

-- The statuses that end a subscription (flash.ended_subscription_statuses): churn's and the ended-subscription check's
create or replace function cma.flash_ended_statuses_of(p_tenant_id uuid)
returns text[]
language sql stable
as $$
  select cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.ended_subscription_statuses'))
$$;

-- A breakdown's value as a snapshot can hold it, for a value a source writes freely (a SKU, a warehouse, a store's
-- payment status, a pipeline, a stage, a task's type or status): p_none when absent or blank; other when it holds an @
-- or a control character or is longer than 100 characters (a snapshot holds no @, so no email can land in one); else
-- the value. The base sets apply it, so a figure, its breakdown cell and the list behind it agree, and one odd value
-- never fails a take
create or replace function cma.flash_dim_of(p_value text, p_none text)
returns text
language sql immutable
as $$
  select case when nullif(btrim(p_value), '') is null then p_none
              when strpos(p_value, '@') > 0 or p_value ~ '[[:cntrl:]]' or length(btrim(p_value)) > 100 then 'other'
              else btrim(p_value) end
$$;

-- Every connection that holds subscriptions (kind subscriptions, or unset while it holds them) with its commerce store
-- (0008zl's cma.subscription_store_connection_of): the store's connection, handle, market and currency
create or replace function cma.flash_subscription_stores_of(p_tenant_id uuid)
returns table (connection_id uuid, store_connection_id uuid, handle text, market text)
language sql stable
as $$
  select c.id, x.store_connection_id, x.handle, st.market
  from cma.integration_connection c
  cross join lateral cma.subscription_store_connection_of(p_tenant_id, c.id) x
  join cma.commerce_store st on st.tenant_id = c.tenant_id and st.id = x.store_id
  where c.tenant_id = p_tenant_id
    and (c.kind = 'subscriptions'
         or (c.kind is null and exists (select 1 from cma.subscription s where s.tenant_id = c.tenant_id and s.connection_id = c.id)))
$$;

-- The sources Flash reads, each set up or not, with its active connections' adapters and the last successful read
-- (the latest finish of a succeeded sync_run of one of them): commerce (a store), subscriptions (a subscriptions
-- connection), assets (0008zi's set-up), crm (a connection of kind crm, or one holding CRM rows) and reviews (0008ze's)
create or replace function cma.flash_sources_of(p_tenant_id uuid)
returns jsonb
language sql stable
as $$
  with c as (
    select ic.id, ic.adapter,
           case when ic.kind is not null then ic.kind
                when exists (select 1 from cma.commerce_store x where x.tenant_id = ic.tenant_id and x.connection_id = ic.id) then 'commerce'
                else (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1] end as kind
    from cma.integration_connection ic
    where ic.tenant_id = p_tenant_id and ic.status = 'active'
  ), k as (
    select x.kind, array_agg(distinct c.adapter order by c.adapter) filter (where c.id is not null) as adapters,
           (select max(r.finished_at) from cma.sync_run r
            where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.connection_id in (select c2.id from c c2 where c2.kind = x.kind)) as last_read_at
    from unnest(array['commerce', 'subscriptions', 'assets', 'crm', 'reviews']) x(kind)
    left join c on c.kind = x.kind
    group by x.kind
  )
  select jsonb_object_agg(k.kind, jsonb_build_object(
           'set_up', case k.kind
                       when 'commerce' then exists (select 1 from cma.commerce_store st join c on c.id = st.connection_id where st.tenant_id = p_tenant_id)
                       when 'subscriptions' then exists (select 1 from cma.flash_subscription_stores_of(p_tenant_id) s join c on c.id = s.connection_id)
                       when 'assets' then cma.assets_set_up_of(p_tenant_id)
                       when 'reviews' then cma.reviews_set_up_of(p_tenant_id)
                       else k.adapters is not null end,
           'adapters', coalesce(to_jsonb(k.adapters), '[]'::jsonb),
           'last_read_at', k.last_read_at))
  from k
$$;

-- The instants a period of the tenant's business dates spans: [from 00:00, the day after to 00:00) in its zone
create or replace function cma.flash_period_of(p_tenant_id uuid, p_from date, p_to date, out from_at timestamptz, out to_at timestamptz)
language sql stable
as $$
  select (p_from::timestamp at time zone t.timezone), ((p_to + 1)::timestamp at time zone t.timezone)
  from cma.tenant t where t.id = p_tenant_id
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The base sets: one per overview, the records behind its figures and its list (ids, codes, amounts, times)
-- ---------------------------------------------------------------------------------------------
-- Store customers the CMA holds (not deleted), each with its store and market (the store's), lifetime orders and total
-- spent as the store states them, the CRM contact it is linked to (0008h) and whether the CMA holds that contact, the
-- contact's references among commerce.required_contact_refs (each system's first slot) and those it lacks in every slot
-- (every one when the contact is not held), its subscriptions in the active statuses and paused (of the subscriptions of its store, not missing), and
-- the devices whose customer reference is its id, of its store's market (the register names no store: a customer id is
-- matched within a market, so two stores of one market sharing an id would share its devices; docs/architecture/data-model/0008.md)
create or replace function cma.flash_customers_of(p_tenant_id uuid)
returns table (customer_id uuid, connection_id uuid, source_id text, store text, market text, lifetime_orders integer, total_spent numeric,
               currency text, crm_connection_id uuid, contact_source_id text, contact_held boolean, refs jsonb, missing_refs text[],
               active_subscriptions integer, paused_subscriptions integer, devices integer)
language sql stable
as $$
  with s as materialized (
    select cma.flash_active_statuses_of(p_tenant_id) as active,
           cma.flash_list_of(cma.setting_of(p_tenant_id, 'commerce.required_contact_refs')) as refs
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
         coalesce(sub.active, 0), coalesce(sub.paused, 0), coalesce(dev.n, 0)
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

-- Subscriptions the latest full read still returns, each with its store and market (its connection's store), its store
-- customer's CRM contact (0008h), status, payment state (0008zl; none for merged and never-subscribed), whether its status
-- is an active one, amount per cycle and currency, interval, next billing, the open failed renewal's first failure and
-- highest attempt, and the devices whose subscription reference is its id, of its store's market
create or replace function cma.flash_subscriptions_of(p_tenant_id uuid)
returns table (subscription_id uuid, connection_id uuid, source_id text, store text, market text, customer_source_id text,
               crm_connection_id uuid, contact_source_id text, status text, payment_state text, is_active boolean, amount_per_cycle numeric,
               currency text, billing_interval text, billing_interval_count integer, next_billing_at timestamptz, retry_since timestamptz,
               last_attempt integer, devices integer)
language sql stable
as $$
  with s as materialized (
    select cma.flash_active_statuses_of(p_tenant_id) as active
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  ), ps as materialized (
    select p.subscription_id, p.payment_state, p.retry_since, p.last_attempt from cma.subscription_payment_state_of(p_tenant_id) p
  ), dev as materialized (
    select d.subscription_ref, d.market, count(*)::integer as n
    from cma.device d
    where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.subscription_ref is not null
    group by 1, 2
  )
  select sb.id, sb.connection_id, sb.source_id, coalesce(sm.handle, 'unknown'), coalesce(sm.market, 'unknown'), sb.customer_source_id,
         cu.crm_connection_id, cu.crm_contact_source_id, sb.status, coalesce(ps.payment_state, 'none'), sb.status = any (s.active),
         sb.amount_per_cycle, sb.currency, sb.billing_interval, sb.billing_interval_count, sb.next_billing_at, ps.retry_since, ps.last_attempt,
         coalesce(dev.n, 0)
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

-- Devices the asset register still holds (not missing from its latest full snapshot), each with its serial, model,
-- market and device status (unknown when unmapped), the status's flags, its warehouse (none; other for a value a
-- snapshot cannot hold, cma.flash_dim_of), its named ids among assets.required_refs and those it lacks, its customer and
-- subscription references, the subscription link (linked: a subscription of a store of the device's market has the
-- reference as its id; not_found; none: no reference) with that subscription's id and status (its payment state is the
-- list's, cma.flash_rows_of), and from 0008zi's forecast as of p_today its past-due items, its items due within three
-- months (not past due) and its earliest due date. p_today is the business date the figures are for: the tenant's today
-- live, the snapshot's own date in a take (so an item due on a month's last day is not past due in that month end's
-- snapshot, taken after midnight)
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
         sub.id, sub.status, coalesce(mi.past_due, 0), coalesce(mi.due_3m, 0), mi.next_due
  from cma.device d
  cross join s
  left join cma.device_status st on st.tenant_id = d.tenant_id and st.key = d.device_status_key
  left join sub on sub.market = d.market and sub.source_id = d.subscription_ref
  left join mi on mi.device_id = d.id
  where d.tenant_id = p_tenant_id and d.source_deleted_at is null
$$;

-- The subscriptions churned per business date of a period: a move into a status of flash.ended_subscription_statuses
-- (default canceled and expired): an event canceled (while canceled is one of them), or status_changed to one of them,
-- of the date in the tenant's zone; a subscription counts once per date (its first such event), with the reason code of
-- its canceled event, else of the other (none when absent), its store and market, its store customer and its current
-- cycle. A period is the sum of its dates
create or replace function cma.flash_churn_of(p_tenant_id uuid, p_from date, p_to date)
returns table (subscription_id uuid, connection_id uuid, source_id text, store text, market text, customer_source_id text,
               business_date date, churned_at timestamptz, reason text, cycles integer)
language sql stable
as $$
  with z as materialized (
    select t.timezone as zone, p.from_at, p.to_at, cma.flash_ended_statuses_of(p_tenant_id) as ended
    from cma.tenant t cross join cma.flash_period_of(p_tenant_id, p_from, p_to) p
    where t.id = p_tenant_id
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  ), e as (
    select ev.connection_id, ev.subscription_source_id, (ev.occurred_at at time zone z.zone)::date as d, ev.occurred_at, ev.event_type,
           ev.reason_code
    from cma.subscription_event ev
    cross join z
    where ev.tenant_id = p_tenant_id and ev.occurred_at >= z.from_at and ev.occurred_at < z.to_at
      and ((ev.event_type = 'canceled' and 'canceled' = any (z.ended))
           or (ev.event_type = 'status_changed' and ev.status_to = any (z.ended)))
  ), g as (
    select e.connection_id, e.subscription_source_id, e.d, min(e.occurred_at) as at,
           coalesce((array_agg(e.reason_code order by (e.event_type = 'canceled') desc, e.occurred_at)
                       filter (where e.reason_code is not null))[1], 'none') as reason
    from e
    group by 1, 2, 3
  )
  select sb.id, g.connection_id, g.subscription_source_id, coalesce(sm.handle, 'unknown'), coalesce(sm.market, 'unknown'),
         sb.customer_source_id, g.d, g.at, g.reason, sb.current_cycle
  from g
  left join sm on sm.connection_id = g.connection_id
  left join cma.subscription sb on sb.tenant_id = p_tenant_id and sb.connection_id = g.connection_id and sb.source_id = g.subscription_source_id
$$;

-- The store orders created on the business dates of a period (the tenant's zone), test orders and deleted ones left out:
-- store, market, kind, the payment and fulfilment status as the store states them (lower case; unknown when absent), the
-- SKUs (none for a line without one, other for one a snapshot cannot hold: cma.flash_dim_of) and units of its lines, the total less refunded in its currency, the customer's id
create or replace function cma.flash_orders_of(p_tenant_id uuid, p_from date, p_to date)
returns table (order_id uuid, connection_id uuid, source_id text, order_number text, store text, market text, business_date date,
               created_at timestamptz, kind text, financial_status text, fulfillment_status text, skus text[], units integer, total numeric,
               currency text, customer_source_id text)
language sql stable
as $$
  with z as materialized (
    select t.timezone as zone, p.from_at, p.to_at
    from cma.tenant t cross join cma.flash_period_of(p_tenant_id, p_from, p_to) p
    where t.id = p_tenant_id
  ), st as materialized (
    select x.connection_id, x.handle, x.market from cma.commerce_store x where x.tenant_id = p_tenant_id
  )
  , o as materialized (
    select o.* from cma.commerce_order o cross join z
    where o.tenant_id = p_tenant_id and o.source_created_at >= z.from_at and o.source_created_at < z.to_at
      and not o.is_test and o.source_deleted_at is null
  ), l as (
    -- the lines of those orders, once, by a join (no read per order)
    select ln.connection_id, ln.order_source_id,
           array_agg(distinct cma.flash_dim_of(ln.sku, 'none') order by cma.flash_dim_of(ln.sku, 'none')) as skus,
           sum(ln.quantity)::integer as units
    from cma.commerce_order_line ln
    join o on o.connection_id = ln.connection_id and o.source_id = ln.order_source_id
    where ln.tenant_id = p_tenant_id
    group by 1, 2
  )
  select o.id, o.connection_id, o.source_id, coalesce(o.order_name, o.source_id), coalesce(st.handle, 'unknown'), coalesce(st.market, 'unknown'),
         (o.source_created_at at time zone z.zone)::date, o.source_created_at, o.order_kind,
         lower(cma.flash_dim_of(o.financial_status, 'unknown')), lower(cma.flash_dim_of(o.fulfillment_status, 'unknown')),
         coalesce(l.skus, '{}'::text[]), coalesce(l.units, 0), o.total_amount - coalesce(o.refunded_amount, 0), o.currency, o.customer_source_id
  from o
  cross join z
  left join st on st.connection_id = o.connection_id
  left join l on l.connection_id = o.connection_id and l.order_source_id = o.source_id
$$;

-- The lines of the same orders per SKU: the order, its market, store and kind, its business date, the SKU and its units
create or replace function cma.flash_order_lines_of(p_tenant_id uuid, p_from date, p_to date)
returns table (order_id uuid, store text, market text, kind text, business_date date, sku text, units integer)
language sql stable
as $$
  select o.order_id, o.store, o.market, o.kind, o.business_date, cma.flash_dim_of(ln.sku, 'none'), sum(ln.quantity)::integer
  from cma.flash_orders_of(p_tenant_id, p_from, p_to) o
  join cma.commerce_order_line ln on ln.tenant_id = p_tenant_id and ln.connection_id = o.connection_id and ln.order_source_id = o.source_id
  group by 1, 2, 3, 4, 5, 6
$$;

-- Payments without the ERP, from two sources and labelled as such: kind order, each store order of the period with its
-- financial status as the store states it and its total less refunded; kind renewal, each renewal and
-- failed renewal of the subscription app in the period (renewed, renew_failed), with the subscription and its cycle. A
-- business date of the tenant's zone. Never "failed payment" or "dunning" (Failed renewal)
create or replace function cma.flash_payments_of(p_tenant_id uuid, p_from date, p_to date)
returns table (kind text, status text, source_id text, record_ref text, cycle integer, connection_id uuid, store text, market text,
               business_date date, at timestamptz, amount numeric, currency text)
language sql stable
as $$
  with z as materialized (
    select t.timezone as zone, p.from_at, p.to_at
    from cma.tenant t cross join cma.flash_period_of(p_tenant_id, p_from, p_to) p
    where t.id = p_tenant_id
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  )
  select 'order'::text, o.financial_status, o.source_id, o.order_number, null::integer, o.connection_id, o.store, o.market, o.business_date,
         o.created_at, o.total, o.currency
  from cma.flash_orders_of(p_tenant_id, p_from, p_to) o
  union all
  select 'renewal', ev.event_type, ev.source_id, ev.subscription_source_id, ev.cycle_index, ev.connection_id, coalesce(sm.handle, 'unknown'),
         coalesce(sm.market, 'unknown'), (ev.occurred_at at time zone z.zone)::date, ev.occurred_at, null::numeric, null::text
  from cma.subscription_event ev
  cross join z
  left join sm on sm.connection_id = ev.connection_id
  where ev.tenant_id = p_tenant_id and ev.occurred_at >= z.from_at and ev.occurred_at < z.to_at
    and ev.event_type in ('renewed', 'renew_failed')
$$;

-- Open deals: deals of counted pipelines, not deleted, not closed by their stage, created on or after intake.start_date
-- (0008y's cma.counted_deals_of, never copied: its market rule, the deal's own else its contact's country), with the
-- pipeline, stage, the owner's ref and person, created, and the age in whole days since creation as of p_at (now live;
-- the end of the snapshot's date in a take, so an age is its date's and never the take's)
create or replace function cma.flash_deals_of(p_tenant_id uuid, p_at timestamptz default now())
returns table (deal_id uuid, connection_id uuid, source_id text, pipeline text, stage text, market text, owner_ref text, owner_user_id uuid,
               created_at timestamptz, age_days integer)
language sql stable
as $$
  select d.deal_id, d.connection_id, d.source_id, cma.flash_dim_of(d.pipeline_id, 'none'), cma.flash_dim_of(d.stage_id, 'none'),
         coalesce(d.market, 'unknown'), d.owner_ref, cma.owner_user_of(p_tenant_id, d.source_system, d.owner_ref), d.created_at,
         greatest(0, floor(extract(epoch from coalesce(p_at, now()) - d.created_at) / 86400))::integer
  from cma.counted_deals_of(p_tenant_id, null, null) d
  where not d.is_closed
$$;

-- Open tickets: 0008o's cma.open_tickets_of (counted pipelines, not closed, not deleted; the ticket's market else its
-- contact's country), the queue its pipeline, with the age in whole days since creation as of p_at (as open deals)
create or replace function cma.flash_tickets_of(p_tenant_id uuid, p_at timestamptz default now())
returns table (ticket_id uuid, connection_id uuid, source_id text, queue text, stage text, market text, owner_ref text, owner_user_id uuid,
               created_at timestamptz, age_days integer)
language sql stable
as $$
  select t.ticket_id, t.connection_id, t.ticket_source_id, cma.flash_dim_of(t.pipeline_id, 'none'), cma.flash_dim_of(t.stage_id, 'none'),
         coalesce(t.market, 'unknown'), t.owner_ref, t.owner_user_id, t.created_at,
         greatest(0, floor(extract(epoch from coalesce(p_at, now()) - t.created_at) / 86400))::integer
  from cma.open_tickets_of(p_tenant_id) t
$$;

-- Open tasks: 0008o's cma.open_tasks_of (not deleted, status not done by the connection's catalog, type counted), the
-- market from the task's deal, else its ticket, else its contact (unknown otherwise), overdue when due on a business
-- date before p_on (the tenant's today live, as 0008o's due state; the snapshot's date in a take, so a task due on that
-- date is not overdue in its snapshot)
create or replace function cma.flash_tasks_of(p_tenant_id uuid, p_on date default null)
returns table (task_id uuid, connection_id uuid, source_id text, type text, status text, market text, owner_ref text, owner_user_id uuid,
               due_at timestamptz, overdue boolean, record_type text, record_source_id text)
language sql stable
as $$
  with z as materialized (
    select t.timezone as zone, coalesce(p_on, (now() at time zone t.timezone)::date) as on_date from cma.tenant t where t.id = p_tenant_id
  )
  select k.task_id, k.connection_id, k.task_source_id, cma.flash_dim_of(k.type_ref, 'none'), cma.flash_dim_of(k.status_ref, 'none'),
         coalesce(k.market, 'unknown'), k.owner_ref, k.owner_user_id, k.due_at,
         coalesce((k.due_at at time zone z.zone)::date < z.on_date, false), k.record_type, k.record_source_id
  from cma.open_tasks_of(p_tenant_id) k
  cross join z
$$;

-- Published reviews of counted channels (0008ze's cma.reviews_of, never copied) submitted on the business dates of a
-- period: market (the channel's), rating, whole star, negative, link level, with the review's id at the platform
create or replace function cma.flash_reviews_of(p_tenant_id uuid, p_from date, p_to date)
returns table (review_id uuid, connection_id uuid, source_id text, channel text, market text, rating numeric, stars integer,
               is_negative boolean, business_date date, submitted_at timestamptz, link_level text)
language sql stable
as $$
  select r.review_id, r.connection_id, rv.source_id, r.channel_source_id, r.market, r.rating, r.stars, r.is_negative, r.business_date,
         r.submitted_at, r.link_level
  from cma.reviews_of(p_tenant_id) r
  join cma.review rv on rv.tenant_id = p_tenant_id and rv.id = r.review_id
  where r.business_date between p_from and p_to
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Data quality: Flash's six checks, every check's rows with their market and the system where they are fixed
-- ---------------------------------------------------------------------------------------------
-- Flash's checks, listed apart and shown after 0008zi's, as each addition lists its own
create or replace function cma.data_quality_flash_checks()
returns table (check_key text, sort_order integer, description text)
language sql immutable
as $$
  values
    ('customer_required_ref_missing',      310, 'Store customers with an order whose CRM contact lacks a required reference, with the references missing'),
    ('device_required_ref_missing',        320, 'Devices lacking a required named id, with the ids missing'),
    ('subscription_customer_unmatched',    330, 'Subscriptions whose customer id no customer of their store holds'),
    ('active_subscription_without_device', 340, 'Active subscriptions no device''s subscription reference names'),
    ('device_subscription_ref_unknown',    350, 'Devices in the field whose subscription reference names no subscription the CMA holds'),
    ('field_device_on_ended_subscription', 360, 'Devices in the field linked to a subscription in an ended status (flash.ended_subscription_statuses), with its status')
$$;

-- As 0008zi (112), plus Flash's six checks (0008zn): store customers with an order whose contact lacks a required
-- reference, devices lacking a required named id, subscriptions whose customer their store does not hold, active
-- subscriptions without a device (of a market the register holds devices of), devices in the field with a subscription
-- reference the CMA does not know (of a market whose subscriptions it reads) and devices in the field on an ended
-- subscription. A device's subscription reference is matched within the device's market (the register names no
-- connection)
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
  -- active subscriptions (flash.active_subscription_statuses) of a store whose market the register holds devices of,
  -- that no device of that market the register still holds names by its subscription reference, once the tenant has an
  -- asset register set up (0008zn); the value the status. A market without any device in the register (one it does not
  -- cover yet) gives no finding
  select 'active_subscription_without_device', sb.connection_id, 'subscription', sb.source_id, sb.status
  from cma.subscription sb
  join (select x.connection_id, x.market from cma.flash_subscription_stores_of(p_tenant_id) x offset 0) sm on sm.connection_id = sb.connection_id
  left join (select distinct d.market, d.subscription_ref from cma.device d
             where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.subscription_ref is not null) dr
    on dr.subscription_ref = sb.source_id and dr.market = sm.market
  where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null and dr.subscription_ref is null
    and sb.status = any (cma.flash_active_statuses_of(p_tenant_id)) and cma.assets_set_up_of(p_tenant_id)
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
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null;

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

-- As 0008zi (112), plus Flash's checks: listed once their sources are set up (and, for the two reference checks, once
-- the setting names a reference), or while one finds something. A tenant without either keeps every earlier row exactly
create or replace function cma.data_quality()
returns table (check_key text, description text, total integer)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'tenant.configure']);
  return query
    with q as materialized (select f.check_key from cma.data_quality_of(v_tenant) f),
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
         or (fc.check_key in ('active_subscription_without_device', 'device_subscription_ref_unknown', 'field_device_on_ended_subscription')
             and (s.src -> 'subscriptions' ->> 'set_up')::boolean and (s.src -> 'assets' ->> 'set_up')::boolean)
    )
    select c.check_key, c.description,
           case when c.check_key = 'writeback_parked' and to_regclass('cma.outbox_action') is null then null
                else (select count(*) from q where q.check_key = c.check_key)::integer end
    from c
    order by c.sort_order;
end
$$;

-- Every data-quality check of every addition, in one list (key, order, description): what Flash labels and checks a
-- check key against
create or replace function cma.data_quality_catalog()
returns table (check_key text, sort_order integer, description text)
language sql immutable
as $$
  select x.check_key, x.sort_order, x.description
  from (select * from cma.data_quality_checks()
        union all select * from cma.data_quality_added_checks()
        union all select * from cma.data_quality_follow_up_checks()
        union all select * from cma.data_quality_forms_checks()
        union all select * from cma.data_quality_reviews_checks()
        union all select * from cma.data_quality_assets_checks()
        union all select * from cma.data_quality_flash_checks()) x
$$;

-- Where a finding is fixed, as the kind of the owning system (crm, commerce, subscriptions, assets, telephony, reviews),
-- or cma for the CMA's own configuration (People, Configuration, Sources) and for a contact the CMA does not hold yet
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
                         'device_subscription_ref_unknown', 'field_device_on_ended_subscription') then 'assets'
    else 'cma' end
$$;

-- Every finding of cma.data_quality_of with its market (the record's: a store customer's or a subscription's store, a
-- device's, a deal's or ticket's own else its contact's country, a contact's country, a form's, a review channel's, a
-- market check's own; unknown otherwise), where it is fixed (cma.data_quality_fix_in) and that system's adapter (the
-- finding's connection's when it is of that kind, else the tenant's first active connection of it). A store's or a
-- subscription connection's market by a join; a record's own read only for the findings of its type; the links are the
-- list's (cma.flash_finding_links_of, per row shown)
create or replace function cma.flash_findings_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text, market text, fix_in text, fix_adapter text)
language sql stable
as $$
  with f as materialized (
    select q.* from cma.data_quality_of(p_tenant_id) q
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
                    when 'market' then f.object_id
                    -- a record's own market, read for the findings of its type only
                    when 'device' then (select d.market from cma.device d
                                        where d.tenant_id = p_tenant_id and d.connection_id = f.connection_id and d.source_id = f.object_id)
                    when 'contact' then (select cma.market_code_of(p_tenant_id, k.country) from cma.crm_contact k
                                         where k.tenant_id = p_tenant_id and k.connection_id = f.connection_id and k.source_id = f.object_id)
                    when 'form' then (select cf.market from cma.connection_form cf
                                      where cf.tenant_id = p_tenant_id and cf.connection_id = f.connection_id and cf.source_form_id = f.object_id)
                    when 'review_channel' then (select ch.market from cma.review_channel ch
                                                where ch.tenant_id = p_tenant_id and ch.connection_id = f.connection_id and ch.source_id = f.object_id)
                    -- 0007d's market rule (cma.record_market_of) for a deal's or ticket's finding
                    when 'deal' then (select coalesce(cma.market_code_of(p_tenant_id, r.market), cma.market_code_of(p_tenant_id, rk.country))
                                      from cma.crm_record r
                                      left join cma.crm_contact rk
                                        on rk.tenant_id = r.tenant_id and rk.connection_id = r.connection_id and rk.source_id = r.contact_source_id
                                      where r.tenant_id = p_tenant_id and r.connection_id = f.connection_id and r.record_type = 'deal'
                                        and r.source_id = f.object_id)
                    when 'ticket' then (select coalesce(cma.market_code_of(p_tenant_id, r.market), cma.market_code_of(p_tenant_id, rk.country))
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
  left join sm on f.object_type = 'subscription' and sm.connection_id = f.connection_id
$$;

-- A finding's links, for a row a list shows: the record's (its connection's record_url template) and the related
-- record (a store customer's CRM contact with its link; a device's subscription reference)
create or replace function cma.flash_finding_links_of(p_tenant_id uuid, p_connection_id uuid, p_object_type text, p_object_id text)
returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'record_url', case when p_connection_id is not null then cma.record_url(p_connection_id, p_object_type, p_object_id) end,
    'related_type', case when cu.crm_contact_source_id is not null then 'contact' when dv.subscription_ref is not null then 'subscription' end,
    'related_id', coalesce(cu.crm_contact_source_id, dv.subscription_ref),
    'related_url', case when cu.crm_contact_source_id is not null then cma.record_url(cu.crm_connection_id, 'contact', cu.crm_contact_source_id) end)
  from (select 1) one
  left join cma.commerce_customer cu
    on p_object_type = 'commerce_customer' and cu.tenant_id = p_tenant_id and cu.connection_id = p_connection_id and cu.source_id = p_object_id
  left join cma.device dv
    on p_object_type = 'device' and dv.tenant_id = p_tenant_id and dv.connection_id = p_connection_id and dv.source_id = p_object_id
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. The figures: one computation, live and in the snapshot
-- ---------------------------------------------------------------------------------------------
-- An overview's figures for an explicit tenant: one row per grouping set of the overview (cma.flash_overviews().sets):
-- dims (the set's keys and values: {} for the totals) and measures. Stock overviews read the mirrors as they are (the
-- period is ignored) and measure against p_on, the business date the figures are for: null live (the tenant's today,
-- ages as of now), the snapshot's date in a take (past due and due within three months against that date, overdue
-- tasks due before it, ages as of its end), so a snapshot taken after midnight says what its own date said. Flow
-- overviews take the business dates p_from to p_to. Amounts are summed per currency (an object of currency codes);
-- never across currencies. Nothing for an overview whose source the tenant has not set up; the totals row with zeros
-- for a set-up source without records. A measure that does not apply is left out of every row, never 0: the customers'
-- with_required_refs while commerce.required_contact_refs is empty (no reference is required, so none is met or
-- missed; Decision log, 3 Nov 2026). The snapshot stores exactly these rows (one code path)
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
begin
  perform cma.assert_flash_overview(p_overview);
  if v_src is not null and not coalesce((cma.flash_sources_of(p_tenant_id) -> v_src ->> 'set_up')::boolean, false) then
    return;
  end if;
  if p_overview = 'customers' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'store', b.store) end,
             jsonb_build_object('customers_held', count(*),
                                'active_customers', count(*) filter (where b.active_subscriptions > 0),
                                'paused_customers', count(*) filter (where b.active_subscriptions = 0 and b.paused_subscriptions > 0),
                                'linked_to_contact', count(*) filter (where b.contact_source_id is not null))
             || case when v_refs_required
                     then jsonb_build_object('with_required_refs', count(*) filter (where b.contact_source_id is not null and b.contact_held
                                                                                     and cardinality(b.missing_refs) = 0))
                     else '{}'::jsonb end
      from cma.flash_customers_of(p_tenant_id) b
      group by grouping sets ((), (b.market), (b.market, b.store));
  elsif p_overview = 'subscriptions' then
    return query
      with a as (
        select case when grouping(b.market) = 1 then '{}'::jsonb
                    when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                    else jsonb_build_object('market', b.market, 'store', b.store, 'status', b.status, 'payment_state', b.payment_state) end as dims,
               b.currency, count(*) as n, count(*) filter (where b.is_active) as act, count(*) filter (where b.status = 'paused') as paused,
               -- the active subscriptions' amounts only, each for its own billing cycle (Flash overview measures)
               sum(b.amount_per_cycle) filter (where b.is_active) as amount
        from cma.flash_subscriptions_of(p_tenant_id) b
        group by grouping sets ((b.currency), (b.market, b.currency), (b.market, b.store, b.status, b.payment_state, b.currency))
      )
      select a.dims, jsonb_build_object('subscriptions', sum(a.n), 'active_subscriptions', sum(a.act), 'paused_subscriptions', sum(a.paused),
                                        'amount_per_cycle', coalesce(jsonb_object_agg(a.currency, round(a.amount, 2))
                                                                       filter (where a.currency is not null and a.amount is not null), '{}'::jsonb))
      from a group by a.dims;
    if not found then
      return query select '{}'::jsonb, jsonb_build_object('subscriptions', 0, 'active_subscriptions', 0, 'paused_subscriptions', 0,
                                                          'amount_per_cycle', '{}'::jsonb);
    end if;
  elsif p_overview = 'installed_base' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.status) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'status', b.status, 'model', b.model, 'warehouse', b.warehouse, 'link', b.link) end,
             jsonb_build_object('devices', count(*), 'in_field', count(*) filter (where b.is_in_field),
                                'in_stock', count(*) filter (where b.is_in_stock), 'components_past_due', coalesce(sum(b.past_due_items), 0),
                                'items_due_3m', coalesce(sum(b.items_due_3m), 0))
      from cma.flash_devices_of(p_tenant_id, v_on) b
      group by grouping sets ((), (b.market), (b.market, b.status, b.model, b.warehouse, b.link));
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
-- 9. The snapshots: runs, figures, the month end's id lists (written by the take alone)
-- ---------------------------------------------------------------------------------------------
-- One row per take of a tenant and business date, written once when the take ends: succeeded (its figures stored),
-- failed (nothing stored, the error's code), or missed: a date that stopped being the latest due date without a
-- succeeded take, recorded by the next take and never taken afterwards (a date missed is never invented, and never
-- silently absent). One succeeded or missed run per tenant and date. due_at: when the date became due (the day after it
-- at flash.snapshot_local_time, in the tenant's zone); late: the take started more than an hour after due_at, so the
-- hourly job's first run after the due time did not take it (a skipped or failed run); counts: the rows stored per
-- overview, at a month end the ids per kind, and the watch's counts; sources: cma.flash_sources_of at the take;
-- settings: the Flash settings the figures followed; missed_before: the business dates between the previous succeeded
-- run and this one without one; watch_error: the watch's error code when the watch failed (the snapshot is kept, the
-- watch's findings of that take are not written)
create table if not exists cma.flash_snapshot_run (
  id             uuid primary key default uuidv7(),
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  snapshot_date  date not null,
  due_at         timestamptz not null,
  started_at     timestamptz not null,
  finished_at    timestamptz not null,
  status         text not null check (status in ('succeeded', 'failed', 'missed')),
  late           boolean not null default false,
  counts         jsonb not null default '{}'::jsonb check (jsonb_typeof(counts) = 'object' and strpos(counts::text, '@') = 0),
  sources        jsonb not null default '{}'::jsonb check (jsonb_typeof(sources) = 'object' and strpos(sources::text, '@') = 0),
  settings       jsonb not null default '{}'::jsonb check (jsonb_typeof(settings) = 'object' and strpos(settings::text, '@') = 0),
  missed_before  integer not null default 0 check (missed_before >= 0),
  error          text check (error ~ '^[A-Za-z0-9_ :.-]{1,200}$'),
  watch_error    text check (watch_error ~ '^[A-Za-z0-9_]{1,20}$'),
  unique (tenant_id, id),
  check (finished_at >= started_at),
  check ((status = 'failed') = (error is not null)),
  check (watch_error is null or status = 'succeeded'),
  check (status <> 'missed' or (counts = '{}'::jsonb and not late))
);
comment on table cma.flash_snapshot_run is 'Flash: one row per take of a tenant''s business date, written when the take ends, succeeded or failed, and one per date the take missed (0008zn). Written by the snapshot job''s take only (cma.flash_snapshot_take); never changed';
comment on column cma.flash_snapshot_run.due_at is 'When the date became due: the day after it at flash.snapshot_local_time in the tenant''s zone';
comment on column cma.flash_snapshot_run.late is 'The take started more than an hour after due_at: the hourly job''s first run after the due time did not take the date';
comment on column cma.flash_snapshot_run.missed_before is 'The business dates between the previous succeeded run and this one without a snapshot; each has a missed run, and none is taken afterwards';
comment on column cma.flash_snapshot_run.watch_error is 'The watch''s error code when the watch failed after the figures were stored: the snapshot is kept, that take''s findings are not written';
drop index if exists cma.flash_snapshot_run_succeeded_idx;
create unique index if not exists flash_snapshot_run_final_idx on cma.flash_snapshot_run (tenant_id, snapshot_date) where status in ('succeeded', 'missed');
create index if not exists flash_snapshot_run_date_idx on cma.flash_snapshot_run (tenant_id, snapshot_date);

-- The figures of a take: one row per overview and grouping set, the live computation's rows as they were
create table if not exists cma.flash_snapshot (
  id                  uuid primary key default uuidv7(),
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  snapshot_date       date not null,
  overview            text not null,
  dims                jsonb not null,
  measures            jsonb not null,
  definition_version  text not null check (definition_version ~ '^[0-9a-z.]{1,20}$'),
  computed_at         timestamptz not null,
  run_id              uuid not null,
  unique (tenant_id, id),
  unique (tenant_id, snapshot_date, overview, dims),
  check (cma.flash_row_ok(overview, dims, measures)),
  foreign key (tenant_id, run_id) references cma.flash_snapshot_run (tenant_id, id) deferrable initially deferred
);
comment on table cma.flash_snapshot is 'Flash: the figures of each overview per business date as cma.flash_compute_of computed them at the take, measured against that date: one row per grouping set, dims and measures held to the overview''s allow-list, no id of a record and no @ (0008zn). Written by the take only; never changed';
comment on column cma.flash_snapshot.dims is 'The grouping set''s keys and values ({} for the totals): codes such as a market, a store''s handle, a status, a pipeline''s id';
comment on column cma.flash_snapshot.measures is 'The figures: counts, sums, ages; an amount as an object of currency codes to sums, never summed across currencies';
create index if not exists flash_snapshot_overview_idx on cma.flash_snapshot (tenant_id, overview, snapshot_date);

-- At a month end only: the ids of the active customers, the active subscriptions and every device, frozen
create table if not exists cma.flash_snapshot_ids (
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  snapshot_date  date not null check (snapshot_date = (date_trunc('month', snapshot_date) + interval '1 month - 1 day')::date),
  record_kind    text not null check (record_kind in ('customer', 'subscription', 'device')),
  source_id      text not null check (length(source_id) between 1 and 100 and source_id !~ '[[:cntrl:]@]'),
  connection_id  uuid not null,
  market         text not null check (market ~ '^([A-Z]{2}|unknown)$'),
  state          text not null check (state ~ '^[a-z0-9_-]{1,40}$'),
  run_id         uuid not null,
  primary key (tenant_id, snapshot_date, record_kind, connection_id, source_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id),
  foreign key (tenant_id, run_id) references cma.flash_snapshot_run (tenant_id, id) deferrable initially deferred
);
comment on table cma.flash_snapshot_ids is 'Flash: at each month end the frozen ids of the active customers (state active), the active subscriptions (their status) and every device the register holds (its device status), with connection and market; kept flash.id_list_retention_months (0008zn). Written by the take only; removed after the retention by cma.flash_snapshot_ids_expire_of';
create index if not exists flash_snapshot_ids_market_idx on cma.flash_snapshot_ids (tenant_id, snapshot_date, record_kind, market);

-- An object of scalar values under the given keys only, no @ anywhere (a watch finding's dims and detail)
create or replace function cma.flash_keys_ok(p_obj jsonb, p_keys text[])
returns boolean
language sql immutable
as $$
  select p_obj is not null and jsonb_typeof(p_obj) = 'object' and strpos(p_obj::text, '@') = 0
     and not exists (select 1 from jsonb_each(p_obj) e
                     where not (e.key = any (p_keys)) or jsonb_typeof(e.value) not in ('string', 'number', 'boolean', 'null'))
$$;

-- The watch's findings: written by the take, resolved by a later take, never deleted
create table if not exists cma.flash_watch_finding (
  id             uuid primary key default uuidv7(),
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  snapshot_date  date not null,
  kind           text not null check (kind in ('jump', 'flow_zero', 'source_stale', 'snapshot_missing', 'dq_rise')),
  overview       text check (overview is null or cma.flash_definition_version(overview) is not null),
  dims           jsonb not null default '{}'::jsonb check (cma.flash_keys_ok(dims, array['market', 'check', 'source', 'adapter', 'store'])),
  measure        text check (measure ~ '^[a-z][a-z0-9_]{0,39}$'),
  value          numeric,
  previous       numeric,
  threshold      numeric,
  detail         jsonb not null default '{}'::jsonb
                 check (cma.flash_keys_ok(detail, array['missing_from', 'missing_to', 'days', 'cadence_minutes', 'cadence_basis', 'age_minutes',
                                                        'last_read_at', 'jump_pct', 'jump_min', 'previous_days', 'connections'])),
  state          text not null default 'open' check (state in ('open', 'resolved')),
  resolved_on    date,
  created_at     timestamptz not null default now(),
  unique (tenant_id, id),
  check ((state = 'resolved') = (resolved_on is not null)),
  check (resolved_on is null or resolved_on >= snapshot_date)
);
comment on table cma.flash_watch_finding is 'Flash: the deterministic watch''s findings after each snapshot (jump, flow_zero, source_stale, snapshot_missing, dq_rise): aggregates, codes and counts only, no id of a record (0008zn). Written and resolved by the take only; one open finding per kind, overview, dims and measure';
create unique index if not exists flash_watch_finding_open_idx
  on cma.flash_watch_finding (tenant_id, kind, coalesce(overview, ''), dims, coalesce(measure, '')) where state = 'open';
create index if not exists flash_watch_finding_date_idx on cma.flash_watch_finding (tenant_id, snapshot_date);

select cma.setup_tenant_table('cma.flash_snapshot_run');
select cma.setup_tenant_table('cma.flash_snapshot');
select cma.setup_tenant_table('cma.flash_snapshot_ids');
select cma.setup_tenant_table('cma.flash_watch_finding');
-- The id lists are written in bulk at a month end (every active customer, active subscription and device: some 250,000
-- rows for a tenant at the sizes Flash is built for) and never change: no row image per id in the append-only audit
-- log; the take writes one audit row per kind with its count, and the expiry one per removal (as 0008s keeps its derived
-- tables out of the log)
drop trigger if exists audit on cma.flash_snapshot_ids;

-- Read only for the application: no insert, no update, no delete. Every row is written by the take, which runs with the
-- owner's rights (cma.flash_snapshot_take, SECURITY DEFINER, flash.snapshot checked), so a stored figure is always the
-- live computation's and a date missed is never invented; the owner's writers check flash.snapshot too. A finding's
-- state alone ever changes (open to resolved, by the take, guarded below)
revoke insert, update, delete on cma.flash_snapshot_run, cma.flash_snapshot, cma.flash_snapshot_ids, cma.flash_watch_finding from cma_app;
revoke update (state, resolved_on) on cma.flash_watch_finding from cma_app;

-- A finding moves from open to resolved once, by the take (the owner's rights and flash.snapshot), and nothing else of
-- it changes. A trigger function: nobody gets execute
create or replace function cma.flash_watch_finding_guard()
returns trigger
language plpgsql
as $$
begin
  if current_user <> 'cma_owner' and not cma.has_permission(cma.current_user_id(), 'flash.snapshot') then
    raise exception 'a watch finding is resolved by the snapshot job only' using errcode = 'CMA06';
  end if;
  if old.state <> 'open' or new.state <> 'resolved' or new.resolved_on is null
     or (new.tenant_id, new.snapshot_date, new.kind, new.overview, new.dims, new.measure, new.value, new.previous, new.threshold, new.detail)
        is distinct from
        (old.tenant_id, old.snapshot_date, old.kind, old.overview, old.dims, old.measure, old.value, old.previous, old.threshold, old.detail) then
    raise exception 'a watch finding only moves from open to resolved' using errcode = 'CMA03';
  end if;
  return new;
end
$$;
revoke execute on function cma.flash_watch_finding_guard() from public;
drop trigger if exists guard_state on cma.flash_watch_finding;
create trigger guard_state before update on cma.flash_watch_finding
  for each row execute function cma.flash_watch_finding_guard();

-- ---------------------------------------------------------------------------------------------
-- 10. The take: each business date once, from its due time
-- ---------------------------------------------------------------------------------------------
-- When a business date is due, and the latest due date at an instant (Decision log, 2 November 2026): date D is due at
-- D + 1 at flash.snapshot_local_time T in the tenant's zone, and at local time L the latest due date is (L - T)'s date
-- minus one. Each date is the latest due date for one local day (from its due time to the next date's), so the hourly
-- job takes every date exactly once, whatever T (00:00 to 23:59), the zone or summer time: T = 00:30 takes D at the
-- first run after D + 1 00:30, T = 23:59 at the first run after D + 1 23:59 (D + 2 00:20 with the job at minute 20)
create or replace function cma.flash_due_date_of(p_zone text, p_time time, p_now timestamptz)
returns date
language sql stable
as $$
  select ((p_now at time zone p_zone) - p_time::interval)::date - 1
$$;

create or replace function cma.flash_due_at_of(p_zone text, p_time time, p_date date)
returns timestamptz
language sql stable
as $$
  select ((p_date + 1) + p_time) at time zone p_zone
$$;

-- An id a month end's list can hold: 1 to 100 characters without a control character or an @, a market code or
-- unknown, a state code (the table's checks)
create or replace function cma.flash_id_ok(p_source_id text, p_market text, p_state text)
returns boolean
language sql immutable
as $$
  select coalesce(length(p_source_id) between 1 and 100 and p_source_id !~ '[[:cntrl:]@]' and p_market ~ '^([A-Z]{2}|unknown)$'
                  and p_state ~ '^[a-z0-9_-]{1,40}$', false)
$$;

-- The month end's id lists of a take (in its transaction, with the owner's rights; flash.snapshot and the current
-- tenant checked here too): the active customers, the active subscriptions (their status) and every device (its device
-- status), from the same base sets as the figures; an id the list cannot hold (cma.flash_id_ok) is left out and counted
-- (ids_skipped), never a reason to lose the date; one audit row per kind with its count. Answers the counts
create or replace function cma.flash_snapshot_ids_write_of(p_tenant_id uuid, p_date date, p_run_id uuid)
returns jsonb
language plpgsql
as $$
declare
  v_c  integer;
  v_s  integer;
  v_d  integer;
  v_nc integer;
  v_ns integer;
  v_nd integer;
begin
  perform cma.assert_permission('flash.snapshot');
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() or p_date is null or p_run_id is null then
    raise exception 'a month end''s id lists are written for the current tenant only' using errcode = 'CMA06';
  end if;
  with src as materialized (
    select c.source_id, c.connection_id, c.market from cma.flash_customers_of(p_tenant_id) c where c.active_subscriptions > 0
  ), ins as (
    insert into cma.flash_snapshot_ids (tenant_id, snapshot_date, record_kind, source_id, connection_id, market, state, run_id)
    select p_tenant_id, p_date, 'customer', src.source_id, src.connection_id, src.market, 'active', p_run_id
    from src where cma.flash_id_ok(src.source_id, src.market, 'active')
    returning 1
  )
  select (select count(*) from ins), (select count(*) from src) into v_c, v_nc;
  with src as materialized (
    select s.source_id, s.connection_id, s.market, s.status from cma.flash_subscriptions_of(p_tenant_id) s where s.is_active
  ), ins as (
    insert into cma.flash_snapshot_ids (tenant_id, snapshot_date, record_kind, source_id, connection_id, market, state, run_id)
    select p_tenant_id, p_date, 'subscription', src.source_id, src.connection_id, src.market, src.status, p_run_id
    from src where cma.flash_id_ok(src.source_id, src.market, src.status)
    returning 1
  )
  select (select count(*) from ins), (select count(*) from src) into v_s, v_ns;
  with src as materialized (
    select d.source_id, d.connection_id, d.market, d.status from cma.flash_devices_of(p_tenant_id, p_date) d
  ), ins as (
    insert into cma.flash_snapshot_ids (tenant_id, snapshot_date, record_kind, source_id, connection_id, market, state, run_id)
    select p_tenant_id, p_date, 'device', src.source_id, src.connection_id, src.market, src.status, p_run_id
    from src where cma.flash_id_ok(src.source_id, src.market, src.status)
    returning 1
  )
  select (select count(*) from ins), (select count(*) from src) into v_d, v_nd;
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  select p_tenant_id, 'flash_snapshot_ids', 'insert', null,
         jsonb_build_object('snapshot_date', p_date, 'record_kind', k.kind, 'rows', k.n, 'run_id', p_run_id),
         cma.current_user_id(), cma.current_actor_label()
  from (values ('customer', v_c), ('subscription', v_s), ('device', v_d)) k(kind, n);
  return jsonb_build_object('ids_customer', v_c, 'ids_subscription', v_s, 'ids_device', v_d,
                            'ids_skipped', (v_nc - v_c) + (v_ns - v_s) + (v_nd - v_d));
end
$$;

-- The id lists' one delete (in the take, with the owner's rights; flash.snapshot and the current tenant checked): the
-- tenant's lists of month ends more than flash.id_list_retention_months before the tenant's today. The cutoff is
-- computed here from the setting and the tenant's own today alone: no caller passes a date, so no call removes a list
-- that is still within its retention. One audit row per removal with its count. Answers the rows removed
create or replace function cma.flash_snapshot_ids_expire_of(p_tenant_id uuid)
returns integer
language plpgsql
as $$
declare
  v_before date;
  v_n      integer;
begin
  perform cma.assert_permission('flash.snapshot');
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'the id lists expire for the current tenant only' using errcode = 'CMA06';
  end if;
  v_before := (cma.tenant_today_of(p_tenant_id)
               - make_interval(months => cma.setting_of(p_tenant_id, 'flash.id_list_retention_months')::integer))::date;
  delete from cma.flash_snapshot_ids x where x.tenant_id = p_tenant_id and x.snapshot_date < v_before;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
    values (p_tenant_id, 'flash_snapshot_ids', 'delete', jsonb_build_object('before', v_before, 'rows', v_n), null,
            cma.current_user_id(), cma.current_actor_label());
  end if;
  return v_n;
end
$$;

-- The watch after a take of p_date (in its transaction, in a subtransaction of its own, with the owner's rights;
-- flash.snapshot and the current tenant checked here too), as of p_now: the conditions that hold now, each a finding
-- unless one is open already (one per kind, overview, dims and measure: a condition that holds twice is one finding);
-- every open finding whose condition no longer holds resolved on p_date. Answers the counts
--   jump              a count measure of a stock overview per market (its [market] row) that moved from p_date - 1 to
--                     p_date by more than flash.watch_jump_min and more than flash.watch_jump_pct percent of the earlier
--                     value (both dates with a succeeded snapshot; a market without a row has 0; a measure left out of
--                     the totals row on either date, one that does not apply that day, is not compared)
--   flow_zero         a count measure of a flow overview whose [market] row was above 0 on each of the 7 dates before
--                     p_date (each with a succeeded snapshot) and is 0 or absent on p_date
--   source_stale      an active connection of a source Flash reads whose last succeeded run finished more than three
--                     cadences before p_now; the cadence its poll interval setting (a setting named *_poll_interval_minutes),
--                     else the median gap between its succeeded runs of the 7 days before p_now (none: no finding). One
--                     finding per source, adapter and store: two stale connections alike are one finding with the
--                     oldest read, and how many they are (detail connections)
--   snapshot_missing  the date before p_date has no succeeded snapshot while an earlier one has
--   dq_rise           a data-quality check (its [check] row) that rose from p_date - 1 to p_date by more than the jump
--                     thresholds
create or replace function cma.flash_watch_of(p_tenant_id uuid, p_date date, p_now timestamptz)
returns jsonb
language plpgsql
as $$
declare
  v_pct      numeric := cma.setting_of(p_tenant_id, 'flash.watch_jump_pct')::numeric;
  v_min      numeric := cma.setting_of(p_tenant_id, 'flash.watch_jump_min')::numeric;
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
  ), r as (
    -- a connection's cadence: its poll interval setting, else the median gap between its succeeded runs of 7 days
    select c.kind, c.adapter, c.store,
           (select min((e.value #>> '{}')::numeric) from jsonb_each(c.settings) e
            where e.key like '%\_poll\_interval\_minutes' and (e.value #>> '{}') ~ '^[0-9]{1,5}$') as set_minutes,
           (select percentile_cont(0.5) within group (order by g.gap)
            from (select extract(epoch from x.finished_at - lag(x.finished_at) over (order by x.finished_at)) / 60 as gap
                  from cma.sync_run x
                  where x.tenant_id = p_tenant_id and x.connection_id = c.id and x.status = 'succeeded'
                    and x.finished_at > p_now - interval '7 days' and x.finished_at <= p_now) g
            where g.gap is not null and g.gap > 0) as seen_minutes,
           (select max(x.finished_at) from cma.sync_run x
            where x.tenant_id = p_tenant_id and x.connection_id = c.id and x.status = 'succeeded' and x.finished_at <= p_now) as last_at
    from c
    where c.kind in ('commerce', 'subscriptions', 'assets', 'crm', 'reviews')
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
    -- source_stale: per source, adapter and store, the stale connection with the oldest read, and how many are stale
    select 'source_stale', null::text, z.dims, null::text, z.value, null::numeric, z.threshold,
           z.detail || jsonb_build_object('connections', z.n)
    from (select distinct on (st.dims) st.dims, st.value, st.threshold, st.detail, count(*) over (partition by st.dims) as n
          from (select jsonb_strip_nulls(jsonb_build_object('source', r.kind, 'adapter', r.adapter, 'store', r.store)) as dims,
                       round(extract(epoch from p_now - r.last_at) / 60) as value, round(3 * coalesce(r.set_minutes, r.seen_minutes)::numeric) as threshold,
                       jsonb_build_object('cadence_minutes', round(coalesce(r.set_minutes, r.seen_minutes)::numeric, 1),
                                          'cadence_basis', case when r.set_minutes is not null then 'setting' else 'runs' end,
                                          'age_minutes', round(extract(epoch from p_now - r.last_at) / 60), 'last_read_at', r.last_at) as detail,
                       r.last_at
                from r
                where r.last_at is not null and coalesce(r.set_minutes, r.seen_minutes) is not null
                  and extract(epoch from p_now - r.last_at) / 60 > 3 * coalesce(r.set_minutes, r.seen_minutes)) st
          order by st.dims, st.last_at, st.value desc) z
    union all
    -- snapshot_missing
    select 'snapshot_missing', null::text, '{}'::jsonb, null::text, ((p_date - 1) - x.last_before)::numeric, null::numeric, null::numeric,
           jsonb_build_object('missing_from', x.last_before + 1, 'missing_to', p_date - 1, 'days', (p_date - 1) - x.last_before)
    from (select max(r.snapshot_date) as last_before from cma.flash_snapshot_run r
          where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date < p_date - 1) x
    where x.last_before is not null and not v_prev_ok
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

-- The take at an instant (an instant other than now is the owner's alone; the application reaches the take through
-- cma.flash_snapshot_take only, so only the verify takes one at another instant): the latest due date at p_now
-- (cma.flash_due_date_of), unless a succeeded run holds it; under a transaction-level advisory lock per tenant.
--   1. every earlier date since the last succeeded or missed one that never got a succeeded take is recorded as missed
--      (one run row each, kept even when this take fails): never taken afterwards, never silently absent
--   2. every overview through cma.flash_compute_of (stock figures measured against the date, flows for that date alone),
--      the id lists on a month's last day, the expiry of the old lists
--   3. the watch, in a subtransaction of its own: its failure is the run's watch_error, never the snapshot's loss
--   4. the run row: its due time and whether the take is late (its instant more than an hour after the due time)
-- A failure in 2 leaves nothing but a failed run row with the error's code; the next hourly run tries the date again
-- while it is the latest due date. Answers what it did
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

-- The job's entry (flash.snapshot): the current tenant, as of now. SECURITY DEFINER, owned by cma_owner, search path
-- pinned, executable by the application only: the application holds no write on the four Flash tables, so this is the
-- one way a figure, an id list, a run or a finding is ever written, always the live computation's and always for the
-- latest due date. The permission and the tenant are checked before anything else
create or replace function cma.flash_snapshot_take(p_tenant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, cma, pg_temp
as $$
begin
  perform cma.assert_permission('flash.snapshot');
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a Flash snapshot is taken for the current tenant only' using errcode = 'CMA06';
  end if;
  return cma.flash_snapshot_take_at(p_tenant_id, now());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 11. The reads (reports.view or performance.team; data-quality rows: reports.view or tenant.configure)
-- ---------------------------------------------------------------------------------------------
-- The checks every Flash read makes (CMA04): a market's code or unknown; a date no later than the tenant's today; a
-- period of 1 to 366 business dates, from before to
create or replace function cma.assert_flash_params(p_market text, p_as_of date, p_from date, p_to date, p_today date)
returns void
language plpgsql immutable
as $$
begin
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'a market is a two-letter code or unknown' using errcode = 'CMA04';
  end if;
  if p_as_of is not null and p_as_of >= p_today then
    raise exception 'a snapshot''s date is a business date that has ended (before %)', p_today using errcode = 'CMA04';
  end if;
  if (p_from is null) <> (p_to is null) or p_from > p_to or p_to - p_from > 365 then
    raise exception 'a period runs from a date to the same or a later one, at most 366 days' using errcode = 'CMA04';
  end if;
  if p_to > p_today then
    raise exception 'a period ends today (%) at the latest', p_today using errcode = 'CMA04';
  end if;
end
$$;

-- The labels of an overview's dims (configuration names, never a record's): markets, stores, device statuses and models,
-- pipelines (queues) and stages (keyed pipeline:stage), task types and statuses, data-quality checks
create or replace function cma.flash_labels_of(p_tenant_id uuid, p_overview text)
returns jsonb
language sql stable
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'market', (select jsonb_object_agg(m.code, m.name) from cma.market m where m.tenant_id = p_tenant_id),
    'store', case when p_overview in ('customers', 'subscriptions', 'churn', 'orders', 'payments')
                  then (select jsonb_object_agg(st.handle, st.name) from cma.commerce_store st where st.tenant_id = p_tenant_id) end,
    'status', case p_overview
                when 'installed_base' then (select jsonb_object_agg(ds.key, ds.name) from cma.device_status ds where ds.tenant_id = p_tenant_id)
                when 'open_tasks' then (select jsonb_object_agg(ts.status_ref, ts.label) from cma.connection_task_status ts where ts.tenant_id = p_tenant_id) end,
    'model', case when p_overview = 'installed_base'
                  then (select jsonb_object_agg(dm.key, dm.name) from cma.device_model dm where dm.tenant_id = p_tenant_id) end,
    'pipeline', case when p_overview = 'open_deals'
                     then (select jsonb_object_agg(p.source_pipeline_id, p.label) from cma.connection_pipeline p
                           where p.tenant_id = p_tenant_id and p.record_type = 'deal') end,
    'queue', case when p_overview = 'open_tickets'
                  then (select jsonb_object_agg(p.source_pipeline_id, p.label) from cma.connection_pipeline p
                        where p.tenant_id = p_tenant_id and p.record_type = 'ticket') end,
    'stage', case when p_overview in ('open_deals', 'open_tickets')
                  then (select jsonb_object_agg(cs.source_pipeline_id || ':' || cs.source_stage_id, cs.label) from cma.connection_stage cs
                        where cs.tenant_id = p_tenant_id and cs.record_type = case p_overview when 'open_deals' then 'deal' else 'ticket' end) end,
    'type', case when p_overview = 'open_tasks'
                 then (select jsonb_object_agg(tt.type_ref, tt.label) from cma.connection_task_type tt where tt.tenant_id = p_tenant_id) end,
    'check', case when p_overview = 'data_quality'
                  then (select jsonb_object_agg(c.check_key, c.description) from cma.data_quality_catalog() c) end))
$$;

-- An overview's rows of a set of snapshot dates summed per grouping set: numbers summed, amounts summed per currency
-- (the flow overviews' period; a stock overview is read for one date)
create or replace function cma.flash_snapshot_sum_of(p_tenant_id uuid, p_overview text, p_dates date[])
returns table (dims jsonb, measures jsonb)
language sql stable
as $$
  with x as (
    select s.dims, e.key, e.value
    from cma.flash_snapshot s
    cross join lateral jsonb_each(s.measures) e
    where s.tenant_id = p_tenant_id and s.overview = p_overview and s.snapshot_date = any (p_dates)
  ), num as (
    select x.dims, x.key, sum((x.value #>> '{}')::numeric) as v from x where jsonb_typeof(x.value) = 'number' group by 1, 2
  ), amt as (
    select a.dims, a.key, jsonb_object_agg(a.cur, a.v) as obj
    from (select x.dims, x.key, c.key as cur, sum((c.value #>> '{}')::numeric) as v
          from x cross join lateral jsonb_each(x.value) c
          where jsonb_typeof(x.value) = 'object'
          group by 1, 2, 3) a
    group by 1, 2
  ), k as (
    select distinct x.dims, x.key, jsonb_typeof(x.value) as t from x
  )
  select k.dims, jsonb_object_agg(k.key, case when k.t = 'object' then coalesce(a.obj, '{}'::jsonb) else to_jsonb(n.v) end)
  from k
  left join num n on n.dims = k.dims and n.key = k.key
  left join amt a on a.dims = k.dims and a.key = k.key
  group by k.dims
$$;

-- An overview's document for an explicit tenant (no permission checked: the reads below check it). Live (p_as_of null):
-- cma.flash_compute_of now, a flow over p_from to p_to (today when absent). A snapshot (p_as_of a date): a stock overview
-- as stored for that date (CMA02 without a succeeded snapshot), a flow summed over the dates of p_from to p_to (as_of
-- alone when absent) that have one (CMA02 when none has), the dates without one listed. The totals are the {} row, or the
-- market's row when p_market is given (zeros when the market has none); the rows every other grouping set's, of that
-- market only when given. The sources' state (at the take for a snapshot), the labels, the settings the figures follow,
-- the first snapshot's date; churn's active subscriptions at the period's end (the subscriptions snapshot of that date,
-- else now for a live period that runs to today); data quality's history (each check per snapshot date, 30 dates)
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
    select r.sources into v_sources from cma.flash_snapshot_run r
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
      from jsonb_each(v_total) e where e.key not in ('median_age_days', 'oldest_age_days');
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
      'file_max_rows', cma.setting_of(p_tenant_id, 'flash.file_max_rows')::integer),
    'first_snapshot_date', (select min(r.snapshot_date) from cma.flash_snapshot_run r where r.tenant_id = p_tenant_id and r.status = 'succeeded'),
    'today', cma.tenant_today_of(p_tenant_id), 'time_zone', (select t.timezone from cma.tenant t where t.id = p_tenant_id))
    || v_extra;
end
$$;

-- One overview in one read (reports.view or performance.team): live, or as of a snapshot's date; flows over a period
create or replace function cma.flash_overview(p_overview text, p_market text default null, p_as_of date default null,
                                              p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_flash_overview(p_overview);
  perform cma.assert_flash_params(p_market, p_as_of, p_from, p_to, cma.tenant_today_of(v_tenant));
  return cma.flash_document_of(v_tenant, p_overview, p_market, p_as_of, p_from, p_to);
end
$$;

-- A list's order: the sort key's expression from the overview's whitelist (an amount sorted within its currency:
-- currency first), nulls last, then a stable tie-break on the record's id; null for a key outside the whitelist
create or replace function cma.flash_order_by(p_overview text, p_sort text, p_descending boolean)
returns text
language sql immutable
as $$
  select case when e.expr is null or not (p_sort = any (coalesce((select o.sorts from cma.flash_overviews() o where o.key = p_overview), '{}'::text[]))) then null
              else replace(e.expr, '{d}', case when coalesce(p_descending, false) then 'desc' else 'asc' end) || ' nulls last, ' || e.tie end
  from (select case p_overview || ':' || p_sort
                 when 'customers:lifetime_orders' then 'x.lifetime_orders {d}'
                 when 'customers:total_spent' then 'x.currency asc nulls last, x.total_spent {d}'
                 when 'customers:customer_id' then 'x.source_id {d}'
                 when 'customers:store' then 'x.store {d}'
                 when 'customers:market' then 'x.market {d}'
                 when 'customers:active_subscriptions' then 'x.active_subscriptions {d}'
                 when 'customers:devices' then 'x.devices {d}'
                 when 'subscriptions:subscription_id' then 'x.source_id {d}'
                 when 'subscriptions:store' then 'x.store {d}'
                 when 'subscriptions:market' then 'x.market {d}'
                 when 'subscriptions:status' then 'x.status {d}'
                 when 'subscriptions:payment_state' then 'x.payment_state {d}'
                 when 'subscriptions:amount_per_cycle' then 'x.currency asc nulls last, x.amount_per_cycle {d}'
                 when 'subscriptions:next_billing_at' then 'x.next_billing_at {d}'
                 when 'subscriptions:retry_since' then 'x.retry_since {d}'
                 when 'subscriptions:devices' then 'x.devices {d}'
                 when 'installed_base:serial' then 'x.serial {d}'
                 when 'installed_base:model' then 'x.model {d}'
                 when 'installed_base:market' then 'x.market {d}'
                 when 'installed_base:status' then 'x.status {d}'
                 when 'installed_base:warehouse' then 'x.warehouse {d}'
                 when 'installed_base:past_due_items' then 'x.past_due_items {d}'
                 when 'installed_base:next_due_on' then 'x.next_due_on {d}'
                 when 'churn:churned_at' then 'x.churned_at {d}'
                 when 'churn:subscription_id' then 'x.source_id {d}'
                 when 'churn:store' then 'x.store {d}'
                 when 'churn:market' then 'x.market {d}'
                 when 'churn:reason' then 'x.reason {d}'
                 when 'churn:cycles' then 'x.cycles {d}'
                 when 'orders:created_at' then 'x.created_at {d}'
                 when 'orders:order_number' then 'x.order_number {d}'
                 when 'orders:store' then 'x.store {d}'
                 when 'orders:market' then 'x.market {d}'
                 when 'orders:kind' then 'x.kind {d}'
                 when 'orders:total' then 'x.currency asc nulls last, x.total {d}'
                 when 'payments:at' then 'x.at {d}'
                 when 'payments:kind' then 'x.kind {d}'
                 when 'payments:status' then 'x.status {d}'
                 when 'payments:amount' then 'x.currency asc nulls last, x.amount {d}'
                 when 'payments:store' then 'x.store {d}'
                 when 'payments:market' then 'x.market {d}'
                 when 'open_deals:age_days' then 'x.age_days {d}'
                 when 'open_deals:created_at' then 'x.created_at {d}'
                 when 'open_deals:record_id' then 'x.source_id {d}'
                 when 'open_deals:pipeline' then 'x.pipeline {d}'
                 when 'open_deals:stage' then 'x.stage {d}'
                 when 'open_deals:market' then 'x.market {d}'
                 when 'open_tickets:age_days' then 'x.age_days {d}'
                 when 'open_tickets:created_at' then 'x.created_at {d}'
                 when 'open_tickets:record_id' then 'x.source_id {d}'
                 when 'open_tickets:queue' then 'x.queue {d}'
                 when 'open_tickets:stage' then 'x.stage {d}'
                 when 'open_tickets:market' then 'x.market {d}'
                 when 'open_tasks:due_at' then 'x.due_at {d}'
                 when 'open_tasks:task_id' then 'x.source_id {d}'
                 when 'open_tasks:type' then 'x.type {d}'
                 when 'open_tasks:status' then 'x.status {d}'
                 when 'open_tasks:market' then 'x.market {d}'
                 when 'reviews:submitted_at' then 'x.submitted_at {d}'
                 when 'reviews:rating' then 'x.rating {d}'
                 when 'reviews:market' then 'x.market {d}'
                 when 'reviews:review_id' then 'x.source_id {d}'
                 when 'data_quality:object_id' then 'x.object_id {d}'
                 when 'data_quality:check' then 'x.check_key {d}'
                 when 'data_quality:market' then 'x.market {d}'
               end as expr,
               case p_overview
                 when 'customers' then 'x.source_id, x.customer_id'
                 when 'subscriptions' then 'x.source_id, x.subscription_id'
                 when 'installed_base' then 'x.source_id, x.device_id'
                 when 'churn' then 'x.source_id, x.business_date, x.connection_id'
                 when 'orders' then 'x.source_id, x.order_id'
                 when 'payments' then 'x.source_id, x.kind, x.connection_id'
                 when 'open_deals' then 'x.source_id, x.deal_id'
                 when 'open_tickets' then 'x.source_id, x.ticket_id'
                 when 'open_tasks' then 'x.source_id, x.task_id'
                 when 'reviews' then 'x.source_id, x.review_id'
                 when 'data_quality' then 'x.check_key, x.object_type, x.object_id, x.connection_id, x.value'
               end as tie) e
$$;

-- An overview's list, live, for an explicit tenant (no permission checked: cma.flash_rows checks it): the records of
-- the overview's base set after the filters (its dims, and measure: the records one count measure counts), in the
-- order, p_limit from p_offset, each as an object of ids, codes, amounts, times and links; total the count before the
-- limit. Flows over p_from to p_to
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
      v_base := 'cma.flash_customers_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
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
      v_base := 'cma.flash_subscriptions_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'') and ($1 ->> ''payment_state'' is null or x.payment_state = $1 ->> ''payment_state'')
                  and case $1 ->> ''measure'' when ''active_subscriptions'' then x.is_active when ''paused_subscriptions'' then x.status = ''paused'' else true end';
      v_obj := 'jsonb_build_object(''subscription_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market,
                  ''customer_id'', x.customer_source_id, ''contact_id'', x.contact_source_id,
                  ''contact_url'', cma.record_url(x.crm_connection_id, ''contact'', x.contact_source_id), ''status'', x.status,
                  ''payment_state'', x.payment_state, ''amount_per_cycle'', x.amount_per_cycle, ''currency'', x.currency,
                  ''billing_interval'', x.billing_interval, ''billing_interval_count'', x.billing_interval_count, ''next_billing_at'', x.next_billing_at,
                  ''retry_since'', x.retry_since, ''last_attempt'', x.last_attempt, ''devices'', x.devices)';
    when 'installed_base' then
      -- the linked subscription's payment state for the list (0008zl's derivation, once per read): the figures need none
      v_base := '(select d.*, ps.payment_state as subscription_payment_state
                  from cma.flash_devices_of($2, $7) d
                  left join cma.subscription_payment_state_of($2) ps on ps.subscription_id = d.subscription_id)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and ($1 ->> ''model'' is null or x.model = $1 ->> ''model'') and ($1 ->> ''warehouse'' is null or x.warehouse = $1 ->> ''warehouse'')
                  and ($1 ->> ''link'' is null or x.link = $1 ->> ''link'')
                  and case $1 ->> ''measure'' when ''in_field'' then x.is_in_field when ''in_stock'' then x.is_in_stock
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
    using p_filters, p_tenant_id, p_limit, p_offset, v_from, v_to, v_today;
  return v_res;
end
$$;

-- A past month end's frozen list (customers, subscriptions, installed_base) for an explicit tenant: the ids as frozen,
-- joined to nothing that could have changed (source id, connection, market, state); filters market and status (the
-- state; not for customers, all active), measure the list's own; sorted by id, market or status. CMA02 without a list
-- of that kind for that date, and CMA02 (expired) for a list its take wrote that flash.id_list_retention_months has
-- since removed: never an empty list in its place
create or replace function cma.flash_id_rows_of(p_tenant_id uuid, p_overview text, p_filters jsonb, p_sort text, p_descending boolean,
                                                p_limit integer, p_offset integer, p_as_of date)
returns jsonb
language plpgsql stable
as $$
declare
  v_kind  text := case p_overview when 'customers' then 'customer' when 'subscriptions' then 'subscription' when 'installed_base' then 'device' end;
  v_order text;
begin
  if v_kind is null then
    raise exception 'a list of a past date exists for customers, subscriptions and installed_base, at a month end' using errcode = 'CMA02';
  end if;
  if exists (select 1 from jsonb_object_keys(coalesce(p_filters, '{}'::jsonb)) k
             where k not in ('market', 'status', 'measure') or (k = 'status' and v_kind = 'customer'))
     or (p_filters ? 'measure' and p_filters ->> 'measure' <> case v_kind when 'customer' then 'active_customers'
                                                                         when 'subscription' then 'active_subscriptions' else 'devices' end) then
    raise exception 'a past month end''s list is filtered by market and status only' using errcode = 'CMA04';
  end if;
  v_order := case coalesce(p_sort, 'id')
               when 'customer_id' then 'x.source_id' when 'subscription_id' then 'x.source_id' when 'serial' then 'x.source_id' when 'id' then 'x.source_id'
               when 'market' then 'x.market' when 'status' then 'x.state' end;
  if v_order is null then
    raise exception 'a past month end''s list sorts by its id, market or status' using errcode = 'CMA04';
  end if;
  if not exists (select 1 from cma.flash_snapshot_ids x where x.tenant_id = p_tenant_id and x.snapshot_date = p_as_of and x.record_kind = v_kind) then
    if exists (select 1 from cma.flash_snapshot_run r where r.tenant_id = p_tenant_id and r.snapshot_date = p_as_of and r.status = 'succeeded'
               and coalesce((r.counts ->> ('ids_' || v_kind))::integer, 0) > 0) then
      raise exception 'the frozen list of % for % has expired (flash.id_list_retention_months)', v_kind, p_as_of using errcode = 'CMA02';
    end if;
    if not exists (select 1 from cma.flash_snapshot_run r where r.tenant_id = p_tenant_id and r.snapshot_date = p_as_of and r.status = 'succeeded'
                   and p_as_of = (date_trunc('month', p_as_of) + interval '1 month - 1 day')::date) then
      raise exception 'no frozen list of % for %: lists are kept for month ends', v_kind, p_as_of using errcode = 'CMA02';
    end if;
  end if;
  return (
    with f as materialized (
      select x.* from cma.flash_snapshot_ids x
      where x.tenant_id = p_tenant_id and x.snapshot_date = p_as_of and x.record_kind = v_kind
        and (p_filters ->> 'market' is null or x.market = p_filters ->> 'market')
        and (p_filters ->> 'status' is null or x.state = p_filters ->> 'status')
    ), p as (
      select x.*, row_number() over (order by
               case when v_order = 'x.market' then x.market when v_order = 'x.state' then x.state else x.source_id end
                 collate "C",
               x.source_id, x.connection_id) as ord
      from f x
    )
    select jsonb_build_object('total', (select count(*) from f),
                              'rows', coalesce((select jsonb_agg(jsonb_build_object('source_id', q.source_id, 'connection_id', q.connection_id,
                                                                                    'market', q.market, 'state', q.state, 'snapshot_date', q.snapshot_date)
                                                                 order by q.pos)
                                                from (select p.*, case when coalesce(p_descending, false) then -p.ord else p.ord end as pos from p
                                                      order by case when coalesce(p_descending, false) then -p.ord else p.ord end
                                                      limit p_limit offset p_offset) q), '[]'::jsonb)));
end
$$;

-- A list of one overview (reports.view or performance.team): live, the records behind a figure (the filters: the
-- overview's dims and measure, a count measure), sorted by a whitelisted key (the overview's first when absent),
-- p_limit rows (1 to flash.file_max_rows) from p_offset, the total before the limit; flows over a period. With p_as_of,
-- a past month end's frozen list (customers, subscriptions, installed_base; CMA02 for another date or overview). The answer
-- says whether the overview's source is set up (set_up: an empty list of a source not set up is no zero) and the tenant's
-- time zone (a file's instants and its name follow the tenant, not the reader)
create or replace function cma.flash_rows(p_overview text, p_filters jsonb default '{}'::jsonb, p_sort text default null,
                                          p_descending boolean default false, p_limit integer default 500, p_offset integer default 0,
                                          p_as_of date default null, p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_today   date;
  v_filters jsonb := coalesce(p_filters, '{}'::jsonb);
  o         record;
  v_sort    text;
  v_res     jsonb;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_flash_overview(p_overview);
  v_today := cma.tenant_today_of(v_tenant);
  perform cma.assert_flash_params(null, p_as_of, p_from, p_to, v_today);
  select * into o from cma.flash_overviews() x where x.key = p_overview;
  if jsonb_typeof(v_filters) <> 'object'
     or exists (select 1 from jsonb_each(v_filters) e
                where not (e.key = any (o.dims) or e.key = 'measure') or jsonb_typeof(e.value) <> 'string'
                   or length(e.value #>> '{}') not between 1 and 100)
     or (v_filters ? 'measure' and not ((v_filters ->> 'measure') = any (o.count_measures))) then
    raise exception 'filters are the overview''s dims (%) and measure (one of %), each a text', array_to_string(o.dims, ', '),
      array_to_string(o.count_measures, ', ') using errcode = 'CMA04';
  end if;
  -- a measure that does not apply has no records: with_required_refs while no contact reference is required
  if p_overview = 'customers' and (v_filters ->> 'measure') = 'with_required_refs'
     and cardinality(cma.flash_list_of(cma.setting_of(v_tenant, 'commerce.required_contact_refs'))) = 0 then
    raise exception 'with_required_refs does not apply: commerce.required_contact_refs is empty' using errcode = 'CMA04';
  end if;
  perform cma.assert_flash_params(v_filters ->> 'market', null, null, null, v_today);
  if p_limit is null or p_limit not between 1 and cma.setting_of(v_tenant, 'flash.file_max_rows')::integer
     or p_offset is null or p_offset not between 0 and 100000000 then
    raise exception 'a list reads 1 to % rows from an offset of 0 or more', cma.setting_of(v_tenant, 'flash.file_max_rows') using errcode = 'CMA04';
  end if;
  if p_as_of is null then
    v_sort := coalesce(p_sort, o.sorts[1]);
    v_res := cma.flash_rows_of(v_tenant, p_overview, v_filters, v_sort, p_descending, p_limit, p_offset,
                               case when o.kind = 'flow' then coalesce(p_from, v_today) end, case when o.kind = 'flow' then coalesce(p_to, v_today) end);
  else
    v_sort := p_sort;
    v_res := cma.flash_id_rows_of(v_tenant, p_overview, v_filters, p_sort, p_descending, p_limit, p_offset, p_as_of);
  end if;
  return jsonb_build_object('overview', p_overview, 'mode', case when p_as_of is null then 'live' else 'snapshot' end,
                            'as_of', case when p_as_of is null then to_jsonb(now()) else to_jsonb(p_as_of) end,
                            'from', case when o.kind = 'flow' and p_as_of is null then coalesce(p_from, v_today) end,
                            'to', case when o.kind = 'flow' and p_as_of is null then coalesce(p_to, v_today) end,
                            'filters', v_filters, 'sort', v_sort, 'descending', coalesce(p_descending, false), 'limit', p_limit, 'offset', p_offset,
                            'set_up', case when o.source is null then true
                                           else coalesce((cma.flash_sources_of(v_tenant) -> o.source ->> 'set_up')::boolean, false) end,
                            'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant))
         || v_res;
end
$$;

-- An overview's headline for the landing: the figure of the totals (or the market's) row, among rows dims and measures
create or replace function cma.flash_pick_of(p_rows jsonb, p_market text, p_measure text)
returns jsonb
language sql immutable
as $$
  select r -> 'measures' -> p_measure
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
  where r -> 'dims' = case when p_market is null then '{}'::jsonb else jsonb_build_object('market', p_market) end
$$;

-- An overview's stored headline over a set of snapshot dates (summed for a flow; one date for a stock): the market's figure,
-- 0 when the market has no row on dates that hold the overview, null when no date holds it
create or replace function cma.flash_stored_headline_of(p_tenant_id uuid, p_overview text, p_market text, p_dates date[])
returns jsonb
language sql stable
as $$
  with r as (
    select jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures)) as rows
    from cma.flash_snapshot_sum_of(p_tenant_id, p_overview, coalesce(p_dates, '{}'::date[])) c
    where c.dims = '{}'::jsonb or c.dims = jsonb_build_object('market', p_market)
  )
  select coalesce(cma.flash_pick_of(r.rows, p_market, o.headline),
                  case when cma.flash_pick_of(r.rows, null, o.headline) is not null then '0'::jsonb end)
  from r cross join cma.flash_overviews() o
  where o.key = p_overview
$$;

-- One overview's live headline (reports.view or performance.team): the totals' (or the market's) headline figure of
-- cma.flash_compute_of, now or over a period for a flow; null when its source is not set up. The landing asks it once per
-- card after the page, so the page itself reads stored figures only
create or replace function cma.flash_headline(p_overview text, p_market text default null, p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable
set jit = off
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_today  date;
  o        record;
  v_rows   jsonb;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_flash_overview(p_overview);
  v_today := cma.tenant_today_of(v_tenant);
  perform cma.assert_flash_params(p_market, null, p_from, p_to, v_today);
  select * into o from cma.flash_overviews() x where x.key = p_overview;
  select jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures)) into v_rows
  from cma.flash_compute_of(v_tenant, p_overview, case when o.kind = 'flow' then coalesce(p_from, v_today) end,
                            case when o.kind = 'flow' then coalesce(p_to, v_today) end) c
  where c.dims = '{}'::jsonb or c.dims = jsonb_build_object('market', p_market);
  return jsonb_build_object('overview', p_overview, 'headline', o.headline, 'market', p_market, 'as_of', now(),
    'from', case when o.kind = 'flow' then coalesce(p_from, v_today) end, 'to', case when o.kind = 'flow' then coalesce(p_to, v_today) end,
    'set_up', v_rows is not null,
    'value', coalesce(cma.flash_pick_of(v_rows, p_market, o.headline),
                      case when cma.flash_pick_of(v_rows, null, o.headline) is not null then '0'::jsonb end));
end
$$;

-- Reports → Flash's landing in one read of stored figures only (reports.view or performance.team), so it answers at once
-- whatever the volume: per overview whether its source is set up and its figures from the snapshots. As of a date: the
-- headline as stored for that date (a flow summed over the period's dates that have a snapshot) and the figure to compare
-- it with (a stock's snapshot before; a flow's same number of dates before the period, when every one has a snapshot).
-- Now: the latest snapshot's headline as the figure to compare with (a flow's: the period before, as above); the live
-- headline is each card's own read (cma.flash_headline). And the sources' state, the open watch findings, the markets,
-- the first and the latest snapshot's date. A date without a snapshot answers snapshot_missing with the nearest dates
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
        'today', cma.tenant_today_of(v_tenant), 'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant));
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
    'today', cma.tenant_today_of(v_tenant), 'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant));
end
$$;

-- The snapshot dates of a period (reports.view or performance.team; at most 400 days, the last 90 when absent): every run
-- with its status and the dates missed before it, the first and the latest succeeded date, the open watch findings
create or replace function cma.flash_snapshots(p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_to     date;
  v_from   date;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  v_to := coalesce(p_to, cma.tenant_today_of(v_tenant));
  v_from := coalesce(p_from, v_to - 90);
  if v_from > v_to or v_to - v_from > 400 then
    raise exception 'a period of snapshot dates runs from a date to the same or a later one, at most 400 days' using errcode = 'CMA04';
  end if;
  return jsonb_build_object(
    'from', v_from, 'to', v_to,
    'dates', (select coalesce(jsonb_agg(jsonb_build_object('date', r.snapshot_date, 'status', r.status, 'missed_before', r.missed_before,
                                                           'finished_at', r.finished_at, 'error', r.error)
                                        order by r.snapshot_date, r.finished_at), '[]'::jsonb)
              from cma.flash_snapshot_run r where r.tenant_id = v_tenant and r.snapshot_date between v_from and v_to),
    'first_snapshot_date', (select min(r.snapshot_date) from cma.flash_snapshot_run r where r.tenant_id = v_tenant and r.status = 'succeeded'),
    'last_snapshot_date', (select max(r.snapshot_date) from cma.flash_snapshot_run r where r.tenant_id = v_tenant and r.status = 'succeeded'),
    'watch', (select coalesce(jsonb_agg(jsonb_build_object('kind', f.kind, 'overview', f.overview, 'dims', f.dims, 'measure', f.measure,
                                                           'value', f.value, 'previous', f.previous, 'threshold', f.threshold, 'detail', f.detail,
                                                           'snapshot_date', f.snapshot_date)
                                        order by f.snapshot_date desc, f.kind, f.overview, f.dims::text), '[]'::jsonb)
              from cma.flash_watch_finding f where f.tenant_id = v_tenant and f.state = 'open'));
end
$$;

-- A data-quality check's findings (reports.view or tenant.configure): every row of the check, of a market when given,
-- p_limit (1 to flash.file_max_rows) from p_offset, sorted by the record's id: its ids, value, market, where it is
-- fixed (kind and adapter), the record's link and the related record (a customer's contact, a device's subscription);
-- total before the limit. CMA04 for a key no addition defines
create or replace function cma.data_quality_rows(p_check text, p_market text default null, p_limit integer default 500, p_offset integer default 0)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'tenant.configure']);
  if p_check is null or not exists (select 1 from cma.data_quality_catalog() c where c.check_key = p_check) then
    raise exception 'check % is no data-quality check', p_check using errcode = 'CMA04';
  end if;
  perform cma.assert_flash_params(p_market, null, null, null, cma.tenant_today_of(v_tenant));
  if p_limit is null or p_limit not between 1 and cma.setting_of(v_tenant, 'flash.file_max_rows')::integer
     or p_offset is null or p_offset not between 0 and 100000000 then
    raise exception 'a list reads 1 to % rows from an offset of 0 or more', cma.setting_of(v_tenant, 'flash.file_max_rows') using errcode = 'CMA04';
  end if;
  return jsonb_build_object('check', p_check, 'market', p_market, 'limit', p_limit, 'offset', p_offset,
                            'description', (select c.description from cma.data_quality_catalog() c where c.check_key = p_check))
         || cma.flash_rows_of(v_tenant, 'data_quality', jsonb_strip_nulls(jsonb_build_object('check', p_check, 'market', p_market)),
                              'object_id', false, p_limit, p_offset, null, null);
end
$$;

-- A Flash file read or a bulk read of records, in the audit log (who saw what): the overview, the part (rows or
-- breakdown), the filters (the overview's dims and measure, each a text of 1 to 100 characters without an @; data
-- quality's check too), the market, the date or period and the rows given; never a row. reports.view or
-- performance.team, and for data quality tenant.configure too (whoever may read the records is recorded reading them)
create or replace function cma.flash_file_record(p_overview text, p_part text, p_filters jsonb, p_market text, p_as_of date, p_from date,
                                                 p_to date, p_rows integer)
returns void
language plpgsql
as $$
declare
  o record;
begin
  perform cma.assert_any_permission(case when p_overview = 'data_quality' then array['reports.view', 'performance.team', 'tenant.configure']
                                         else array['reports.view', 'performance.team'] end);
  perform cma.assert_flash_overview(p_overview);
  select * into o from cma.flash_overviews() x where x.key = p_overview;
  if p_part is null or p_part not in ('rows', 'breakdown') or p_rows is null or p_rows < 0
     or (p_filters is not null
         and (jsonb_typeof(p_filters) <> 'object' or strpos(p_filters::text, '@') > 0
              or exists (select 1 from jsonb_each(p_filters) e
                         where not (e.key = any (o.dims) or e.key = 'measure') or jsonb_typeof(e.value) <> 'string'
                            or length(e.value #>> '{}') not between 1 and 100)
              or (p_filters ? 'measure' and not ((p_filters ->> 'measure') = any (o.count_measures))))) then
    raise exception 'a file record names its part (rows or breakdown), its filters (the overview''s dims and measure, each a text) and its rows'
      using errcode = 'CMA04';
  end if;
  perform cma.assert_flash_params(p_market, p_as_of, p_from, p_to, cma.tenant_today_of(cma.current_tenant_id()));
  perform cma.assert_flash_params(p_filters ->> 'market', null, null, null, cma.tenant_today_of(cma.current_tenant_id()));
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  values (cma.current_tenant_id(), 'flash_file', 'insert', null,
          jsonb_strip_nulls(jsonb_build_object('overview', p_overview, 'part', p_part, 'filters', coalesce(p_filters, '{}'::jsonb),
                                               'market', p_market, 'as_of', p_as_of, 'from', p_from, 'to', p_to, 'rows', p_rows)),
          cma.current_user_id(), cma.current_actor_label());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 12. Contacts held for matched store customers (D2)
-- ---------------------------------------------------------------------------------------------
-- As 0008u (84), and a contact is also taken in while a commerce customer is linked to it (0008h's link), so its
-- references (among them the ones commerce.required_contact_refs names) are read and kept fresh: thin record only
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
           set country = null, country_source = null, language = null, currency = null, store = null, raw = '{}'::jsonb,
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
    if v_old.id is null then
      insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, country_source, language, currency,
                                   store, source_updated_at, source_created_at, raw)
      values (v_tenant, p_connection_id, v_system, v_src, v_country, v_csource, nullif(btrim(c ->> 'language'), ''),
              cma.json_currency(c ->> 'currency'), v_store, v_updated, v_created, coalesce(c -> 'raw', '{}'::jsonb))
      returning id into v_id;
    else
      v_id := v_old.id;
      update cma.crm_contact cc
         set country = v_country, country_source = v_csource, language = nullif(btrim(c ->> 'language'), ''),
             currency = cma.json_currency(c ->> 'currency'), store = v_store,
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
-- 13. Indexes for the lists' joins and the new checks
-- ---------------------------------------------------------------------------------------------
-- a subscription by its id across the tenant's connections (a device's subscription reference)
create index if not exists subscription_source_present_idx on cma.subscription (tenant_id, source_id) where source_deleted_at is null;
-- a device by its subscription reference
create index if not exists device_subscription_ref_idx on cma.device (tenant_id, subscription_ref)
  where source_deleted_at is null and subscription_ref is not null;
-- the renewals, failed renewals and churn events of a period
create index if not exists subscription_event_type_occurred_idx on cma.subscription_event (tenant_id, event_type, occurred_at);
-- the store customers' links to CRM contacts, newest first (the ingest's sweep and nightly reconcile take in the contacts
-- of recent links, D2)
create index if not exists commerce_customer_link_matched_idx on cma.commerce_customer (tenant_id, crm_connection_id, matched_at)
  where crm_contact_source_id is not null and source_deleted_at is null;

-- ---------------------------------------------------------------------------------------------
-- 14. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.flash_list_of(text)', 'cma.flash_list_ok(text,text,integer,boolean)',
    'cma.job_permission_of(text)', 'cma.job_run_start(text)',
    'cma.flash_overviews()', 'cma.flash_definition_version(text)', 'cma.flash_keys_ok(jsonb,text[])', 'cma.assert_flash_overview(text)', 'cma.flash_row_ok(text,jsonb,jsonb)',
    'cma.flash_active_statuses_of(uuid)', 'cma.flash_ended_statuses_of(uuid)', 'cma.flash_dim_of(text,text)',
    'cma.flash_subscription_stores_of(uuid)', 'cma.flash_sources_of(uuid)', 'cma.flash_period_of(uuid,date,date)',
    'cma.flash_customers_of(uuid)', 'cma.flash_subscriptions_of(uuid)', 'cma.flash_devices_of(uuid,date)', 'cma.flash_churn_of(uuid,date,date)',
    'cma.flash_orders_of(uuid,date,date)', 'cma.flash_order_lines_of(uuid,date,date)', 'cma.flash_payments_of(uuid,date,date)',
    'cma.flash_deals_of(uuid,timestamptz)', 'cma.flash_tickets_of(uuid,timestamptz)', 'cma.flash_tasks_of(uuid,date)', 'cma.flash_reviews_of(uuid,date,date)',
    'cma.data_quality_flash_checks()', 'cma.data_quality_of(uuid)', 'cma.data_quality()', 'cma.data_quality_catalog()',
    'cma.data_quality_fix_in(text,text)', 'cma.flash_findings_of(uuid)', 'cma.flash_finding_links_of(uuid,uuid,text,text)',
    'cma.flash_compute_of(uuid,text,date,date,date)',
    'cma.flash_due_date_of(text,time,timestamptz)', 'cma.flash_due_at_of(text,time,date)', 'cma.flash_id_ok(text,text,text)',
    'cma.flash_snapshot_take(uuid)',
    'cma.assert_flash_params(text,date,date,date,date)', 'cma.flash_labels_of(uuid,text)', 'cma.flash_snapshot_sum_of(uuid,text,date[])',
    'cma.flash_document_of(uuid,text,text,date,date,date)', 'cma.flash_overview(text,text,date,date,date)',
    'cma.flash_order_by(text,text,boolean)', 'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)',
    'cma.flash_id_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date)',
    'cma.flash_rows(text,jsonb,text,boolean,integer,integer,date,date,date)', 'cma.flash_pick_of(jsonb,text,text)',
    'cma.flash_stored_headline_of(uuid,text,text,date[])', 'cma.flash_headline(text,text,date,date)', 'cma.flash_page(text,date,date,date)', 'cma.flash_snapshots(date,date)', 'cma.data_quality_rows(text,text,integer,integer)',
    'cma.flash_file_record(text,text,jsonb,text,date,date,date,integer)',
    'cma.ingest_upsert_contacts(uuid,jsonb)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- the take's writers: the owner's alone (the take runs them with the owner's rights); each checks flash.snapshot and
  -- the current tenant too
  foreach f in array array[
    'cma.flash_snapshot_ids_write_of(uuid,date,uuid)', 'cma.flash_snapshot_ids_expire_of(uuid)', 'cma.flash_watch_of(uuid,date,timestamptz)',
    'cma.flash_snapshot_take_at(uuid,timestamptz)'
  ] loop
    execute format('revoke execute on function %s from public, cma_app', f);
  end loop;
end
$$;

-- JIT off for Flash's large reads and the take: PostgreSQL compiles a plan whose estimated cost passes jit_above_cost
-- (100,000 by default) before running it, and the plans of these reads (cma.data_quality_of's union of some thirty
-- checks above all) are so large that compiling took seconds longer than running them at the volume 123 measures
-- (data_quality_of: about 8.6 s with JIT, 1.8 s without, locally). A function's own setting holds for everything it
-- calls; a user may set jit, so the application's role needs nothing more. The SQL base functions keep being inlined
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.data_quality_of(uuid)', 'cma.flash_compute_of(uuid,text,date,date,date)', 'cma.flash_document_of(uuid,text,text,date,date,date)',
    'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)', 'cma.flash_id_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date)',
    'cma.flash_snapshot_take_at(uuid,timestamptz)', 'cma.flash_snapshot_ids_write_of(uuid,date,uuid)',
    'cma.flash_watch_of(uuid,date,timestamptz)', 'cma.flash_snapshot_take(uuid)'
  ] loop
    execute format('alter function %s set jit = off', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 15. Reporting views: the history for BigQuery and NocoDB
-- ---------------------------------------------------------------------------------------------
-- Every column: dates, codes, figures (no id of a record)
create or replace view cma_read.flash_snapshot as
  select id, tenant_id, snapshot_date, overview, dims, measures, definition_version, computed_at, run_id
  from cma.flash_snapshot
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.flash_snapshot_run as
  select id, tenant_id, snapshot_date, started_at, finished_at, status, counts, sources, settings, missed_before, error, due_at, late, watch_error
  from cma.flash_snapshot_run
  where cma_read.reader_sees(tenant_id);

-- Every column: the month ends' ids as frozen (store customer, subscription and register record ids, codes)
create or replace view cma_read.flash_snapshot_ids as
  select tenant_id, snapshot_date, record_kind, source_id, connection_id, market, state, run_id
  from cma.flash_snapshot_ids
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.flash_watch_finding as
  select id, tenant_id, snapshot_date, kind, overview, dims, measure, value, previous, threshold, detail, state, resolved_on, created_at
  from cma.flash_watch_finding
  where cma_read.reader_sees(tenant_id);

-- The six data-quality checks' views, as 0007d's dq_ views (ids and codes only)
create or replace view cma_read.dq_customer_required_ref_missing as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'customer_required_ref_missing';

create or replace view cma_read.dq_device_required_ref_missing as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'device_required_ref_missing';

create or replace view cma_read.dq_subscription_customer_unmatched as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'subscription_customer_unmatched';

create or replace view cma_read.dq_active_subscription_without_device as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'active_subscription_without_device';

create or replace view cma_read.dq_device_subscription_ref_unknown as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'device_subscription_ref_unknown';

create or replace view cma_read.dq_field_device_on_ended_subscription as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'field_device_on_ended_subscription';

-- ---------------------------------------------------------------------------------------------
-- 16. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zn', 'Flash: eleven overviews (customers, subscriptions, installed_base, churn, orders, payments, open_deals, open_tickets, open_tasks, reviews, data_quality) from one base set each, computed by cma.flash_compute_of per grouping set (amounts per currency), live through cma.flash_overview, cma.flash_rows and cma.flash_page and stored once per business date and tenant by cma.flash_snapshot_take (flash.snapshot, the scheduler''s only, SECURITY DEFINER: the application holds no write on the four tables; sync_run job flash_snapshot; a date due the day after it at flash.snapshot_local_time, the latest due date taken by the hourly job, a date missed recorded as such) into cma.flash_snapshot (stock figures measured against the date), cma.flash_snapshot_run and, at a month end, cma.flash_snapshot_ids (kept flash.id_list_retention_months from the tenant''s today); the deterministic watch cma.flash_watch_finding (jump, flow_zero, source_stale, snapshot_missing, dq_rise) in a subtransaction of its own; six data-quality checks with cma.data_quality_rows (active and ended statuses from settings, references matched within a market); contacts held while a commerce customer is linked to them; the Flash settings; the reader views')
on conflict (version) do nothing;

commit;
reset role;
