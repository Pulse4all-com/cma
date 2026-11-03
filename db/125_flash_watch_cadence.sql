-- =============================================================================================
-- 125_flash_watch_cadence.sql: addition 0008zo, the Flash watch's stale sources measured per job and stream
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: a source's cadence is read from its own runs (jobs and streams are
-- cma.sync_run's own vocabulary) and its floor is a tenant setting. Runs unchanged in every database, after 122_flash.sql
-- (0008zn). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 123_verify_flash.sql there (its B28 is this addition's check), then prod, then 123 there. The web, the ingest and the
-- snapshot job run unchanged on it; the next take uses it.
--
-- Why (prod, 3 November 2026, the first take, run cma-snapshot-flash-rk8fh; Decision log, 3 November 2026): every
-- source_stale finding had the threshold 0. 0008zn measured a connection's cadence as the median gap between all its
-- succeeded runs, and one job execution writes one run per stream within seconds (a store's nightly reconcile of its
-- customers, orders and products), so the median gap was near zero and every source stale a minute after its last run:
-- 15 open findings in one tenant, its CRM at 1 minute and its 14 stores at 805 minutes, cadences of 0.0 to 0.1 minutes.
-- 122 ran in prod and is not edited.
--
-- What it changes
--   setting            flash.watch_stale_min_minutes (5): the floor of a cadence measured from runs, a whole number of
--                      minutes from 1 to 1440, so bursts never give a cadence under it; cma.check_tenant_setting() as
--                      0008zn's, with its check
--   flash_watch_finding the detail's allow-list gains job and stream (the run vocabulary of cma.sync_run: no id, no @)
--   cma.flash_watch_of source_stale only, per connection: the cadence of each job and stream is the median gap between its
--                      succeeded runs of the 7 days before p_now (never a gap between runs of different jobs or streams),
--                      at least flash.watch_stale_min_minutes; a connection's <job>_interval_minutes setting (a
--                      *_poll_interval_minutes) is that job's cadence instead, as before. A connection is stale only when
--                      its most frequent job and stream (the smallest cadence) last succeeded more than three of its own
--                      cadences before p_now, so a minutely sweep governs a CRM connection and a nightly reconcile alone a
--                      store that has only that. Backfills (started by hand) set no cadence. The finding's detail keeps
--                      cadence_minutes, cadence_basis (setting or runs), age_minutes, last_read_at and connections, and
--                      adds the job and stream that set the cadence. jump, flow_zero, snapshot_missing and dq_rise are
--                      0008zn's, unchanged; the function keeps its privileges (the owner's alone) and jit off
-- What it does not change
--   the findings already open: the watch resolves every open finding whose condition no longer holds, so the false
--   source_stale findings of 0008zn resolve at the next take by themselves; no row is changed here
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
  if not exists (select 1 from cma.schema_migration where version = '0008zn') then
    raise exception 'addition 0008zn (122_flash.sql) must run before 0008zo';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The setting
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('flash.watch_stale_min_minutes', 'integer', null, '5',
     'The Flash watch''s floor of a source''s cadence measured from its runs, in minutes (1 to 1440): a job and stream that runs more often counts as running every this many minutes, so a source is stale only after three of them. A connection''s poll interval setting is its job''s cadence and has no floor')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0008zn (122_flash.sql), with the watch's floor: a whole number of minutes from 1 to 1440
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
  -- the watch's floor of a cadence measured from runs (0008zo)
  elsif new.key = 'flash.watch_stale_min_minutes'
        and (case when length(new.value) > 4 then true else new.value::integer not between 1 and 1440 end) then
    raise exception 'Setting % takes a whole number of minutes from 1 to 1440', new.key using errcode = 'CMA04';
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. A finding's detail names the job and stream that set a source's cadence
-- ---------------------------------------------------------------------------------------------
alter table cma.flash_watch_finding drop constraint if exists flash_watch_finding_detail_check;
alter table cma.flash_watch_finding add constraint flash_watch_finding_detail_check
  check (cma.flash_keys_ok(detail, array['missing_from', 'missing_to', 'days', 'cadence_minutes', 'cadence_basis', 'age_minutes',
                                         'last_read_at', 'jump_pct', 'jump_min', 'previous_days', 'connections', 'job', 'stream'])) not valid;
alter table cma.flash_watch_finding validate constraint flash_watch_finding_detail_check;

-- ---------------------------------------------------------------------------------------------
-- 3. The watch: a source's cadence per job and stream
-- ---------------------------------------------------------------------------------------------
-- As 0008zn (122_flash.sql), with source_stale measured per job and stream
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
--   source_stale      an active connection of a source Flash reads whose most frequent job and stream last succeeded
--                     more than three of its own cadences before p_now (0008zo). A job and stream's cadence is the median
--                     gap between its succeeded runs of the 7 days before p_now, never a gap between runs of different
--                     jobs or streams (one execution writes one run per stream within seconds), at least
--                     flash.watch_stale_min_minutes; a connection's <job>_interval_minutes setting (a setting named
--                     *_poll_interval_minutes) is that job's cadence instead, its age from the job's last succeeded run
--                     of any time. Backfills (started by hand) set no cadence. The most frequent is the smallest
--                     cadence (a minutely sweep governs a CRM connection, a nightly reconcile alone a store that has only
--                     that); none: no finding. One finding per source, adapter and store: two stale connections alike
--                     are one finding with the oldest read, and how many they are (detail connections); the detail
--                     names the job and stream that set the cadence
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
      and e.key like '%\_poll\_interval\_minutes' and (e.value #>> '{}') ~ '^[0-9]{1,5}$' and (e.value #>> '{}')::numeric > 0
    group by 1, 2
  ), cand as (
    -- every job and stream with a cadence: its setting (its age from its last succeeded run of any time, backfills aside),
    -- else the median gap of its runs of the 7 days, at least flash.watch_stale_min_minutes
    select s.connection_id, x.job, x.stream, max(x.finished_at) as last_at, s.minutes as cadence, 'setting'::text as basis
    from sets s
    join cma.sync_run x on x.tenant_id = p_tenant_id and x.connection_id = s.connection_id and x.job = s.job
                       and x.status = 'succeeded' and x.finished_at <= p_now
    group by s.connection_id, x.job, x.stream, s.minutes
    union all
    select w.connection_id, w.job, w.stream, max(w.finished_at),
           greatest((percentile_cont(0.5) within group (order by w.gap) filter (where w.gap > 0))::numeric, v_floor), 'runs'
    from win w
    where not exists (select 1 from sets s where s.connection_id = w.connection_id and s.job = w.job)
    group by w.connection_id, w.job, w.stream
    having count(*) filter (where w.gap > 0) > 0
  ), gov as (
    -- a connection's most frequent job and stream: the smallest cadence (on a tie the latest read, then the names)
    select distinct on (k.connection_id) k.connection_id, k.job, k.stream, k.last_at, k.cadence, k.basis, c.kind, c.adapter, c.store
    from cand k
    join c on c.id = k.connection_id
    order by k.connection_id, k.cadence, k.last_at desc, k.job collate "C", k.stream collate "C" nulls first
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
                       round(extract(epoch from p_now - g.last_at) / 60) as value, round(3 * g.cadence) as threshold,
                       jsonb_build_object('cadence_minutes', round(g.cadence, 1), 'cadence_basis', g.basis,
                                          'age_minutes', round(extract(epoch from p_now - g.last_at) / 60), 'last_read_at', g.last_at)
                       || jsonb_strip_nulls(jsonb_build_object('job', g.job, 'stream', g.stream)) as detail,
                       g.last_at
                from gov g
                where extract(epoch from p_now - g.last_at) / 60 > 3 * g.cadence) st
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

-- The owner's alone, as 0008zn's (a replaced function keeps its privileges, not its settings): jit off again
revoke execute on function cma.flash_watch_of(uuid, date, timestamptz) from public, cma_app;
alter function cma.flash_watch_of(uuid, date, timestamptz) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 4. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zo', 'Flash watch cadence: source_stale measures a cadence per job and stream (the median gap between succeeded runs of the same job and stream in the 7 days before the take, backfills aside), at least flash.watch_stale_min_minutes (5), a connection''s poll interval setting its job''s cadence; a connection is stale only when its most frequent job and stream last succeeded more than three of its cadences before; the finding names that job and stream')
on conflict (version) do nothing;

commit;
reset role;
