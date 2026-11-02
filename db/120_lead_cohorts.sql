-- =============================================================================================
-- 120_lead_cohorts.sql: addition 0008zm, lead cohorts: the lead deals by the ISO week or month of their creation, followed
-- at fixed ages
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 118_subscriptions.sql
-- (0008zl). Rerunnable, forward-only, in one transaction. Run as your own IAM login: dev first, then
-- 121_verify_lead_cohorts.sql (dev only), normal and provoked, then 113_verify_assets.sql, 95_verify_attempts_for_sales.sql
-- and 41_verify_lead_metrics.sql again (dev; cma.check_tenant_setting() is made again here, and 41 sets
-- lead_to_order.max_days); then prod, before the web that reads cma.lead_cohorts_report is merged. The web and the ingest of
-- main read nothing this adds, so both run on the migrated database unchanged.
--
-- Why (Decision log, 30 October 2026; KPIs 1 and 12): period reports hide how a week's or a month's leads fare over time.
-- A lead cohort is every lead deal created in one ISO week or one month; the report follows each cohort at the ages of
-- cohorts.lead_ages_days and shows, per age, the share attempted, with a conversation, ordered and lost. Computed in
-- Postgres from functions that exist, like every report; no new source data and no ingest change. BigQuery takes it
-- over once NetSuite and the asset register join (Decision log, 30 October 2026).
--
-- What it adds
--   setting            cohorts.lead_ages_days ('1,7,30,60,90'): one to six increasing whole numbers of days, the largest at
--                      most lead_to_order.max_days (CMA04 otherwise); lead_to_order.max_days is refused below the largest
--                      age (cma.check_tenant_setting() as 0008zi with both)
--   the deals          cma.lead_cohort_deal and cma.lead_cohorts_of(tenant, from, to, now): one row per lead deal created in
--                      [from, to) (null: unbounded) with its period keys (business date, ISO week start, month start), its
--                      age as of now and its facts, each read from the function that owns it (below)
--   the report         cma.lead_cohorts_report(from, to, period, market, source channel, split, pipeline) (reports.view or
--                      performance.team, at most 92 days): per cohort newest first (and per market or source channel with a
--                      split) the created deals, per age the deals attempted, with a conversation, ordered and lost (null
--                      at an age the cohort has not reached), the median days to order, the deals not called yet now, and
--                      the filter lists; counts only, no deal list
--   reporting view     cma_read.lead_cohorts over cma_read.lead_cohort_rows(): the deals' rows for every tenant the reader
--                      sees (ids, codes, dates and times), so BigQuery can cut cohorts its own way
--
-- Definitions (docs/definitions.md, Cohort terms). 0007d's, 0008z's, 0008zb's and 0008zc's are reused, never copied:
--   population         a lead deal: cma.lead_deals_of (a counted lead pipeline, not deleted, created on or after
--                      intake.start_date); the creation's business date in the tenant's zone places it in its ISO week
--                      (Monday) and month. Deals carry no creation source and no test flag yet, so a cohort holds deals
--                      created by hand and test deals (docs/open-decisions.md)
--   cohort age         n days after the creation: created_at + n days, as lead_to_order.max_days counts its days. A cohort
--                      has reached (is mature at) age n once every deal in it is n days old; before that its figures at n
--                      are null
--   attempted          the deal's first attempt at or before its age: Attempts per deal's attempts (cma.sales_deals_of's
--                      window and cma.deal_attempts_of under attempts.source, from the creation less
--                      speed_to_lead.pre_window_minutes), so the two pages never disagree
--   conversation       the first of those attempts that is a Conversation (0008zc), at or before the age
--   ordered            lead to order (cma.lead_to_order_of): the first store order of the deal's contacts within
--                      lead_to_order.max_days, at or before the age; not First orders' attribution. At an age above
--                      lead_to_order.max_days (possible only after a setting's reset) the ordered figure is null
--   lost               cma.sales_deals_of's outcome lost (the stage's outcome lost and no order ended the window first),
--                      closed at or before the age; a lost deal without a closing time counts at no age
--   not called yet     now: the deal is open (cma.sales_deals_of's outcome open) and has no attempt, as Attempts per
--                      deal's open deals never attempted
--   source channel     crm_record.source_channel, as the funnel reads it (0008zb)
--   A deal of a pipeline marked both lead and order is a lead deal but no sales deal (0008z): it counts as created and
--   ordered as lead to order says, never attempted, never lost, never not called yet.
--
-- Everything is SECURITY INVOKER and executable by the application only; the cma_read function of the reader view is
-- SECURITY DEFINER, owned by cma_owner, search path pinned with pg_temp last, executable by readers only. No table and no
-- index: the reads use the indexes the functions they call use.
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008zl') then
    raise exception 'addition 0008zl (118_subscriptions.sql) must run before 0008zm';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The setting and its check
-- ---------------------------------------------------------------------------------------------
-- The ages at which the report follows each cohort, in days from a deal's creation
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('cohorts.lead_ages_days', 'text', null, '1,7,30,60,90',
     'The ages in days after a lead deal''s creation at which Reports, Lead cohorts follows each cohort: one to six increasing whole numbers, comma-separated, the largest at most lead_to_order.max_days')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0008zi (112), with cohorts.lead_ages_days (spaces dropped; one to six increasing whole numbers, at most
-- lead_to_order.max_days) and lead_to_order.max_days no lower than the largest age
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
                 'cohorts.lead_ages_days') then
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
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;


-- ---------------------------------------------------------------------------------------------
-- 2. The deals of the cohorts
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if to_regtype('cma.lead_cohort_deal') is null then
    create type cma.lead_cohort_deal as (
      tenant_id              uuid,
      deal_id                uuid,
      connection_id          uuid,
      deal_source_id         text,
      pipeline_id            text,
      pipeline_label         text,
      market                 text,
      source_channel         text,
      created_at             timestamptz,
      business_date          date,
      week_start             date,
      month_start            date,
      age_days               integer,
      attempts               integer,
      first_attempt_at       timestamptz,
      first_conversation_at  timestamptz,
      outcome                text,
      lost_at                timestamptz,
      order_created_at       timestamptz,
      days_to_order          numeric,
      not_called_yet         boolean
    );
  end if;
end
$$;
comment on type cma.lead_cohort_deal is
  'One lead deal as cma.lead_cohorts_of gives it (0008zm): its period keys (the creation''s business date, the ISO week''s Monday, the month''s first day), its age in whole days as of now, its attempts and the times of its first attempt and first conversation (Attempts per deal''s; null outside the sales deals), its outcome (cma.sales_deals_of''s) and the time it was lost, its first store order within lead_to_order.max_days and the days to it (lead to order), and whether it is open and not called yet';

-- Every lead deal created in [p_from, p_to) (null: unbounded) as of p_now (now() for the application; a verifier gives a
-- fixed instant), each fact from the function that owns it: the population and the order from cma.lead_to_order_of (over
-- cma.lead_deals_of, one row per lead deal); the attempts in Attempts per deal's window (cma.sales_deals_of's, from the
-- creation less speed_to_lead.pre_window_minutes) by cma.deal_attempts_of under attempts.source, read once per deal; the
-- outcome and the close from cma.sales_deals_of; the source channel from the record, as the funnel reads it
create or replace function cma.lead_cohorts_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz, p_now timestamptz default now())
returns setof cma.lead_cohort_deal
language sql stable
as $$
  with s as materialized (
    select greatest(0, cma.setting_of(t.id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min,
           cma.setting_of(t.id, 'attempts.source') as source
    from cma.tenant t where t.id = p_tenant_id
  ),
  l as materialized (
    select * from cma.lead_to_order_of(p_tenant_id, p_from, p_to)
  ),
  a as materialized (
    select d.deal_id, d.outcome, d.closed_at, z.attempts, z.first_at, z.first_conversation_at
    from cma.sales_deals_of(p_tenant_id, p_from, p_to, p_now) d
    cross join s
    -- the deal's attempts, read once: Attempts per deal's (cma.attempts_per_deal_of reads them with the same arguments)
    cross join lateral (
      select (count(*) filter (where y.is_attempt))::integer as attempts,
             min(y.effective_at) filter (where y.is_attempt) as first_at,
             min(y.effective_at) filter (where y.is_attempt and y.conversation) as first_conversation_at
      from cma.deal_attempts_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts,
                                d.created_at - make_interval(mins => s.pre_min), d.window_end, s.source) y) z
  )
  select p_tenant_id, l.deal_id, l.connection_id, l.deal_source_id, l.pipeline_id, l.pipeline_label, l.market, r.source_channel,
         l.created_at, l.business_date, date_trunc('week', l.business_date)::date, date_trunc('month', l.business_date)::date,
         floor(extract(epoch from p_now - l.created_at) / 86400)::integer,
         a.attempts, a.first_at, a.first_conversation_at, a.outcome,
         case when a.outcome = 'lost' then a.closed_at end,
         l.order_created_at, l.days_to_order,
         coalesce(a.outcome = 'open' and a.attempts = 0, false)
  from l
  join cma.crm_record r on r.tenant_id = p_tenant_id and r.id = l.deal_id
  left join a on a.deal_id = l.deal_id
$$;

-- The lead deals of the business dates [p_from, p_to] (the tenant's zone) in one pass. The tenant, the bounds and the
-- instant reach the query as literals, so the definition is inlined and planned for this tenant and span (as 0008z's
-- cma.attempts_rows_of)
create or replace function cma.lead_cohort_rows_of(p_tenant_id uuid, p_from date, p_to date, p_now timestamptz)
returns cma.lead_cohort_deal[]
language plpgsql stable
as $$
declare
  v_zone text;
  v_rows cma.lead_cohort_deal[];
begin
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  execute format(
    'select coalesce(array_agg(x::cma.lead_cohort_deal order by x.created_at, x.deal_id), ''{}'')
     from cma.lead_cohorts_of(%L::uuid, %L::timestamptz, %L::timestamptz, %L::timestamptz) x',
    p_tenant_id, p_from::timestamp at time zone v_zone, (p_to + 1)::timestamp at time zone v_zone, p_now)
  into v_rows;
  return v_rows;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The report
-- ---------------------------------------------------------------------------------------------
-- The tenant's ages (cohorts.lead_ages_days) as whole numbers, in order
create or replace function cma.lead_cohort_ages_of(p_tenant_id uuid)
returns integer[]
language sql stable
as $$
  select coalesce(array_agg(u.x::integer order by u.o), '{}')
  from unnest(string_to_array(cma.setting_of(p_tenant_id, 'cohorts.lead_ages_days'), ',')) with ordinality as u(x, o)
$$;

-- The report's own choices: a period week or month, a split none, market or source. Anything else CMA04
create or replace function cma.lead_cohorts_choices_check(p_period text, p_split text)
returns void
language plpgsql immutable
as $$
begin
  if p_period is null or p_period not in ('week', 'month') then
    raise exception 'period is week or month, not %', coalesce(p_period, 'none') using errcode = 'CMA04';
  end if;
  if p_split is null or p_split not in ('none', 'market', 'source') then
    raise exception 'split is none, market or source, not %', coalesce(p_split, 'none') using errcode = 'CMA04';
  end if;
end
$$;

-- The figures of one cohort (or one group of it) as of p_now: created; per age of p_ages, in order, whether every deal is
-- that old (mature) and, once it is, the deals attempted, with a conversation, ordered and lost by then (null while it is
-- not; ordered null too at an age above p_max_days, lead_to_order.max_days); the deals ordered now and their median days to
-- order; the deals not called yet now. Counts only
create or replace function cma.lead_cohort_figures_from(p_rows cma.lead_cohort_deal[], p_ages integer[], p_max_days integer,
                                                        p_now timestamptz)
returns jsonb
language sql stable
as $$
  with r as (
    select x.* from unnest(coalesce(p_rows, '{}')) x
  )
  select jsonb_build_object(
    'created', (select count(*) from r),
    'not_called_yet', (select count(*) from r where r.not_called_yet),
    'ordered', (select count(*) from r where r.order_created_at is not null),
    'median_days_to_order', (select round((percentile_cont(0.5) within group (order by r.days_to_order))::numeric, 1)
                             from r where r.days_to_order is not null),
    'ages', coalesce((select jsonb_agg(jsonb_build_object(
                               'age', a.age, 'mature', m.mature,
                               'attempted', case when m.mature then m.attempted end,
                               'conversation', case when m.mature then m.conversation end,
                               'ordered', case when m.mature and a.age <= p_max_days then m.ordered end,
                               'lost', case when m.mature then m.lost end)
                             order by a.o)
                      from unnest(coalesce(p_ages, '{}')) with ordinality as a(age, o)
                      cross join lateral (
                        select count(*) > 0 and bool_and(r.created_at + make_interval(days => a.age) <= p_now) as mature,
                               count(*) filter (where r.first_attempt_at <= r.created_at + make_interval(days => a.age)) as attempted,
                               count(*) filter (where r.first_conversation_at <= r.created_at + make_interval(days => a.age)) as conversation,
                               count(*) filter (where r.order_created_at <= r.created_at + make_interval(days => a.age)) as ordered,
                               count(*) filter (where r.lost_at <= r.created_at + make_interval(days => a.age)) as lost
                        from r) m), '[]'::jsonb))
$$;

-- Per cohort (the ISO week's Monday or the month's first day of the creation's business date) newest first, and with a
-- split per market (unknown last) or per source channel (none last) within it: its key, label (ISO week as IYYY-Www, month
-- as YYYY-MM), first and last day, the group, whether the range cuts the period (partial), and its figures
create or replace function cma.lead_cohorts_from(p_rows cma.lead_cohort_deal[], p_period text, p_split text, p_ages integer[],
                                                 p_max_days integer, p_from date, p_to date, p_now timestamptz)
returns jsonb
language sql stable
as $$
  with r as (
    select row(x.*)::cma.lead_cohort_deal as rec,
           case when p_period = 'month' then x.month_start else x.week_start end as k,
           case p_split when 'market' then x.market when 'source' then x.source_channel end as g
    from unnest(coalesce(p_rows, '{}')) x
  ),
  c as (
    select r.k, r.g, array_agg(r.rec) as recs from r group by r.k, r.g
  )
  select coalesce(jsonb_agg(jsonb_build_object(
                    'key', c.k, 'label', case when p_period = 'month' then to_char(c.k, 'YYYY-MM') else to_char(c.k, 'IYYY-"W"IW') end,
                    'start', c.k, 'end', e.last_day, 'group', c.g, 'partial', c.k < p_from or e.last_day > p_to)
                  || cma.lead_cohort_figures_from(c.recs, p_ages, p_max_days, p_now)
                  order by c.k desc, (p_split = 'market' and c.g = 'unknown'), c.g nulls last), '[]'::jsonb)
  from c
  cross join lateral (
    select case when p_period = 'month' then (c.k + interval '1 month' - interval '1 day')::date else c.k + 6 end as last_day) e
$$;

-- The filter lists from the deals without the filters: the markets (unknown last), the pipelines ('<connection id>:<pipeline
-- id>' with the label, by label) and the source channels (by value), as the funnel's
create or replace function cma.lead_cohort_filter_lists_from(p_rows cma.lead_cohort_deal[])
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'markets', coalesce((select jsonb_agg(m.market order by m.market = 'unknown', m.market)
                         from (select distinct x.market from unnest(coalesce(p_rows, '{}')) x) m), '[]'::jsonb),
    'pipelines', coalesce((select jsonb_agg(jsonb_build_object('key', p.k, 'label', p.lbl) order by p.lbl, p.k)
                           from (select x.connection_id::text || ':' || x.pipeline_id as k, max(x.pipeline_label) as lbl
                                 from unnest(coalesce(p_rows, '{}')) x where x.pipeline_id is not null group by 1) p), '[]'::jsonb),
    'source_channels', coalesce((select jsonb_agg(c.v order by c.v)
                                 from (select distinct x.source_channel as v from unnest(coalesce(p_rows, '{}')) x
                                       where x.source_channel is not null) c), '[]'::jsonb))
$$;

-- The report of an explicit tenant as of p_now in one pass, as one JSON object: the period, the split, the ages, the days
-- lead to order counts (lead_to_order.max_days), the history start (intake.start_date), the cohorts of the deals the
-- filters keep (cohorts, never split, for the chart and the table), the same split per market or source channel (rows,
-- empty without a split), and the filter lists of the deals without the filters
create or replace function cma.lead_cohorts_report_of(p_tenant_id uuid, p_from date, p_to date, p_period text, p_pipeline text,
                                                      p_market text, p_source_channel text, p_split text, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_ages integer[] := cma.lead_cohort_ages_of(p_tenant_id);
  v_max  integer := cma.setting_of(p_tenant_id, 'lead_to_order.max_days')::integer;
  v_all  cma.lead_cohort_deal[];
  v_rows cma.lead_cohort_deal[];
begin
  v_all := cma.lead_cohort_rows_of(p_tenant_id, p_from, p_to, p_now);
  select coalesce(array_agg(x order by x.created_at, x.deal_id), '{}') into v_rows
  from unnest(v_all) x
  where (p_pipeline is null or x.connection_id::text || ':' || x.pipeline_id = p_pipeline)
    and (p_market is null or x.market = p_market)
    and (p_source_channel is null or x.source_channel = p_source_channel);
  return jsonb_build_object(
    'period', p_period, 'split', p_split, 'ages', to_jsonb(v_ages), 'lead_to_order_days', v_max,
    'history_start', cma.setting_of(p_tenant_id, 'intake.start_date')::date,
    'cohorts', cma.lead_cohorts_from(v_rows, p_period, 'none', v_ages, v_max, p_from, p_to, p_now),
    'rows', case when p_split = 'none' then '[]'::jsonb
                 else cma.lead_cohorts_from(v_rows, p_period, p_split, v_ages, v_max, p_from, p_to, p_now) end)
    || cma.lead_cohort_filter_lists_from(v_all);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The application's read (permission checked, parameters checked, current tenant, row-level security)
-- ---------------------------------------------------------------------------------------------
-- Reports, Lead cohorts in one read (reports.view or performance.team, as the funnel; at most 92 days of creation dates):
-- the period week or month, the market, source channel and pipeline filters as the funnel's, the split none, market or
-- source
create or replace function cma.lead_cohorts_report(p_from date, p_to date, p_period text default 'week', p_market text default null,
                                                   p_source_channel text default null, p_split text default 'none',
                                                   p_pipeline text default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.funnel_filters_check(p_market, p_pipeline, p_source_channel, null);
  perform cma.lead_cohorts_choices_check(p_period, p_split);
  return cma.lead_cohorts_report_of(v_tenant, p_from, p_to, p_period, p_pipeline, p_market, p_source_channel, p_split, now());
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
    'cma.lead_cohorts_of(uuid,timestamptz,timestamptz,timestamptz)',
    'cma.lead_cohort_rows_of(uuid,date,date,timestamptz)',
    'cma.lead_cohort_ages_of(uuid)',
    'cma.lead_cohorts_choices_check(text,text)',
    'cma.lead_cohort_figures_from(cma.lead_cohort_deal[],integer[],integer,timestamptz)',
    'cma.lead_cohorts_from(cma.lead_cohort_deal[],text,text,integer[],integer,date,date,timestamptz)',
    'cma.lead_cohort_filter_lists_from(cma.lead_cohort_deal[])',
    'cma.lead_cohorts_report_of(uuid,date,date,text,text,text,text,text,timestamptz)',
    'cma.lead_cohorts_report(date,date,text,text,text,text,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Reporting view
-- ---------------------------------------------------------------------------------------------
-- Every lead deal since each tenant's intake start with its cohort keys and facts, for readers (so BigQuery can cut cohorts
-- its own way, and later join NetSuite and the asset register): ids, codes, dates, times and counts only. Over a SECURITY
-- DEFINER function in cma_read (owned by cma_owner, search path pinned, executable by readers only) that reads every tenant
-- the reader sees, as 0007d's cma_read.lead_to_order_rows
create or replace function cma_read.lead_cohort_rows()
returns setof cma.lead_cohort_deal
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select r.* from cma.tenant t
  cross join lateral cma.lead_cohorts_of(t.id, null, null, now()) r
  where cma_read.reader_sees(t.id)
$$;
revoke execute on function cma_read.lead_cohort_rows() from public;
grant execute on function cma_read.lead_cohort_rows() to cma_readonly;

create or replace view cma_read.lead_cohorts as
  select * from cma_read.lead_cohort_rows();

-- ---------------------------------------------------------------------------------------------
-- 7. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zm', 'Lead cohorts: the setting cohorts.lead_ages_days (one to six increasing ages in days, the largest at most lead_to_order.max_days, which is refused below it; cma.check_tenant_setting() as 0008zi with both); the row type cma.lead_cohort_deal and cma.lead_cohorts_of (per lead deal of cma.lead_deals_of its ISO week and month, age, Attempts per deal''s first attempt and first conversation, cma.sales_deals_of''s outcome and lost time, lead to order''s first order, the source channel, not called yet); the report cma.lead_cohorts_report (period week or month, market, source channel and pipeline filters, split none, market or source; per cohort and age the deals attempted, with a conversation, ordered and lost, null at an age not reached; the median days to order; not called yet now); the reporting view cma_read.lead_cohorts over cma_read.lead_cohort_rows()')
on conflict (version) do nothing;

commit;
reset role;
