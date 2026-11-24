-- =============================================================================================
-- 236_speed_to_lead_cockpit.sql: addition 0009zr, Sales → Speed to lead as a cockpit (brief B40b)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: the goals, the stale days, the target, the cutoff, the markets'
-- calendars and the attempts' source stay each tenant's settings and catalogs. Runs unchanged in every database, after
-- 234_speed_to_lead_one.sql (0009zq). Rerunnable, forward-only, in one transaction with a lock timeout.
-- Run as your own IAM login: dev first, then 237_verify_speed_to_lead_cockpit.sql there (normal and provoked), then the
-- verifies that read what this re-creates, each still PASS: 235, 41, 95 and 179, edited by this change (235: V1 takes
-- either row shape and V2 finds the first outbound CRM call itself; 41: A5 names first_attempt_at and block B reads the
-- first Attempt's CRM call; 95: B8 finds the first outbound CRM call itself; 179: E3 and E4 compare no first_call_*), and
-- unchanged 191 (its clock-at-read copies of cma.speed_to_lead_of and cma.open_leads_of), 73, 75, 81, 93, 99, 101, 103,
-- 121, 151, 155 (the readers of cma.open_leads_of and the follow-up), 113, 123, 137 (they read cma.check_tenant_setting's
-- text), 161, 233, 14, 33 and 225; then 131_time_all.sql part b. 73, 75, 81, 93, 95, 99, 101, 103, 121, 151 and 155 run
-- in dev only, as before.
-- Prod BEFORE the merge, as for 0009zq: 236, 237 and the reruns that run in prod (235, 41, 179, 191, 113, 123, 137, 161,
-- 233, 14, 33, 225); the live web keeps working on the new database: it maps the columns it knows (the dropped
-- first_call_* read as absent), the summary's new columns are appended, and week is refused by the web before the
-- database sees it. Locally main's verify:api answered alike on 235's and on this script's database (376 PASS, the same
-- 6 FAIL of Flash and Active's local seed on both); Martin runs verify:api against dev before the merge.
--
-- Why (Martin, 24 November 2026; Decision log, 24 Nov 2026; the cockpit's mockup approved that day; Gaps D36): Sales →
-- Speed to lead becomes a cockpit: figures with their change against the previous period, per market, a trend, and the
-- deals attempt by attempt; every figure from B40a's one function (cma.speed_to_lead_of) and cma.deal_attempts_of,
-- nothing computed in the web. The first outbound CRM call (first_call_*), deprecated by 0009zq, goes (D36).
--
-- What it changes
--   settings          speed_to_lead.goal_within_target_pct and speed_to_lead.goal_before_cutoff_pct (text: a whole number
--                     of percent 0 to 100, or empty for no goal; empty by default, Pulse4all's values come from Martin) and
--                     speed_to_lead.stale_business_days (integer 1 to 30, default 2), each checked by
--                     cma.check_tenant_setting (based on 224, every earlier rule kept word for word)
--   cma.speed_to_lead_row   first_call_id, first_call_source_id, first_call_at and first_call_linked dropped (D36);
--                     appended: last_attempt_at, last_call_at (the latest call of the deal or its contacts from the
--                     window's start, any direction: the open leads' last call), deal_owner_ref (the deal's CRM owner
--                     reference: the open leads' owner_ref), conversations_so_far (the Attempts that were a Conversation)
--                     and window_end (the Attempts' window's end: the deals list reads each page deal's attempts with it).
--                     The brief's cutoff_at is not a column of its own: next_business_noon is that instant already (since
--                     0009zq it follows speed_to_lead.next_day_cutoff), and the deals list returns it as cutoff_at
--   cma.speed_to_lead_of     (based on 234) each deal's calls read once (cma.deal_calls_of, which cma.lead_calls_of and
--                     cma.deal_attempts_of both read from the same start), where 0009zq read them twice; the same deals
--                     and answers in every column it keeps (237 W3), the new columns from the same calls (W4)
--   cma.open_leads_of        (based on 234) the owner reference and the last call from the rows, no second read of the
--                     deals and their calls (open-decisions, B40b idea 2); the same rows in the same order (237 W5); jit off
--   cma.speed_to_lead_summary (based on 234) dropped and made again: three columns appended (attempts_mean,
--                     attempts_median, conversation_share), the group week (the Monday of the business date's ISO week),
--                     no_attempt's shares and medians null; from cma.speed_to_lead_groups_from
--   new               cma.speed_to_lead_groups_from, _figures_from and _deals_from (each part from an array of rows already
--                     read, as Attempts per deal's _from functions); cma.speed_to_lead_figures (the period and the previous
--                     one of the same length, cma.forms_previous_of's rule), cma.speed_to_lead_deals_of (a view, not_called
--                     or called, newest first, with each deal's attempts from cma.deal_attempts_of, at most 20, and stale),
--                     cma.speed_to_lead_page (the page in one read: figures, markets, trend, groups, a page of deals) and
--                     cma.speed_to_lead_view_check; types cma.speed_to_lead_figures_row and cma.speed_to_lead_deal_row
--   cma.speed_to_lead_rows   (0007d's text) jit off and force_custom_plan
--   cma_read.speed_to_lead   dropped and made again from the row type (no first_call_*, the five new columns last)
--
-- Speed at three times prod's volume (web/verify/perf-volume-fixture.sql, local, PostgreSQL 16 with a uuidv7() shim, the
-- fixture's subscriptions tenant, Postgres held to one CPU (taskset on the postmaster), each read seven times in one
-- session and the steady calls given (the 6th and 7th included); a relative measure: prod runs it again). Before (0009zq)
-- → this script, the previous month (October) unless named:
--   the follow-up job's cma.open_leads_of (its call, with ordinality)   1,160-1,360 → 700-710 ms
--   cma.speed_to_lead_summary total (the Dashboard tile, as cma_app)        690-910 → 430-440 ms
--   cma.speed_to_lead_summary by day (as cma_app)                           710-910 → 435-445 ms
--   cma.speed_to_lead_rows (as cma_app)                                     690-770 → 445-455 ms
--   cma.speed_to_lead_summary total over 92 days (as cma_app)            1,020-1,110 → 760-790 ms
--   cma.attempts_rows_of (Attempts per deal; not changed here)          1,210-1,380 → 1,130-1,190 ms
--   the page: before, the summary by day and the rows (about 1,450 ms together); now one read, cma.speed_to_lead_page
--     (October, with September for the previous period: figures, markets, trend, groups, the first 50 deals) 510-560 ms,
--     the Called tab's page 2 590-600 ms, over 92 days (and the 92 before them) 815-875 ms
--   cma.speed_to_lead_figures 480-515 ms, cma.speed_to_lead_deals_of (called, first page) 505-550 ms (the API's)
-- What made the difference: JIT. The body's estimated cost passes jit_above_cost, and compiling it took about 130 ms of
-- each call (150 to 300 ms of the job's), more than it saved: jit off on the callers, as 0008zr's reads (132). Not on
-- cma.speed_to_lead_of itself: a setting keeps it from being inlined, and its body was then planned with parameters for
-- its bounds (the job's read 1,900 ms, measured). And the plpgsql reads turned to the generic plan from the sixth call of
-- a connection (the deals list 420 → 1,090 ms): force_custom_plan, as cma.courtesy_page_of (150). Reading each deal's
-- calls once saved about 100 ms of a month. Against 131's budgets this is still over at three times prod's volume: the
-- page 510-560 ms against 500 (report core), the deals list read alone 505-550 against 300 (a list's first page); every
-- read of the deals of a period runs cma.speed_to_lead_of over it (about 380 ms of the month), so a stored take of speed
-- to lead would be the next step (the PR names it as open).
--
-- No index. No lock on a busy table: types, functions, a view and setting rows (a row lock on cma.setting) only.
-- SQLSTATEs as before; CMA04 for a group, a view, a limit or an offset outside their bounds and for a goal or stale days
-- outside theirs.

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
  if not exists (select 1 from cma.schema_migration where version = '0009zq') then
    raise exception 'addition 0009zq (234_speed_to_lead_one.sql) must run before 0009zr';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The settings
-- ---------------------------------------------------------------------------------------------
-- The two goals are text so that empty (no goal: the tile has no colour) is a value; the trigger below takes a whole
-- number from 0 to 100 or nothing. Pulse4all's values come from Martin; until then no tenant holds one
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('speed_to_lead.goal_within_target_pct', 'text', null, '',
     'The goal for the share of lead deals whose first attempt came within speed_to_lead.target_minutes business minutes, in percent (a whole number from 0 to 100), or nothing for no goal; Sales → Speed to lead colours its tile against it (addition 0009zr)'),
  ('speed_to_lead.goal_before_cutoff_pct', 'text', null, '',
     'The goal for the share of lead deals called before speed_to_lead.next_day_cutoff on the next working day, in percent (a whole number from 0 to 100), or nothing for no goal; Sales → Speed to lead colours its tile against it (addition 0009zr)'),
  ('speed_to_lead.stale_business_days', 'integer', null, '2',
     'A lead deal not called yet is stale on Sales → Speed to lead once it has waited more than this many working days of its market since its creation (a whole number from 1 to 30; addition 0009zr)')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0009zl's (224), with the rules of the three settings of Speed to lead's cockpit (0009zr); every earlier rule kept
-- word for word (113, 123 and 137 read their text)
-- based on: 224_subscription_rates_start.sql
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
  -- Speed to lead's cockpit (0009zr): the two goals, a whole number of percent from 0 to 100 or nothing (no goal); a
  -- not-called deal's working days before it is stale, from 1 to 30
  elsif new.key in ('speed_to_lead.goal_within_target_pct', 'speed_to_lead.goal_before_cutoff_pct') then
    new.value := btrim(new.value);
    if new.value <> '' and new.value !~ '^(100|[1-9]?[0-9])$' then
      raise exception 'Setting % takes a whole number of percent from 0 to 100, or nothing (no goal)', new.key using errcode = 'CMA04';
    end if;
  elsif new.key = 'speed_to_lead.stale_business_days'
        and (case when length(new.value) > 2 then true else new.value::integer not between 1 and 30 end) then
    raise exception 'Setting % takes a whole number of working days from 1 to 30', new.key using errcode = 'CMA04';
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;


-- ---------------------------------------------------------------------------------------------
-- 2. The row type: first_call_* go (D36), five columns appended
-- ---------------------------------------------------------------------------------------------
-- The readers' view is made from the type's columns, so it goes first and is made again below (section 7). A rerun
-- finds the new shape and changes nothing
drop view if exists cma_read.speed_to_lead;

do $$
begin
  if exists (select 1 from pg_attribute a
             where a.attrelid = (select t.typrelid from pg_type t where t.oid = to_regtype('cma.speed_to_lead_row'))
               and a.attname = 'first_call_id' and not a.attisdropped) then
    alter type cma.speed_to_lead_row
      drop attribute first_call_id,
      drop attribute first_call_source_id,
      drop attribute first_call_at,
      drop attribute first_call_linked;
  end if;
  if not exists (select 1 from pg_attribute a
                 where a.attrelid = (select t.typrelid from pg_type t where t.oid = to_regtype('cma.speed_to_lead_row'))
                   and a.attname = 'last_attempt_at' and not a.attisdropped) then
    alter type cma.speed_to_lead_row
      add attribute last_attempt_at timestamptz,
      add attribute last_call_at timestamptz,
      add attribute deal_owner_ref text,
      add attribute conversations_so_far integer,
      add attribute window_end timestamptz;
  end if;
end
$$;
comment on type cma.speed_to_lead_row is
  'One lead deal as cma.speed_to_lead_of gives it (0007d, 0009zq, 0009zr): status called, not_called_open or closed_before_first_call; the measure from the creation to the first Attempt (first_attempt_*), the Attempts so far, the last one and the Conversations among them, and the end of the Attempts'' window; the first call, the first connected call and the last call shown beside it; the agent (the first attempt''s telephony user) and the deal''s owner apart (as a person and as the CRM''s reference)';

-- ---------------------------------------------------------------------------------------------
-- 3. Speed to lead: one function, each deal's calls read once
-- ---------------------------------------------------------------------------------------------
-- As 0009zq's (234): one row per lead deal created in [p_from, p_to) (null: unbounded), the same deals, the same
-- end and the same answers in every column it keeps (237 compares them with 234's definition row for row). Each deal's
-- calls are read once (cma.deal_calls_of, which cma.lead_calls_of and cma.deal_attempts_of both read from the same
-- start), where 0009zq read them twice: the first call, the first connected call and the last call come from all of
-- them; the Attempts are those cma.deal_attempts_of keeps (under attempts.source crm an outbound CRM call, else a
-- linked outbound telephony call on a counted line, up to the window's end), in its order (the start, then the CRM
-- call's id), so the first, the count, the last and the Conversations among them are its n = 1, its highest n, its
-- last and its conversation (237 compares each deal's with cma.deal_attempts_of's). The first outbound CRM call
-- (first_call_*) is gone (D36); the deal's CRM owner reference is carried for the open leads, and the window's end
-- (until: the earliest of the close, the contacts' first order and now, as cma.sales_deals_of's window_end) for the
-- deals list, which reads the attempts of its page's deals from cma.deal_attempts_of with it (0009zr)
-- based on: 234_speed_to_lead_one.sql
create or replace function cma.speed_to_lead_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns setof cma.speed_to_lead_row
language sql stable
as $$
  -- materialized, so the settings are read once per call (folded into the query, once per deal)
  with s as materialized (
    select greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min,
           cma.setting_of(p_tenant_id, 'speed_to_lead.target_minutes')::integer * 60 as target_s,
           cma.setting_of(p_tenant_id, 'speed_to_lead.next_day_cutoff')::time as cutoff,
           cma.setting_of(p_tenant_id, 'attempts.source') as source
  ),
  -- each market's zone, office hours and holidays read once per call, not per deal
  cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id)
  ),
  -- the window's end of each sales deal as Attempts per deal reads it (cma.sales_deals_of: the earliest of the close,
  -- the first order of the deal's contacts and now), so both give the same answer for every deal (Martin, 24 Nov 2026)
  w as materialized (
    select sd.deal_id, sd.window_end, sd.window_end_reason
    from cma.sales_deals_of(p_tenant_id, p_from, p_to, now()) sd
  ),
  d as materialized (
    -- the attempts' source and the cutoff as columns: a function argument holding a subquery stops the planner from
    -- inlining cma.deal_calls_of, which then runs once per deal on its own plan. A lead deal outside the sales deals
    -- (a pipeline that is both a lead and an order pipeline) ends at its close, else now
    select ld.*, ld.created_at - make_interval(mins => s.pre_min) as not_before,
           coalesce(w.window_end, case when ld.is_closed then coalesce(cr.closed_at, now()) else now() end) as until,
           coalesce(w.window_end_reason = 'ordered', false) as ordered,
           s.source as attempts_source, s.cutoff
    from cma.lead_deals_of(p_tenant_id, p_from, p_to) ld
    cross join s
    left join w on w.deal_id = ld.deal_id
    left join cma.crm_record cr on cr.tenant_id = p_tenant_id and cr.id = ld.deal_id
  ),
  -- every call of each deal from the window's start, read once, each marked an Attempt as cma.deal_attempts_of marks
  -- it (its is_attempt and its window's end, p_until)
  c as materialized (
    select d.deal_id, x.call_id, x.direction, x.effective_at, x.is_connected,
           x.telephony_source_system, x.telephony_user_ref,
           x.effective_at <= d.until
             and case when d.attempts_source = 'crm' then x.direction = 'outbound'
                      else x.is_linked and x.telephony_direction = 'outbound' and x.line_counted end as is_attempt,
           x.is_conversation
    from d
    cross join lateral cma.deal_calls_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts, d.not_before) x
  ),
  -- per deal: the first call (and its direction), the first connected call and the last call of all of them; the
  -- first Attempt (its call, start and telephony user), how many, the last one and how many were a Conversation. Each
  -- "first" is the earliest by the start, then the CRM call's id, as 0009zq's distinct on and cma.deal_attempts_of's n
  k as (
    select c.deal_id,
           min(c.effective_at) as fa_at,
           (array_agg(c.direction order by c.effective_at, c.call_id))[1] as fa_dir,
           min(c.effective_at) filter (where c.is_connected) as fc_at,
           max(c.effective_at) as last_call_at,
           (array_agg(c.call_id order by c.effective_at, c.call_id) filter (where c.is_attempt))[1] as at_id,
           min(c.effective_at) filter (where c.is_attempt) as at_at,
           (array_agg(c.telephony_source_system order by c.effective_at, c.call_id) filter (where c.is_attempt))[1] as at_system,
           (array_agg(c.telephony_user_ref order by c.effective_at, c.call_id) filter (where c.is_attempt))[1] as at_user,
           (count(*) filter (where c.is_attempt))::integer as attempts,
           max(c.effective_at) filter (where c.is_attempt) as last_at,
           (count(*) filter (where c.is_attempt and c.is_conversation))::integer as conversations
    from c
    group by c.deal_id
  ),
  r as (
    select d.*, k.fa_at, k.fa_dir, k.fc_at, k.last_call_at, k.at_id, k.at_at, k.at_system, k.at_user, k.last_at,
           coalesce(k.attempts, 0) as attempts, coalesce(k.conversations, 0) as conversations,
           (select s.target_s from s) as target_s,
           nn.noon,
           bc.time_zone as cal_zone, bc.weekdays as cal_weekdays, bc.opens as cal_opens, bc.closes as cal_closes, bc.holidays as cal_holidays
    from d
    left join cal bc on bc.market = nullif(d.market, 'unknown')
    -- offset 0: the cutoff moment computed once per deal (pulled up, it ran once per reference), from the calendar's arrays
    left join lateral (select cma.next_business_noon_in(bc.time_zone, bc.weekdays, bc.holidays, d.created_at, d.cutoff) as noon
                       offset 0) nn on true
    left join k on k.deal_id = d.deal_id
  ),
  m as (
    select r.*, bt.bs, bt.bs_now, xa.user_id as ag_user, xo.user_id as owner_user
    from r
    -- offset 0: each deal's business seconds computed once (pulled up, they ran once per reference), from the calendar's
    -- arrays; an attempt in the pre-window is 0 (cma.business_seconds_in of an end before the start)
    left join lateral (
      select case when r.at_at is not null
                  then cma.business_seconds_in(r.cal_zone, r.cal_weekdays, r.cal_opens, r.cal_closes, r.cal_holidays, r.created_at, r.at_at) end as bs,
             case when r.at_at is null and not r.is_closed and not r.ordered
                  then cma.business_seconds_in(r.cal_zone, r.cal_weekdays, r.cal_opens, r.cal_closes, r.cal_holidays, r.created_at, now()) end as bs_now
      offset 0) bt on true
    -- the agent: the first attempt's telephony user mapped to a person (as cma.calls_people_of maps a call's user)
    left join cma.app_user_external_id xa
      on xa.tenant_id = p_tenant_id and xa.system = r.at_system || '_user' and xa.external_id = r.at_user
    -- the deal's owner mapped to a person, apart from the measure
    left join cma.app_user_external_id xo
      on xo.tenant_id = p_tenant_id and xo.system = r.source_system || '_owner' and xo.external_id = r.owner_ref
  )
  select p_tenant_id, m.deal_id, m.connection_id, m.source_id, m.pipeline_id, m.pipeline_label, m.business_date,
         m.created_at, m.market, m.market_source, m.is_closed,
         case when m.at_at is not null then 'called'
              when m.is_closed or m.ordered then 'closed_before_first_call' else 'not_called_open' end,
         m.fa_at, m.fa_dir,
         coalesce(m.fa_dir = 'inbound', false), m.fc_at,
         m.ag_user, m.at_user, case when m.at_user is not null then 'call' end,
         case when m.at_at is not null then greatest(0, floor(extract(epoch from m.at_at - m.created_at)))::integer end,
         m.bs, m.target_s,
         case when m.bs is not null then m.bs <= m.target_s
              when m.bs_now > m.target_s then false end,
         m.noon,
         case when m.at_at is not null and m.noon is not null then m.at_at < m.noon
              when m.at_at is null and not m.is_closed and not m.ordered and m.noon is not null and now() >= m.noon then false end,
         m.bs_now,
         m.at_id, m.at_at, m.attempts, m.owner_user,
         m.last_at, m.last_call_at, m.owner_ref, m.conversations, m.until
  from m
$$;

-- No setting on this function: a setting keeps the planner from inlining it, and then its body is planned with
-- parameters for its bounds (2,000 ms in place of 700 for the open leads at three times prod's volume, measured). Its
-- callers carry jit off and, the plpgsql ones, force_custom_plan instead (sections 4 to 7)

-- ---------------------------------------------------------------------------------------------
-- 4. The open leads from the one function's rows (open-decisions, B40b idea 2)
-- ---------------------------------------------------------------------------------------------
-- As 0009zq's (234): the not_called_open rows of cma.speed_to_lead_of, the same rows, columns and order (237 compares
-- them with 234's definition). The owner's CRM reference and the last call now come from the row (deal_owner_ref,
-- last_call_at: the latest call of the deal or its contacts from the window's start, as cma.lead_calls_of gave it), so
-- the deals and their calls are no longer read a second time
-- based on: 234_speed_to_lead_one.sql
create or replace function cma.open_leads_of(p_tenant_id uuid)
returns setof cma.open_lead_row
language sql stable
as $$
  -- materialized, so the setting is read once per call (folded into the query, once per lead)
  with s as materialized (
    select cma.setting_of(p_tenant_id, 'leads.age_buckets_business_days') as edges
  ),
  -- each market's zone, office hours and holidays read once per call, not per lead
  cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id)
  ),
  r as (
    select * from cma.speed_to_lead_of(p_tenant_id, null, null) x where x.status = 'not_called_open'
  )
  select p_tenant_id, r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label,
         r.deal_owner_user_id, r.deal_owner_ref, r.market, r.created_at, r.waiting_business_seconds,
         a.days, b.bucket_from, b.bucket_to,
         case when r.within_target is false then true when r.waiting_business_seconds is null then null else false end,
         r.last_call_at,
         case when r.last_call_at is not null then floor(extract(epoch from now() - r.last_call_at) / 86400)::integer end
  from r
  cross join s
  left join cal bc on bc.market = nullif(r.market, 'unknown')
  -- offset 0: the days computed once per lead (pulled up, the call ran once per reference to a.days), from the calendar's arrays
  cross join lateral (select cma.business_days_in(bc.time_zone, bc.weekdays, bc.holidays, r.created_at, now()) as days offset 0) a
  cross join lateral cma.age_bucket_of(a.days, s.edges) b
  order by r.waiting_business_seconds desc nulls last, r.created_at
$$;
-- jit off, as 0008zr's reads (132): the inlined body's estimated cost passes jit_above_cost, and compiling it cost
-- about 200 ms of each call at three times prod's volume (the follow-up job's call, with ordinality: 1,130 ms before
-- this script, 690 ms after; 236's header)
alter function cma.open_leads_of(uuid) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 5. The parts of the cockpit, each from a set of rows already read (0009zr)
-- ---------------------------------------------------------------------------------------------
-- As Attempts per deal's (cma.attempts_figures_from and the rest, 0008z): the rows of cma.speed_to_lead_of are read
-- once into an array, and each part is computed from it, so the page reads the deals and their calls once for all its
-- parts (cma.speed_to_lead_page, section 7), and the summary, the figures and the deals list, each read alone by the
-- API, give the same answers from the same functions

-- The two row types of the cockpit's parts (the _from functions and the reads share them); a rerun keeps them
do $$
begin
  if to_regtype('cma.speed_to_lead_figures_row') is null then
    create type cma.speed_to_lead_figures_row as (
  period_from                           date,
  period_to                             date,
  previous_from                         date,
  previous_to                           date,
  previous_until                        timestamptz,
  target_minutes                        integer,
  next_day_cutoff                       text,
  goal_within_target_pct                integer,
  goal_before_cutoff_pct                integer,
  stale_business_days                   integer,
  deals                                 integer,
  called                                integer,
  within_target_pct                     numeric,
  before_next_noon_pct                  numeric,
  median_business_minutes               numeric,
  open_not_called                       integer,
  oldest_waiting_business_seconds       integer,
  closed_before_first_call              integer,
  attempts_mean                         numeric,
  attempts_median                       numeric,
  conversation_share                    numeric,
  prev_deals                            integer,
  prev_called                           integer,
  prev_within_target_pct                numeric,
  prev_before_next_noon_pct             numeric,
  prev_median_business_minutes          numeric,
  prev_open_not_called                  integer,
  prev_oldest_waiting_business_seconds  integer,
  prev_closed_before_first_call         integer,
  prev_attempts_mean                    numeric,
  prev_attempts_median                  numeric,
  prev_conversation_share               numeric
    );
  end if;
  if to_regtype('cma.speed_to_lead_deal_row') is null then
    create type cma.speed_to_lead_deal_row as (
  deal_id                   uuid,
  connection_id             uuid,
  deal_source_id            text,
  market                    text,
  pipeline_id               text,
  pipeline_label            text,
  created_at                timestamptz,
  status                    text,
  business_seconds          integer,
  within_target             boolean,
  before_next_noon          boolean,
  cutoff_at                 timestamptz,
  owner_user_id             uuid,
  owner_name                text,
  attempts_so_far           integer,
  attempts                  jsonb,
  stale                     boolean,
  cutoff_business_seconds   integer,
  span_business_seconds     integer,
  view_total                integer
    );
  end if;
end
$$;
comment on type cma.speed_to_lead_figures_row is
  'Speed to lead''s figures of a period and of the previous one (0009zr): the periods, the settings shown with them (target, cutoff, the two goals, stale days) and per period the deals, called, the two shares, the median, the open deals not called and the longest wait, closed before the first call, the Attempts per deal and the share with a Conversation';
comment on type cma.speed_to_lead_deal_row is
  'One lead deal of Speed to lead''s deals list (0009zr): ids, market, pipeline, creation, status, the measure, the cutoff, the owner as a person, the Attempts so far and the first 20 of them (jsonb: start, business seconds, connected, talk seconds, conversation, tag meaning keys, agent), stale, the timeline''s scales (the cutoff and 1.5 working days in business seconds), and the view''s count';

-- The groups of the rows created on business dates [p_from, p_to], narrowed to p_market when given: by day (business
-- date), week (the Monday of its ISO week; business dates are the tenant's zone), market, agent (the first attempt's
-- person; a telephony user without a person under 'unknown', a deal without an attempt under 'no_attempt'), pipeline,
-- or 'total' (always one row). 0009zq's columns as before, and at the end the Attempts per deal as attempts.per_deal
-- counts them (the mean to two places and the median to one, over every deal, one without an attempt counting 0) and
-- the share of deals with a Conversation among their Attempts (in percent to one place, as the other shares). In
-- 'no_attempt' the shares and the medians of the measure are null: its deals have no attempt, so no measure (shown as –)
create or replace function cma.speed_to_lead_groups_from(p_rows cma.speed_to_lead_row[], p_from date, p_to date, p_group text,
                                                        p_market text)
returns table (
  group_key                 text,
  group_label               text,
  deals                     integer,
  called                    integer,
  median_business_minutes   numeric,
  p80_business_minutes      numeric,
  within_target_pct         numeric,
  before_next_noon_pct      numeric,
  open_not_called           integer,
  closed_before_first_call  integer,
  attempts_mean             numeric,
  attempts_median           numeric,
  conversation_share        numeric
)
language sql stable
as $$
  with r as (
    select x.*
    from unnest(p_rows) x
    where x.business_date between p_from and p_to
      and (p_market is null or x.market = p_market)
  ),
  g as (
    select g.k, g.l, count(*)::integer as deals, (count(*) filter (where r.status = 'called'))::integer as called,
           case when g.k <> 'no_attempt' then round((percentile_cont(0.5) within group (order by r.business_seconds))::numeric / 60, 1) end as med,
           case when g.k <> 'no_attempt' then round((percentile_cont(0.8) within group (order by r.business_seconds))::numeric / 60, 1) end as p80,
           case when g.k <> 'no_attempt' then round(100.0 * count(*) filter (where r.within_target) / nullif(count(r.within_target), 0), 1) end as wt,
           case when g.k <> 'no_attempt' then round(100.0 * count(*) filter (where r.before_next_noon) / nullif(count(r.before_next_noon), 0), 1) end as bn,
           (count(*) filter (where r.status = 'not_called_open'))::integer as open_nc,
           (count(*) filter (where r.status = 'closed_before_first_call'))::integer as closed_bf,
           round(avg(r.attempts_so_far), 2) as am,
           round((percentile_cont(0.5) within group (order by r.attempts_so_far))::numeric, 1) as amed,
           case when g.k <> 'no_attempt' then round(100.0 * count(*) filter (where r.conversations_so_far > 0) / nullif(count(*), 0), 1) end as conv
    from r
    left join cma.app_user u on u.tenant_id = r.tenant_id and u.id = r.agent_user_id and p_group = 'agent'
    cross join lateral (
      select case p_group when 'total' then 'total'
                          when 'day' then r.business_date::text
                          when 'week' then date_trunc('week', r.business_date)::date::text
                          when 'market' then r.market
                          when 'agent' then case when r.first_attempt_at is null then 'no_attempt'
                                                 else coalesce(r.agent_user_id::text, 'unknown') end
                          else r.connection_id::text || ':' || coalesce(r.pipeline_id, '') end as k,
             case p_group when 'total' then null
                          when 'day' then r.business_date::text
                          when 'week' then date_trunc('week', r.business_date)::date::text
                          when 'market' then r.market
                          when 'agent' then case when r.first_attempt_at is null then null
                                                 else coalesce(u.display_name, 'unknown') end
                          else coalesce(r.pipeline_label, 'unknown') end as l) g
    group by g.k, g.l
  )
  select g.k, g.l, g.deals, g.called, g.med, g.p80, g.wt, g.bn, g.open_nc, g.closed_bf, g.am, g.amed, g.conv from g
  -- the total is one row also when there is no deal
  union all
  select 'total', null, 0, 0, null, null, null, null, 0, 0, null, null, null
  where p_group = 'total' and not exists (select 1 from g)
  order by 1
$$;

-- The figures of the period [p_from, p_to] and the previous one (p_prev_from to p_prev_to, cut on its last date at
-- p_until's time of day in p_zone when p_until is given: cma.forms_previous_of's like for like), narrowed to p_market
-- when given. Per period: deals, called, the two shares and the median (as cma.speed_to_lead_groups_from's total: 237
-- compares them), the open deals not called yet and the longest any of them has waited in business seconds, the deals
-- closed before their first call, the Attempts per deal and the share with a Conversation. With the settings the page
-- shows them against: the target, the cutoff, the two goals (null without one) and the working days after which a deal
-- not called is stale
create or replace function cma.speed_to_lead_figures_from(p_tenant_id uuid, p_rows cma.speed_to_lead_row[], p_from date, p_to date,
                                                         p_prev_from date, p_prev_to date, p_until timestamptz, p_zone text,
                                                         p_market text)
returns setof cma.speed_to_lead_figures_row
language sql stable
as $$
  with r as (
    select x.*,
           case when x.business_date between p_from and p_to then 'current'
                when x.business_date between p_prev_from and p_prev_to
                     and (p_until is null or x.business_date < p_prev_to
                          or (x.created_at at time zone p_zone)::time <= (p_until at time zone p_zone)::time) then 'previous'
           end as part
    from unnest(p_rows) x
    where p_market is null or x.market = p_market
  ),
  f as (
    select r.part, count(*)::integer as deals, (count(*) filter (where r.status = 'called'))::integer as called,
           round(100.0 * count(*) filter (where r.within_target) / nullif(count(r.within_target), 0), 1) as wt,
           round(100.0 * count(*) filter (where r.before_next_noon) / nullif(count(r.before_next_noon), 0), 1) as bn,
           round((percentile_cont(0.5) within group (order by r.business_seconds))::numeric / 60, 1) as med,
           (count(*) filter (where r.status = 'not_called_open'))::integer as open_nc,
           max(r.waiting_business_seconds) filter (where r.status = 'not_called_open') as oldest,
           (count(*) filter (where r.status = 'closed_before_first_call'))::integer as closed_bf,
           round(avg(r.attempts_so_far), 2) as am,
           round((percentile_cont(0.5) within group (order by r.attempts_so_far))::numeric, 1) as amed,
           round(100.0 * count(*) filter (where r.conversations_so_far > 0) / nullif(count(*), 0), 1) as conv
    from r
    where r.part is not null
    group by r.part
  ),
  st as (
    select cma.setting_of(p_tenant_id, 'speed_to_lead.target_minutes')::integer as target_minutes,
           cma.setting_of(p_tenant_id, 'speed_to_lead.next_day_cutoff') as cutoff,
           nullif(cma.setting_of(p_tenant_id, 'speed_to_lead.goal_within_target_pct'), '')::integer as goal_wt,
           nullif(cma.setting_of(p_tenant_id, 'speed_to_lead.goal_before_cutoff_pct'), '')::integer as goal_bc,
           cma.setting_of(p_tenant_id, 'speed_to_lead.stale_business_days')::integer as stale_days
  )
  select p_from, p_to, p_prev_from, p_prev_to, p_until,
         st.target_minutes, st.cutoff, st.goal_wt, st.goal_bc, st.stale_days,
         coalesce(c.deals, 0), coalesce(c.called, 0), c.wt, c.bn, c.med, coalesce(c.open_nc, 0), c.oldest,
         coalesce(c.closed_bf, 0), c.am, c.amed, c.conv,
         coalesce(p.deals, 0), coalesce(p.called, 0), p.wt, p.bn, p.med, coalesce(p.open_nc, 0), p.oldest,
         coalesce(p.closed_bf, 0), p.am, p.amed, p.conv
  from st
  left join f c on c.part = 'current'
  left join f p on p.part = 'previous'
$$;

-- The lead deals of the rows created on business dates [p_from, p_to], narrowed to p_market when given, in one view:
-- 'not_called' (not_called_open) or 'called', newest created first (then the deal's id), p_limit from p_offset;
-- view_total counts the view's deals. Per deal from its row: its ids for the record link, market, pipeline, creation,
-- status, the business seconds (to the first attempt; for a deal not called, waited so far), within target, before the
-- cutoff and the cutoff's moment (next_business_noon, which follows speed_to_lead.next_day_cutoff since 0009zq), the
-- owner as a person (the deal's CRM owner mapped through <crm>_owner; none without a mapping), the Attempts so far;
-- stale when a deal not called has waited more than speed_to_lead.stale_business_days working days of its market since
-- its creation (cma.business_days_in on the market's calendar; never in an unknown market, which has none). And its
-- Attempts as cma.deal_attempts_of gives them for the deal's window (from the creation less the pre-window to the row's
-- window_end, under attempts.source; the contacts as cma.counted_deals_of gives them), the first 20 by number with the
-- true count beside them (attempts_so_far): the start, the business seconds after the creation, connected, the talk
-- seconds, whether a Conversation, the meaning keys of the linked telephony call's current tags (never a tag's text)
-- and the agent (the call's telephony user mapped to a person, with the person's name). Ids, times, codes and people's
-- names only: no phone number, recording, customer name or email
create or replace function cma.speed_to_lead_deals_from(p_tenant_id uuid, p_rows cma.speed_to_lead_row[], p_from date, p_to date,
                                                       p_market text, p_view text, p_limit integer, p_offset integer)
returns setof cma.speed_to_lead_deal_row
language sql stable
as $$
  with s as materialized (
    select greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min,
           cma.setting_of(p_tenant_id, 'attempts.source') as source,
           cma.setting_of(p_tenant_id, 'speed_to_lead.stale_business_days')::integer as stale_days
  ),
  cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id)
  ),
  -- the view's deals, newest first; the page of them, with the view's count
  v as materialized (
    select x.*, count(*) over ()::integer as total
    from unnest(p_rows) x
    where x.business_date between p_from and p_to
      and (p_market is null or x.market = p_market)
      and x.status = case p_view when 'not_called' then 'not_called_open' else 'called' end
    order by x.created_at desc, x.deal_id
    limit p_limit offset p_offset
  ),
  -- each page deal's Attempts, the first 20 by number, with what the list shows of each
  at as (
    select v.deal_id,
           jsonb_agg(jsonb_build_object(
             'n', z.n,
             'started_at', z.effective_at,
             'business_seconds', cma.business_seconds_in(bc.time_zone, bc.weekdays, bc.opens, bc.closes, bc.holidays, v.created_at, z.effective_at),
             'connected', z.connected,
             'talk_seconds', z.talk_seconds,
             'conversation', z.conversation,
             'tag_meanings', coalesce((
               select jsonb_agg(distinct tg.meaning order by tg.meaning)
               from cma.call_link l
               join cma.telephony_call tc on tc.tenant_id = l.tenant_id and tc.id = l.telephony_call_id and tc.source_deleted_at is null
               join cma.telephony_call_tag ct
                 on ct.tenant_id = tc.tenant_id and ct.connection_id = tc.connection_id and ct.call_source_id = tc.source_id
                and ct.untagged_at is null
               join cma.telephony_tag tg
                 on tg.tenant_id = ct.tenant_id and tg.connection_id = ct.connection_id and tg.tag_ref = ct.tag_ref
               where l.tenant_id = p_tenant_id and l.crm_call_id = z.call_id and l.unlinked_at is null and tg.meaning is not null), '[]'::jsonb),
             'agent_user_id', xa.user_id,
             'agent_name', ua.display_name) order by z.n) as attempts
    from v
    join cma.crm_record cr on cr.tenant_id = p_tenant_id and cr.id = v.deal_id
    -- the deal's contacts as cma.counted_deals_of gives them (the record's own contact and its associated ones), a
    -- lateral of the deal itself: a join of its own (a CTE over the page) ran the attempts once per pair of page deals
    cross join lateral (
      select array(select y from (select cr.contact_source_id as y where cr.contact_source_id is not null
                                  union
                                  select a.to_id from cma.crm_association a
                                  where a.tenant_id = cr.tenant_id and a.connection_id = cr.connection_id
                                    and a.from_type = cr.record_type and a.from_id = cr.source_id
                                    and a.to_type = 'contact' and a.removed_at is null) q
                   order by y) as contacts) dk
    cross join s
    left join cal bc on bc.market = nullif(v.market, 'unknown')
    cross join lateral cma.deal_attempts_of(p_tenant_id, v.connection_id, cr.record_type, v.deal_source_id, dk.contacts,
                                            v.created_at - make_interval(mins => s.pre_min), v.window_end, s.source) z
    left join cma.app_user_external_id xa
      on xa.tenant_id = p_tenant_id and xa.system = z.telephony_source_system || '_user' and xa.external_id = z.telephony_user_ref
    left join cma.app_user ua on ua.tenant_id = p_tenant_id and ua.id = xa.user_id
    where z.is_attempt and z.n <= 20
    group by v.deal_id
  )
  select v.deal_id, v.connection_id, v.deal_source_id, v.market, v.pipeline_id, v.pipeline_label, v.created_at, v.status,
         coalesce(v.business_seconds, v.waiting_business_seconds), v.within_target, v.before_next_noon, v.next_business_noon,
         v.deal_owner_user_id, uo.display_name, v.attempts_so_far, coalesce(at.attempts, '[]'::jsonb),
         coalesce(v.status = 'not_called_open'
                  and cma.business_days_in(bc.time_zone, bc.weekdays, bc.holidays, v.created_at, now()) > (select s.stale_days from s), false),
         -- the timeline's two scales: the cutoff in business seconds after the creation, and 1.5 working days of the market
         -- (its mean office day over the weekdays it works); null in an unknown market
         cma.business_seconds_in(bc.time_zone, bc.weekdays, bc.opens, bc.closes, bc.holidays, v.created_at, v.next_business_noon),
         (select round(1.5 * avg(extract(epoch from u.c - u.o)))::integer from unnest(bc.opens, bc.closes) u(o, c)),
         v.total
  from v
  left join at on at.deal_id = v.deal_id
  left join cal bc on bc.market = nullif(v.market, 'unknown')
  left join cma.app_user uo on uo.tenant_id = p_tenant_id and uo.id = v.deal_owner_user_id
  order by v.created_at desc, v.deal_id
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The reads: the summary, the figures and the deals list (the API), each from one read of the rows
-- ---------------------------------------------------------------------------------------------
-- Each checks the permission (reports.view or performance.team) and the period (cma.report_range: at most 92 days), reads
-- cma.speed_to_lead_of once into an array and returns its part. jit off: the inlined body's estimated cost passes
-- jit_above_cost, and compiling it cost about 130 ms of each call at three times prod's volume (236's header);
-- force_custom_plan: a plpgsql statement turns to the generic plan after five calls on a connection, and the generic
-- plan of the inlined body took twice the time or more (the sixth call of the deals list: 420 → 1,090 ms at three times
-- prod's volume), as cma.courtesy_page_of (150) and cma.refresh_follow_up() (178)

-- The return type gains three columns at its end, so the function is dropped and made again (its grants below)
drop function if exists cma.speed_to_lead_summary(date, date, text, text);

-- As 0009zq's (234), from cma.speed_to_lead_groups_from: groups day, week, market, agent, pipeline or total (one row)
-- based on: 234_speed_to_lead_one.sql
create or replace function cma.speed_to_lead_summary(p_from date, p_to date, p_group text, p_market text default null)
returns table (
  group_key                 text,
  group_label               text,
  deals                     integer,
  called                    integer,
  median_business_minutes   numeric,
  p80_business_minutes      numeric,
  within_target_pct         numeric,
  before_next_noon_pct      numeric,
  open_not_called           integer,
  closed_before_first_call  integer,
  attempts_mean             numeric,
  attempts_median           numeric,
  conversation_share        numeric
)
language plpgsql stable
set jit = off
set plan_cache_mode = force_custom_plan
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_range  record;
  v_rows   cma.speed_to_lead_row[];
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'week', 'market', 'agent', 'pipeline', 'total') then
    raise exception 'group by day, week, market, agent, pipeline or total, not %', p_group using errcode = 'CMA04';
  end if;
  select * into v_range from cma.report_range(v_tenant, p_from, p_to);
  select coalesce(array_agg(x), '{}') into v_rows from cma.speed_to_lead_of(v_tenant, v_range.from_at, v_range.to_at) x;
  return query select * from cma.speed_to_lead_groups_from(v_rows, p_from, p_to, p_group, p_market);
end
$$;

-- The deals list's view and page bounds: a view 'not_called' or 'called', a limit from 1 to 200, an offset of 0 or more
create or replace function cma.speed_to_lead_view_check(p_view text, p_limit integer, p_offset integer)
returns void
language plpgsql immutable
as $$
begin
  if p_view is null or p_view not in ('not_called', 'called') then
    raise exception 'view not_called or called, not %', coalesce(p_view, 'none') using errcode = 'CMA04';
  end if;
  if p_limit is null or p_limit not between 1 and 200 or p_offset is null or p_offset < 0 then
    raise exception 'limit from 1 to 200 and offset 0 or more' using errcode = 'CMA04';
  end if;
end
$$;

-- The figures of [p_from, p_to] and of the previous period of the same length, the rule Attempts per deal uses
-- (cma.forms_previous_of: it ends the day before the period; while the period reaches today it is cut on its last date
-- at now's time of day in the tenant's zone), narrowed to p_market when given: one read over both periods
create or replace function cma.speed_to_lead_figures(p_from date, p_to date, p_market text default null)
returns setof cma.speed_to_lead_figures_row
language plpgsql stable
set jit = off
set plan_cache_mode = force_custom_plan
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_range  record;
  v_prev   record;
  v_zone   text;
  v_rows   cma.speed_to_lead_row[];
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  select * into v_range from cma.report_range(v_tenant, p_from, p_to);
  select * into v_prev from cma.forms_previous_of(v_tenant, p_from, p_to, now());
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;
  select coalesce(array_agg(x), '{}') into v_rows
  from cma.speed_to_lead_of(v_tenant, v_prev.prev_from::timestamp at time zone v_zone, v_range.to_at) x;
  return query select * from cma.speed_to_lead_figures_from(v_tenant, v_rows, p_from, p_to, v_prev.prev_from, v_prev.prev_to,
                                                            v_prev.until, v_zone, p_market);
end
$$;

-- The deals list: one view ('not_called' or 'called') of the period's deals, p_limit (1 to 200) from p_offset (0 or more)
create or replace function cma.speed_to_lead_deals_of(p_from date, p_to date, p_market text, p_view text,
                                                     p_limit integer default 50, p_offset integer default 0)
returns setof cma.speed_to_lead_deal_row
language plpgsql stable
set jit = off
set plan_cache_mode = force_custom_plan
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_range  record;
  v_rows   cma.speed_to_lead_row[];
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.speed_to_lead_view_check(p_view, p_limit, p_offset);
  select * into v_range from cma.report_range(v_tenant, p_from, p_to);
  select coalesce(array_agg(x), '{}') into v_rows from cma.speed_to_lead_of(v_tenant, v_range.from_at, v_range.to_at) x;
  return query select * from cma.speed_to_lead_deals_from(v_tenant, v_rows, p_from, p_to, p_market, p_view, p_limit, p_offset);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. The page: every part from one read
-- ---------------------------------------------------------------------------------------------
-- Sales → Speed to lead's page in one read (cma.speed_to_lead_of once, over the period and the previous one): the
-- figures (narrowed to p_market), the markets (every market of the period, never narrowed: the page's market filter
-- and its per-market card), the trend (per day, per week over 31 days; narrowed) with its grouping, the Group by
-- table's groups (p_group; narrowed) and a page of the deals list (p_view, p_limit from p_offset; narrowed). The parts
-- are the same functions' as the summary's, the figures' and the deals list's, so the page and the API agree (237).
-- One jsonb object: figures (an object), markets, trend, groups and deals (arrays of rows), trend_group
create or replace function cma.speed_to_lead_page(p_from date, p_to date, p_market text, p_group text, p_view text,
                                                 p_limit integer default 50, p_offset integer default 0)
returns jsonb
language plpgsql stable
set jit = off
set plan_cache_mode = force_custom_plan
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_range  record;
  v_prev   record;
  v_zone   text;
  v_rows   cma.speed_to_lead_row[];
  v_trend  text := case when p_to - p_from + 1 > 31 then 'week' else 'day' end;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'week', 'market', 'agent', 'pipeline') then
    raise exception 'group by day, week, market, agent or pipeline, not %', p_group using errcode = 'CMA04';
  end if;
  perform cma.speed_to_lead_view_check(p_view, p_limit, p_offset);
  select * into v_range from cma.report_range(v_tenant, p_from, p_to);
  select * into v_prev from cma.forms_previous_of(v_tenant, p_from, p_to, now());
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;
  select coalesce(array_agg(x), '{}') into v_rows
  from cma.speed_to_lead_of(v_tenant, v_prev.prev_from::timestamp at time zone v_zone, v_range.to_at) x;
  return jsonb_build_object(
    'figures', (select to_jsonb(f) from cma.speed_to_lead_figures_from(v_tenant, v_rows, p_from, p_to, v_prev.prev_from,
                                                                       v_prev.prev_to, v_prev.until, v_zone, p_market) f),
    'markets', (select coalesce(jsonb_agg(to_jsonb(g) order by g.group_key), '[]'::jsonb)
                from cma.speed_to_lead_groups_from(v_rows, p_from, p_to, 'market', null) g),
    'trend_group', v_trend,
    'trend', (select coalesce(jsonb_agg(to_jsonb(g) order by g.group_key), '[]'::jsonb)
              from cma.speed_to_lead_groups_from(v_rows, p_from, p_to, v_trend, p_market) g),
    'groups', (select coalesce(jsonb_agg(to_jsonb(g) order by g.group_key), '[]'::jsonb)
               from cma.speed_to_lead_groups_from(v_rows, p_from, p_to, p_group, p_market) g),
    'deals', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc, d.deal_id), '[]'::jsonb)
              from cma.speed_to_lead_deals_from(v_tenant, v_rows, p_from, p_to, p_market, p_view, p_limit, p_offset) d));
end
$$;

-- The page's rows (0007d's, unchanged): the same two settings. jit off: the inlined body's cost passes jit_above_cost
-- (about 130 ms of compiling per call); force_custom_plan: a plpgsql statement turns to the generic plan after five
-- calls on a connection, and the generic plan of the inlined body took twice the time (the 6th call: 420 → 1,090 ms
-- for the deals list at three times prod's volume), as cma.courtesy_page_of (150) and cma.refresh_follow_up() (178)
alter function cma.speed_to_lead_rows(date, date) set jit = off;
alter function cma.speed_to_lead_rows(date, date) set plan_cache_mode = force_custom_plan;

-- ---------------------------------------------------------------------------------------------
-- 8. The readers' view, made again from the type's columns
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.speed_to_lead as
  select * from cma_read.speed_to_lead_rows();
-- the readers' grant stated, as 232's, not left to cma_read's default privileges (237 W1 checks it)
grant select on cma_read.speed_to_lead to cma_readonly;

-- ---------------------------------------------------------------------------------------------
-- 9. Grants: the application only, as 0009zq's (234); the view as 0007d's (40)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.speed_to_lead_summary(date,date,text,text)',
    'cma.speed_to_lead_figures(date,date,text)',
    'cma.speed_to_lead_deals_of(date,date,text,text,integer,integer)',
    'cma.speed_to_lead_page(date,date,text,text,text,integer,integer)',
    'cma.speed_to_lead_view_check(text,integer,integer)',
    'cma.speed_to_lead_groups_from(cma.speed_to_lead_row[],date,date,text,text)',
    'cma.speed_to_lead_figures_from(uuid,cma.speed_to_lead_row[],date,date,date,date,timestamptz,text,text)',
    'cma.speed_to_lead_deals_from(uuid,cma.speed_to_lead_row[],date,date,text,text,integer,integer)',
    'cma.speed_to_lead_of(uuid,timestamptz,timestamptz)',
    'cma.open_leads_of(uuid)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zr', 'Speed to lead as a cockpit (Martin, 24 Nov 2026; brief B40b; D36): cma.speed_to_lead_row loses first_call_* and gains last_attempt_at, last_call_at, deal_owner_ref, conversations_so_far and window_end; cma.speed_to_lead_of reads each deal''s calls once (jit off); cma.open_leads_of reads the owner reference and the last call from its rows; cma.speed_to_lead_summary gains attempts_mean, attempts_median, conversation_share and the group week, null shares in no_attempt; new cma.speed_to_lead_figures (the period and the previous one) and cma.speed_to_lead_deals_of (a view of the deals with their attempts, stale after speed_to_lead.stale_business_days); settings speed_to_lead.goal_within_target_pct, speed_to_lead.goal_before_cutoff_pct (0 to 100 or empty) and speed_to_lead.stale_business_days (1 to 30, default 2) checked by cma.check_tenant_setting')
on conflict (version) do nothing;

commit;
reset role;
