-- =============================================================================================
-- 92_attempts_per_deal.sql: addition 0008y, attempts per deal and the time since the last attempt
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 90_report_speed.sql (0008x). Rerunnable, forward-only, in one transaction. Run as your own IAM login:
-- dev first, then 93_verify_attempts_per_deal.sql (dev), then 41, 61, 69, 73, 75, 77, 81, 83, 85, 89 and 91
-- again (dev, unchanged), then 03 again (dev: the per-person setting takes attempts); then prod, before the
-- web that reads the two page reads is merged (the web before it runs unchanged on this addition).
--
-- Brief of 19 October 2026 (Martin; README Decision log, KPIs 1; backlog CMA-046, rest): how many times
-- the call center tries a deal before it reaches the customer, how often the first attempt reaches them,
-- whether more attempts win more deals, and how long the open deals have waited since their last attempt.
-- Covers HubSpot's "Open deals by activity date" and "Open deals not contacted recently" (CMA-042 port
-- rule: two weeks side by side). The attempts are the CRM's logged calls until the queue engine records
-- its own (README Planned migrations, 0011).
--
-- What it adds
--   settings           attempts.max_bucket (5, 2 to 20): the distribution's top bucket is "n+";
--                      attempts.since_last_buckets_business_days ('1,2,5'): one to six increasing whole
--                      numbers, as leads.age_buckets_business_days; reports.per_person also takes attempts
--                      (one to three of email, orders and attempts, each once, or nothing)
--   the population     cma.counted_deals_of(tenant, from, to): the deals of every counted deal pipeline with
--                      0007d's rules and shape, plus is_lead, is_order, the stage and closed_at; the market as
--                      cma.record_market_of gives it, with cma.market_code_of once per distinct value (record_market_of
--                      per deal took about 0.25 ms, measured). cma.lead_deals_of keeps its signature, its period
--                      bounds and its rows (93 compares it with 0008q's body): it reads counted_deals_of for the lead
--                      pipelines, so the population rule is written once, and every read of it (speed to lead,
--                      follow-up, forms, email) gets the faster market
--   the definition     cma.attempts_per_deal_of(tenant, from, to, scope, now): one row per deal (below)
--   reads              cma.attempts_per_deal_page(from, to, group, market, pipeline, scope) (reports.view or
--                      performance.team) and cma.attempts_per_person_page(from, to, market, pipeline, scope)
--                      (performance.team and reports.per_person holding attempts), each one read and one pass
--                      of the definition over the period and its previous span, answered as one JSON object
--   the line count     cma.telephony_number_stored_calls(connection, line): the stored calls a switch-off
--                      would remove and the first one's start (tenant.configure; backlog CMA-020)
--   reporting view     cma_read.attempts_per_deal (ids, codes, counts and times), over its own SECURITY
--                      DEFINER function in cma_read, for every tenant cma_read.reader_sees() allows
--
-- Definitions (one place each; README, Data model: attempts per deal). 0007d's are reused, never copied:
--   deal               scope lead (the default): a deal of a counted lead pipeline as cma.lead_deals_of has
--                      it; scope counted: a deal of any counted deal pipeline, with the same not-deleted and
--                      intake.start_date rules. An order pipeline (is_order, 0008u) is in neither. The
--                      business date is the creation in the tenant's zone; a period covers at most 92 days
--   attempt            an outbound CRM call of cma.lead_calls_of (not deleted, associated with the deal or
--                      its primary or currently associated contacts, its effective start at or after the
--                      creation minus speed_to_lead.pre_window_minutes), at or before the deal's closed_at
--                      (now while it is open). A call to a contact with two open deals counts for both
--   connected          lead_calls_of's flag: the outcome is_connected, or the linked telephony call answered
--   the n-th attempt   attempts in order of their effective start (then the call's id); the first
--                      connected attempt is n, or null when none connected
--   outcome            the stage's outcome (connection_stage.outcome, 0008u): won or lost; else open while
--                      the deal is open, unknown when it is closed
--   market             0007d's (the deal's own, else its primary contact's country; unknown otherwise)
--   owner              the person behind the deal's owner through app_user_external_id (<source>_owner),
--                      else none; never by id
--   since the last     for an open deal, the business days in its market (cma.business_days_of, 0008o) from
--                      its last attempt, or from its creation when it was never attempted, to now, in the
--                      buckets of attempts.since_last_buckets_business_days (cma.age_bucket_of); null for an
--                      unknown market
--
-- Everything is SECURITY INVOKER and executable by the application only; the cma_read function of the reader
-- view is SECURITY DEFINER, owned by cma_owner, search path pinned with pg_temp last, executable by readers only
-- (as 0007d, 0008o and 0008u). No table, no index: the reads use the indexes 0007d's reads use. Measured locally
-- as cma_app on a throwaway tenant at about twice prod's lead volume of 19 October 2026 (3,000 lead deals over
-- September and October, 9,600 CRM calls): the deal page of October 286 ms (by pipeline with every counted deal
-- 325 ms), per agent 146 ms; prod measures them before the merge (docs/attempts-2026-10/RUNBOOK.md). The reads return ids, codes, counts, links and times: no name, address or
-- phone number exists to return; a person's name only on the per-person page, as every per-person page.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0008x') then
    raise exception 'addition 0008x (90_report_speed.sql) must run before 0008y';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('attempts.max_bucket',                       'integer', null, '5',
     'The top bucket of Attempts per deal: deals with this many attempts or more are counted together as "n+" (2 to 20)'),
  ('attempts.since_last_buckets_business_days', 'text',    null, '1,2,5',
     'Buckets of the business days since an open deal''s last attempt (or its creation, never attempted): one to six increasing whole numbers, comma-separated, such as 1,2,5'),
  ('reports.per_person',                        'text',    null, '',
     'Per-person report pages switched on: comma-separated keys from email, orders and attempts, each once, lower case, no spaces; empty for none. Calls per agent is not under this setting')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- Increasing whole numbers from 1, comma-separated without spaces, one to p_max of them; cma.is_bucket_list(text)
-- of 0008o (one to five) keeps its own definition
create or replace function cma.is_bucket_list(p_value text, p_max integer)
returns boolean
language sql immutable
as $$
  select coalesce(p_max between 1 and 20
     and p_value ~ ('^[1-9][0-9]{0,3}(,[1-9][0-9]{0,3}){0,' || (p_max - 1) || '}$')
     and not exists (select 1 from (select x::integer as e, ord from unnest(string_to_array(p_value, ',')) with ordinality as u(x, ord)) a
                     join (select x::integer as e, ord from unnest(string_to_array(p_value, ',')) with ordinality as u(x, ord)) b
                       on b.ord = a.ord + 1
                     where b.e <= a.e), false)
$$;

-- reports.per_person: empty, or one to three of email, orders and attempts, each once, comma-separated without spaces
create or replace function cma.is_per_person_list(p_value text)
returns boolean
language sql immutable
as $$
  select coalesce(p_value = ''
                  or (p_value ~ '^(email|orders|attempts)(,(email|orders|attempts)){0,2}$'
                      and (select count(*) = count(distinct x) from unnest(string_to_array(p_value, ',')) x)), false)
$$;

-- As 0008u, plus the two attempts settings and attempts in reports.per_person
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
  if new.key = 'email.start_date' then
    new.value := btrim(new.value);
  end if;
  if new.key in ('leads.age_buckets_business_days', 'attempts.since_last_buckets_business_days') then
    new.value := regexp_replace(new.value, '[[:space:]]+', '', 'g');
  end if;
  if s.value_type = 'boolean' and new.value not in ('true', 'false') then
    raise exception 'Setting % takes true or false', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'integer' and new.value !~ '^-?[0-9]+$' then
    raise exception 'Setting % takes a whole number', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'date' or (new.key = 'email.start_date' and new.value <> '') then
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
    raise exception 'Setting % takes email, orders and attempts, each at most once, lower case, comma-separated without spaces, or nothing', new.key
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
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The deal population, written once
-- ---------------------------------------------------------------------------------------------
-- Deals of counted deal pipelines (a pipeline not yet seen counts, is a lead pipeline and no order
-- pipeline), not deleted, created on or after intake.start_date (the tenant's zone) and within [p_from,
-- p_to); with 0007d's shape (the pipeline label, the business date, the market and the deal's contacts:
-- the primary contact and the contacts currently associated with it), then whether the pipeline is a lead
-- pipeline and an order pipeline, the stage and the closing time. The market as cma.record_market_of gives
-- it (the deal's own value, else its primary contact's country, each only when it names a catalog market;
-- unknown otherwise), with cma.market_code_of run once per distinct value of the tenant instead of twice per
-- deal: called per deal, record_market_of took about a quarter of a millisecond (1.2 s for 4,800 deals)
create or replace function cma.counted_deals_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  deal_id            uuid,
  connection_id      uuid,
  source_system      text,
  record_type        text,
  source_id          text,
  pipeline_id        text,
  pipeline_label     text,
  owner_ref          text,
  contact_source_id  text,
  is_closed          boolean,
  created_at         timestamptz,
  business_date      date,
  market             text,
  market_source      text,
  contacts           text[],
  is_lead            boolean,
  is_order           boolean,
  stage_id           text,
  closed_at          timestamptz
)
language sql stable
as $$
  -- one row, read once (else the start date's setting is read again for every deal)
  with s as materialized (
    select t.timezone as zone, cma.setting_of(t.id, 'intake.start_date')::date as start_date,
           -- the catalog market of every value a deal's market reads (deals' own values, contacts' countries), as one map
           (select coalesce(jsonb_object_agg(v.value, cma.market_code_of(t.id, v.value)), '{}'::jsonb)
            from (select r.market as value from cma.crm_record r where r.tenant_id = t.id and r.record_type = 'deal'
                  union
                  select c.country from cma.crm_contact c where c.tenant_id = t.id) v
            where v.value is not null) as code_of
    from cma.tenant t where t.id = p_tenant_id
  )
  select d.id, d.connection_id, d.source_system, d.record_type, d.source_id, d.pipeline_id,
         coalesce(p.label, d.pipeline_id), d.owner_ref, d.contact_source_id, coalesce(d.is_closed, false),
         d.source_created_at, (d.source_created_at at time zone s.zone)::date,
         coalesce(s.code_of ->> d.market, s.code_of ->> cc.country, 'unknown'),
         case when s.code_of ->> d.market is not null then 'record' when s.code_of ->> cc.country is not null then 'contact' end,
         array(select x from (select d.contact_source_id as x where d.contact_source_id is not null
                              union
                              select a.to_id from cma.crm_association a
                              where a.tenant_id = d.tenant_id and a.connection_id = d.connection_id
                                and a.from_type = d.record_type and a.from_id = d.source_id
                                and a.to_type = 'contact' and a.removed_at is null) c
               order by x),
         coalesce(p.is_lead, true), coalesce(p.is_order, false), d.stage_id, d.closed_at
  from cma.crm_record d
  cross join s
  left join cma.connection_pipeline p
    on p.tenant_id = d.tenant_id and p.connection_id = d.connection_id
   and p.record_type = d.record_type and p.source_pipeline_id = d.pipeline_id
  left join cma.crm_contact cc
    on cc.tenant_id = d.tenant_id and cc.connection_id = d.connection_id and cc.source_id = d.contact_source_id
  where d.tenant_id = p_tenant_id
    and d.record_type = 'deal'
    and d.source_deleted_at is null
    and coalesce(p.is_counted, true)
    and d.source_created_at >= (s.start_date::timestamp at time zone s.zone)
    and d.source_created_at >= coalesce(p_from, '-infinity'::timestamptz)
    and d.source_created_at < coalesce(p_to, 'infinity'::timestamptz)
$$;

-- 0007d's lead population (as 0008q bound it): the same signature and rows, now the lead pipelines of
-- cma.counted_deals_of. The planner inlines both, so the period bounds still reach the (tenant, time) index
create or replace function cma.lead_deals_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table(deal_id uuid, connection_id uuid, source_system text, record_type text, source_id text, pipeline_id text,
              pipeline_label text, owner_ref text, contact_source_id text, is_closed boolean, created_at timestamptz,
              business_date date, market text, market_source text, contacts text[])
language sql stable
as $$
  select c.deal_id, c.connection_id, c.source_system, c.record_type, c.source_id, c.pipeline_id, c.pipeline_label, c.owner_ref,
         c.contact_source_id, c.is_closed, c.created_at, c.business_date, c.market, c.market_source, c.contacts
  from cma.counted_deals_of(p_tenant_id, coalesce(p_from, '-infinity'::timestamptz), coalesce(p_to, 'infinity'::timestamptz)) c
  where c.is_lead
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The definition: every deal of a period with its attempts
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if to_regtype('cma.attempt_deal') is null then
    create type cma.attempt_deal as (
      tenant_id                 uuid,
      deal_id                   uuid,
      connection_id             uuid,
      source_system             text,
      deal_source_id            text,
      record_url                text,
      pipeline_id               text,
      pipeline_label            text,
      is_lead                   boolean,
      stage_id                  text,
      market                    text,
      owner_ref                 text,
      owner_user_id             uuid,
      created_at                timestamptz,
      business_date             date,
      week_start                date,
      local_time                time,
      is_closed                 boolean,
      closed_at                 timestamptz,
      outcome                   text,
      attempts                  integer,
      connected                 integer,
      first_connected_attempt   integer,
      first_attempt_at          timestamptz,
      last_attempt_at           timestamptz,
      business_days_since_last  integer,
      since_last_from           integer,
      since_last_to             integer,
      since_last_bucket         text
    );
  end if;
end
$$;
comment on type cma.attempt_deal is
  'One deal as cma.attempts_per_deal_of gives it (0008y): its attempts (outbound CRM calls up to its close), the connected ones, the first connected attempt, its outcome and, open, the business days since its last attempt';

-- The scope a read takes: lead (the default) or counted
create or replace function cma.attempts_scope_check(p_scope text)
returns void
language plpgsql immutable
as $$
begin
  if p_scope is null or p_scope not in ('lead', 'counted') then
    raise exception 'scope is lead or counted, not %', coalesce(p_scope, 'none') using errcode = 'CMA04';
  end if;
end
$$;

-- One row per deal of the scope created in [p_from, p_to) (null: unbounded), as of p_now (now() for the
-- application; a verifier gives a fixed instant). Each deal's calls are read once, through 0007d's
-- cma.lead_calls_of; the link through cma.record_url (the current tenant's connection settings, so readers get
-- none); the owner through the linked account <source>_owner. An open deal's business days since its last attempt
-- (or its creation) are cma.business_days_of's, which depend only on the market and the local date counted from,
-- so it runs once per market and date; the bucket is cma.age_bucket_of's, once per number of days; the label as
-- Follow-up writes it ("0–1", "5+")
create or replace function cma.attempts_per_deal_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz, p_scope text,
                                                    p_now timestamptz default now())
returns setof cma.attempt_deal
language sql stable
as $$
  with s as materialized (
    select t.timezone as zone,
           greatest(0, cma.setting_of(t.id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min,
           cma.setting_of(t.id, 'attempts.since_last_buckets_business_days') as edges
    from cma.tenant t where t.id = p_tenant_id
  ),
  d as materialized (
    select x.*, mk.time_zone as market_zone,
           case when x.is_closed then least(coalesce(x.closed_at, p_now), p_now) else p_now end as upto
    from cma.counted_deals_of(p_tenant_id, p_from, p_to) x
    left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = x.market
    where not x.is_order and (x.is_lead or p_scope = 'counted')
  ),
  r as materialized (
    select d.*, a.attempts, a.connected, a.first_connected, a.first_at, a.last_at,
           coalesce(st.outcome, case when d.is_closed then 'unknown' else 'open' end) as outcome, xo.user_id as owner_user_id,
           -- the local date the business days of an open deal with business hours count from
           case when not d.is_closed and d.market_zone is not null
                then (coalesce(a.last_at, d.created_at) at time zone d.market_zone)::date end as since_day
    from d
    cross join s
    -- the deal's calls, read once: its attempts in the order of their effective start (then the call's id)
    cross join lateral (
      select count(*)::integer as attempts, (count(*) filter (where z.is_connected))::integer as connected,
             (min(z.n) filter (where z.is_connected))::integer as first_connected, min(z.effective_at) as first_at,
             max(z.effective_at) as last_at
      from (select lc.effective_at, lc.is_connected, row_number() over (order by lc.effective_at, lc.call_id) as n
            from cma.lead_calls_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts,
                                   d.created_at - make_interval(mins => s.pre_min)) lc
            where lc.direction = 'outbound' and lc.effective_at <= d.upto) z) a
    left join cma.connection_stage st
      on st.tenant_id = p_tenant_id and st.connection_id = d.connection_id and st.record_type = d.record_type
     and st.source_pipeline_id = d.pipeline_id and st.source_stage_id = d.stage_id
    left join cma.app_user_external_id xo
      on xo.tenant_id = p_tenant_id and xo.system = d.source_system || '_owner' and xo.external_id = d.owner_ref
  ),
  -- the business days from each market and local date to p_now (noon of the date stands for it)
  bd as materialized (
    select x.market, x.since_day,
           cma.business_days_of(p_tenant_id, x.market, (x.since_day + time '12:00') at time zone x.market_zone, p_now) as days
    from (select distinct r.market, r.market_zone, r.since_day from r where r.since_day is not null) x
  ),
  -- the bucket of each number of days
  bk as materialized (
    select x.days, b.bucket_from, b.bucket_to
    from (select distinct bd.days from bd where bd.days is not null) x
    cross join s
    cross join lateral cma.age_bucket_of(x.days, s.edges) b
  )
  select p_tenant_id, r.deal_id, r.connection_id, r.source_system, r.source_id,
         cma.record_url(r.connection_id, r.record_type, r.source_id),
         r.pipeline_id, r.pipeline_label, r.is_lead, r.stage_id, r.market, r.owner_ref, r.owner_user_id,
         r.created_at, r.business_date, date_trunc('week', r.business_date)::date, (r.created_at at time zone s.zone)::time,
         r.is_closed, r.closed_at, r.outcome, r.attempts, r.connected, r.first_connected, r.first_at, r.last_at,
         bd.days, bk.bucket_from, bk.bucket_to,
         case when bk.bucket_from is not null
              then case when bk.bucket_to is null then bk.bucket_from || '+' else bk.bucket_from || '–' || bk.bucket_to end end
  from r
  cross join s
  left join bd on bd.market = r.market and bd.since_day = r.since_day
  left join bk on bk.days = bd.days
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The reads of an explicit tenant, from deals read once
-- ---------------------------------------------------------------------------------------------
-- The filters every read takes: a market is a two-letter code or 'unknown'; a pipeline the connection's id and
-- the pipeline's source id, joined by ':'. Anything else CMA04
create or replace function cma.attempts_filters_check(p_market text, p_pipeline text)
returns void
language plpgsql immutable
as $$
begin
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'a market filter is a market code or unknown, not %', p_market using errcode = 'CMA04';
  end if;
  if p_pipeline is not null
     and p_pipeline !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[^[:space:]:]{1,100}$' then
    raise exception 'a pipeline filter is a connection id and a pipeline id joined by a colon, not %', p_pipeline using errcode = 'CMA04';
  end if;
end
$$;

-- The deals of the business dates [p_from, p_to] (the tenant's zone) in one pass of cma.attempts_per_deal_of, without
-- their record links
create or replace function cma.attempts_rows_of(p_tenant_id uuid, p_from date, p_to date, p_scope text, p_now timestamptz)
returns cma.attempt_deal[]
language sql stable
as $$
  -- the zone as a value, not a lateral row: the definition is planned for one tenant, as the application calls it.
  -- Without the record link, which the list builds for the rows it shows (cma.attempts_list_from): left unread, the
  -- planner does not compute it for every deal
  select coalesce(array_agg(row(x.tenant_id, x.deal_id, x.connection_id, x.source_system, x.deal_source_id, null, x.pipeline_id,
                                x.pipeline_label, x.is_lead, x.stage_id, x.market, x.owner_ref, x.owner_user_id, x.created_at, x.business_date,
                                x.week_start, x.local_time, x.is_closed, x.closed_at, x.outcome, x.attempts, x.connected,
                                x.first_connected_attempt, x.first_attempt_at, x.last_attempt_at, x.business_days_since_last,
                                x.since_last_from, x.since_last_to, x.since_last_bucket)::cma.attempt_deal), '{}')
  from cma.attempts_per_deal_of(p_tenant_id, p_from::timestamp at time zone (select t.timezone from cma.tenant t where t.id = p_tenant_id),
                                (p_to + 1)::timestamp at time zone (select t.timezone from cma.tenant t where t.id = p_tenant_id), p_scope, p_now) x
$$;

-- The deals of business dates [p_from, p_to] among deals already read, cut on p_to at p_until's time of day in
-- the tenant's zone (the previous span, like for like: cma.forms_previous_of), narrowed by market and pipeline
create or replace function cma.attempts_in_period(p_rows cma.attempt_deal[], p_from date, p_to date, p_market text, p_pipeline text,
                                                  p_until timestamptz, p_zone text)
returns cma.attempt_deal[]
language sql stable
as $$
  select coalesce(array_agg(row(r.*)::cma.attempt_deal), '{}')
  from unnest(p_rows) r
  where r.business_date between p_from and p_to
    and (p_until is null or r.business_date < p_to or r.local_time <= (p_until at time zone p_zone)::time)
    and (p_market is null or r.market = p_market)
    and (p_pipeline is null or r.connection_id::text || ':' || r.pipeline_id = p_pipeline)
$$;

-- The figures of a set of deals: deals; attempted (at least one attempt); attempts; the average and the median
-- attempts per deal (every deal, never attempted ones as 0); first_reached (the first attempt connected);
-- connected_deals (any attempt connected); open deals and open deals never attempted; won and lost
create or replace function cma.attempts_figures_from(p_rows cma.attempt_deal[])
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'deals', count(*),
    'attempted', count(*) filter (where r.attempts > 0),
    'attempts', coalesce(sum(r.attempts), 0),
    'avg_attempts', round(avg(r.attempts)::numeric, 2),
    'median_attempts', round((percentile_cont(0.5) within group (order by r.attempts))::numeric, 1),
    'first_reached', count(*) filter (where r.first_connected_attempt = 1),
    'connected_deals', count(*) filter (where r.connected > 0),
    'open_deals', count(*) filter (where not r.is_closed),
    'open_never_attempted', count(*) filter (where not r.is_closed and r.attempts = 0),
    'won', count(*) filter (where r.outcome = 'won'),
    'lost', count(*) filter (where r.outcome = 'lost'))
  from unnest(coalesce(p_rows, '{}')) r
$$;

-- Per attempt bucket 0 to p_max ("p_max+" holds that many or more): the deals with that many attempts, the deals
-- first connected on that attempt (none for 0), and of the closed deals with an outcome, the won and the lost
create or replace function cma.attempts_buckets_from(p_rows cma.attempt_deal[], p_max integer)
returns jsonb
language sql immutable
as $$
  with r as (
    -- least() passes over a null, so a deal never connected gets no first bucket rather than the top one
    select least(x.attempts, p_max) as bucket,
           case when x.first_connected_attempt is not null then least(x.first_connected_attempt, p_max) end as first_bucket, x.outcome
    from unnest(coalesce(p_rows, '{}')) x
  )
  select jsonb_agg(jsonb_build_object(
           'bucket', g.b,
           'label', case when g.b = p_max then g.b || '+' else g.b::text end,
           'deals', (select count(*) from r where r.bucket = g.b),
           'first_connected', (select count(*) from r where r.first_bucket = g.b),
           'won', (select count(*) from r where r.bucket = g.b and r.outcome = 'won'),
           'lost', (select count(*) from r where r.bucket = g.b and r.outcome = 'lost'))
         order by g.b)
  from generate_series(0, p_max) g(b)
$$;

-- The open deals by the business days since their last attempt, in the buckets of the edges ('1,2,5': 0–1, 1–2,
-- 2–5, 5+, as cma.age_bucket_of places them), every bucket listed; the open deals of an unknown market apart
create or replace function cma.attempts_since_last_from(p_rows cma.attempt_deal[], p_edges text)
returns jsonb
language sql immutable
as $$
  with e as (
    select x::integer as edge, ord
    from unnest(string_to_array(regexp_replace(coalesce(p_edges, ''), '[[:space:]]', '', 'g'), ',')) with ordinality as u(x, ord)
    where x ~ '^[0-9]+$'
  ),
  b as (
    select coalesce(lag(e.edge) over (order by e.ord), 0) as bfrom, e.edge as bto from e
    union all
    select coalesce(max(e.edge), 0), null from e
  ),
  o as (select x.* from unnest(coalesce(p_rows, '{}')) x where not x.is_closed)
  select jsonb_build_object(
    'buckets', coalesce((select jsonb_agg(jsonb_build_object(
                          'from', b.bfrom, 'to', b.bto,
                          'label', case when b.bto is null then b.bfrom || '+' else b.bfrom || '–' || b.bto end,
                          'deals', (select count(*) from o where o.since_last_from = b.bfrom and o.since_last_to is not distinct from b.bto))
                        order by b.bfrom, b.bto nulls last) from b), '[]'::jsonb),
    'no_hours', (select count(*) from o where o.business_days_since_last is null))
$$;

-- The figures per group of one grouping: day (the business date), week (its ISO week's Monday), market, pipeline
-- ('<connection id>:<pipeline id>' with its label); by key, pipelines by label
create or replace function cma.attempts_groups_from(p_rows cma.attempt_deal[], p_group text)
returns jsonb
language sql immutable
as $$
  with r as (
    select row(x.*)::cma.attempt_deal as rec,
           case p_group when 'day' then x.business_date::text when 'week' then x.week_start::text when 'market' then x.market
                        else x.connection_id::text || ':' || x.pipeline_id end as k,
           case p_group when 'pipeline' then x.pipeline_label end as lbl
    from unnest(coalesce(p_rows, '{}')) x
  ),
  g as (
    select r.k, max(r.lbl) as lbl, cma.attempts_figures_from(array_agg(r.rec)) as f
    from r
    group by r.k
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', g.k, 'label', g.lbl) || g.f order by g.lbl nulls first, g.k), '[]'::jsonb)
  from g
$$;

-- The list: the open deals first, the longest since the last attempt (or creation) first, an unknown market's after
-- them; then the closed deals, the newest close first; the first p_limit with the total. Ids, codes, counts, times
-- and the record link only
create or replace function cma.attempts_list_from(p_rows cma.attempt_deal[], p_limit integer)
returns jsonb
language sql stable
as $$
  with r as (select x.* from unnest(coalesce(p_rows, '{}')) x),
  shown as (
    select r.*,
           row_number() over (order by r.is_closed,
                                       case when not r.is_closed then r.business_days_since_last end desc nulls last,
                                       case when not r.is_closed then coalesce(r.last_attempt_at, r.created_at) end,
                                       case when r.is_closed then coalesce(r.closed_at, r.created_at) end desc,
                                       r.created_at desc, r.deal_source_id) as ord
    from r
  )
  select jsonb_build_object(
    'total', (select count(*) from r),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
               'connection_id', s.connection_id, 'deal_source_id', s.deal_source_id,
               'record_url', coalesce(s.record_url, cma.record_url(s.connection_id, 'deal', s.deal_source_id)),
               'pipeline_label', s.pipeline_label, 'market', s.market, 'created_at', s.created_at, 'closed_at', s.closed_at,
               'is_closed', s.is_closed, 'outcome', s.outcome, 'attempts', s.attempts, 'connected', s.connected,
               'first_connected_attempt', s.first_connected_attempt, 'last_attempt_at', s.last_attempt_at,
               'business_days_since_last', s.business_days_since_last, 'since_last_bucket', s.since_last_bucket)
             order by s.ord)
             from shown s where s.ord <= p_limit), '[]'::jsonb))
$$;

-- The filter lists from the period's deals without the filters: the markets (unknown last) and the pipelines
-- ('<connection id>:<pipeline id>' with the label, by label)
create or replace function cma.attempts_filter_lists_from(p_rows cma.attempt_deal[])
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'markets', coalesce((select jsonb_agg(m.market order by m.market = 'unknown', m.market)
                         from (select distinct x.market from unnest(coalesce(p_rows, '{}')) x) m), '[]'::jsonb),
    'pipelines', coalesce((select jsonb_agg(jsonb_build_object('key', p.k, 'label', p.lbl) order by p.lbl, p.k)
                           from (select x.connection_id::text || ':' || x.pipeline_id as k, max(x.pipeline_label) as lbl
                                 from unnest(coalesce(p_rows, '{}')) x where x.pipeline_id is not null group by 1) p), '[]'::jsonb))
$$;

-- The history: from the later of intake.start_date and the business date (the tenant's zone) of the tenant's earliest
-- stored CRM call, not deleted; null without one (no attempt can be counted before it, so no change shows against a
-- previous span that starts earlier)
create or replace function cma.attempts_history_start_of(p_tenant_id uuid)
returns date
language sql stable
as $$
  select case when c.first_at is not null
              then greatest(cma.setting_of(t.id, 'intake.start_date')::date, (c.first_at at time zone t.timezone)::date) end
  from cma.tenant t
  cross join lateral (select min(cc.occurred_at) as first_at from cma.crm_call cc
                      where cc.tenant_id = t.id and cc.source_deleted_at is null) c
  where t.id = p_tenant_id
$$;

-- The settings the pages' hints name, as their effective values
create or replace function cma.attempts_settings_of(p_tenant_id uuid)
returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'max_bucket', cma.setting_of(p_tenant_id, 'attempts.max_bucket')::integer,
    'since_last_buckets', cma.setting_of(p_tenant_id, 'attempts.since_last_buckets_business_days'),
    'pre_window_minutes', greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer),
    'list_rows', cma.setting_of(p_tenant_id, 'follow_up.list_rows')::integer)
$$;

-- Attempts per deal of an explicit tenant as of p_now, from one pass of cma.attempts_per_deal_of over the previous
-- span's first date to the period's last, as one JSON object:
--   current, previous   the figures of the period's deals and of the previous span's, like for like
--                       (cma.forms_previous_of: a period that reaches today against the same elapsed dates, the
--                       last of them up to the time of day; one that ended against the whole previous span)
--   buckets             per attempt bucket 0 to attempts.max_bucket: deals, first connected there, won, lost
--   groups              the figures per p_group (day, week, market, pipeline)
--   since_last          the open deals by business days since the last attempt; no_hours apart
--   list                the deals (open first, the longest since the last attempt first; then closed, the newest
--                       close first), p_rows of them, with the total
--   markets, pipelines  the filter lists, from the period without the filters
--   history_start, settings
create or replace function cma.attempts_per_deal_page_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_market text,
                                                         p_pipeline text, p_scope text, p_rows integer, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone   text;
  v_prev   record;
  v_all    cma.attempt_deal[];
  v_cur    cma.attempt_deal[];
begin
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  select * into v_prev from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now);
  -- the one pass: the previous span's first date to the period's last
  v_all := cma.attempts_rows_of(p_tenant_id, least(v_prev.prev_from, p_from), p_to, p_scope, p_now);
  v_cur := cma.attempts_in_period(v_all, p_from, p_to, p_market, p_pipeline, null, v_zone);
  return jsonb_build_object(
    'current', cma.attempts_figures_from(v_cur),
    'previous', cma.attempts_figures_from(cma.attempts_in_period(v_all, v_prev.prev_from, v_prev.prev_to, p_market, p_pipeline, v_prev.until, v_zone)),
    'buckets', cma.attempts_buckets_from(v_cur, cma.setting_of(p_tenant_id, 'attempts.max_bucket')::integer),
    'groups', cma.attempts_groups_from(v_cur, p_group),
    'since_last', cma.attempts_since_last_from(v_cur, cma.setting_of(p_tenant_id, 'attempts.since_last_buckets_business_days')),
    'list', cma.attempts_list_from(v_cur, p_rows),
    'history_start', cma.attempts_history_start_of(p_tenant_id),
    'settings', cma.attempts_settings_of(p_tenant_id))
    || cma.attempts_filter_lists_from(cma.attempts_in_period(v_all, p_from, p_to, null, null, null, v_zone));
end
$$;

-- Attempts per agent of an explicit tenant as of p_now, from one pass, as one JSON object: per deal owner by name,
-- never ranked, the figures of the deals they own (rows: user_id, display_name and the figures); the deals of an
-- owner id without a person, or without an owner, as one not-linked row with how many owner ids that is, never
-- which (null when none); the total; the filter lists, history_start and settings as the deal page gives them
create or replace function cma.attempts_per_person_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_pipeline text,
                                                      p_scope text, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone   text;
  v_all    cma.attempt_deal[];
  v_cur    cma.attempt_deal[];
begin
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  v_all := cma.attempts_rows_of(p_tenant_id, p_from, p_to, p_scope, p_now);
  v_cur := cma.attempts_in_period(v_all, p_from, p_to, p_market, p_pipeline, null, v_zone);
  return jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', p.uid, 'display_name', p.uname) || p.f order by p.uname, p.uid)
      from (select u.id as uid, u.display_name as uname, cma.attempts_figures_from(array_agg(row(r.*)::cma.attempt_deal)) as f
            from unnest(v_cur) r
            join cma.app_user u on u.tenant_id = p_tenant_id and u.id = r.owner_user_id
            group by u.id, u.display_name) p), '[]'::jsonb),
    'not_linked', (
      select jsonb_build_object('unlinked_owners', count(distinct r.owner_ref)) || cma.attempts_figures_from(array_agg(row(r.*)::cma.attempt_deal))
      from unnest(v_cur) r
      left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = r.owner_user_id
      where u.id is null
      having count(*) > 0),
    'total', cma.attempts_figures_from(v_cur),
    'history_start', cma.attempts_history_start_of(p_tenant_id),
    'settings', cma.attempts_settings_of(p_tenant_id))
    || cma.attempts_filter_lists_from(v_all);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The application's reads (permission checked, parameters checked, current tenant, row-level security)
-- ---------------------------------------------------------------------------------------------
-- The parameters both pages take: at most 92 days (CMA04); the scope lead or counted; the filters
create or replace function cma.attempts_params_check(p_tenant_id uuid, p_from date, p_to date, p_market text, p_pipeline text, p_scope text)
returns void
language plpgsql stable
as $$
begin
  perform cma.report_range(p_tenant_id, p_from, p_to);
  perform cma.attempts_scope_check(p_scope);
  perform cma.attempts_filters_check(p_market, p_pipeline);
end
$$;

-- Reports, Attempts per deal in one read and one pass (reports.view or performance.team): as
-- cma.attempts_per_deal_page_of for the current tenant and now, the list capped by follow_up.list_rows (or p_rows,
-- held within 1 to 500); grouped by day, week, market or pipeline
create or replace function cma.attempts_per_deal_page(p_from date, p_to date, p_group text, p_market text, p_pipeline text,
                                                      p_scope text default 'lead', p_rows integer default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'week', 'market', 'pipeline') then
    raise exception 'group by day, week, market or pipeline, not %', coalesce(p_group, 'none') using errcode = 'CMA04';
  end if;
  perform cma.attempts_params_check(v_tenant, p_from, p_to, p_market, p_pipeline, p_scope);
  return cma.attempts_per_deal_page_of(v_tenant, p_from, p_to, p_group, p_market, p_pipeline, p_scope,
    least(500, greatest(1, coalesce(p_rows, cma.setting_of(v_tenant, 'follow_up.list_rows')::integer))), now());
end
$$;

-- Reports, Attempts per agent in one read and one pass: performance.team, and the tenant's reports.per_person holding
-- attempts (cma.assert_per_person; CMA06 otherwise); as cma.attempts_per_person_of for the current tenant and now
create or replace function cma.attempts_per_person_page(p_from date, p_to date, p_market text, p_pipeline text, p_scope text default 'lead')
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_per_person('attempts');
  perform cma.attempts_params_check(v_tenant, p_from, p_to, p_market, p_pipeline, p_scope);
  return cma.attempts_per_person_of(v_tenant, p_from, p_to, p_market, p_pipeline, p_scope, now());
end
$$;

-- The stored calls a line holds, which switching it off would remove (0008f), and the first one's start: counts and
-- a time only. tenant.configure, as the switch; CMA02 for a line the tenant does not have (backlog CMA-020)
create or replace function cma.telephony_number_stored_calls(p_connection_id uuid, p_number_ref text,
                                                             out stored_calls integer, out first_started_at timestamptz)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('tenant.configure');
  if not exists (select 1 from cma.telephony_number n
                 where n.tenant_id = v_tenant and n.connection_id = p_connection_id and n.number_ref = p_number_ref) then
    raise exception 'no line % on connection %', p_number_ref, p_connection_id using errcode = 'CMA02';
  end if;
  select count(*)::integer, min(t.started_at) into stored_calls, first_started_at
  from cma.telephony_call t
  where t.tenant_id = v_tenant and t.connection_id = p_connection_id and t.number_ref = p_number_ref;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.is_bucket_list(text,integer)',
    'cma.is_per_person_list(text)',
    'cma.counted_deals_of(uuid,timestamptz,timestamptz)',
    'cma.lead_deals_of(uuid,timestamptz,timestamptz)',
    'cma.attempts_scope_check(text)',
    'cma.attempts_per_deal_of(uuid,timestamptz,timestamptz,text,timestamptz)',
    'cma.attempts_filters_check(text,text)',
    'cma.attempts_rows_of(uuid,date,date,text,timestamptz)',
    'cma.attempts_in_period(cma.attempt_deal[],date,date,text,text,timestamptz,text)',
    'cma.attempts_figures_from(cma.attempt_deal[])',
    'cma.attempts_buckets_from(cma.attempt_deal[],integer)',
    'cma.attempts_since_last_from(cma.attempt_deal[],text)',
    'cma.attempts_groups_from(cma.attempt_deal[],text)',
    'cma.attempts_list_from(cma.attempt_deal[],integer)',
    'cma.attempts_filter_lists_from(cma.attempt_deal[])',
    'cma.attempts_history_start_of(uuid)',
    'cma.attempts_settings_of(uuid)',
    'cma.attempts_per_deal_page_of(uuid,date,date,text,text,text,text,integer,timestamptz)',
    'cma.attempts_per_person_of(uuid,date,date,text,text,text,timestamptz)',
    'cma.attempts_params_check(uuid,date,date,text,text,text)',
    'cma.attempts_per_deal_page(date,date,text,text,text,text,integer)',
    'cma.attempts_per_person_page(date,date,text,text,text)',
    'cma.telephony_number_stored_calls(uuid,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Reporting view
-- ---------------------------------------------------------------------------------------------
-- Every deal of every counted deal pipeline but the order pipelines, since each tenant's intake start, with its
-- attempts as of now, for readers (is_lead tells the lead scope apart): over a SECURITY DEFINER function in
-- cma_read (owned by cma_owner, search path pinned, executable by readers only) that reads every tenant the reader
-- sees; ids, codes, counts and times only. The record link is the screens' (it needs the application's tenant)
create or replace function cma_read.attempts_per_deal_rows()
returns table (tenant_id uuid, deal_id uuid, connection_id uuid, deal_source_id text, pipeline_id text, pipeline_label text,
               is_lead boolean, market text, owner_user_id uuid, created_at timestamptz, business_date date, is_closed boolean,
               closed_at timestamptz, outcome text, attempts integer, connected integer, first_connected_attempt integer,
               first_attempt_at timestamptz, last_attempt_at timestamptz, business_days_since_last integer, since_last_bucket text)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label, r.is_lead, r.market, r.owner_user_id,
         r.created_at, r.business_date, r.is_closed, r.closed_at, r.outcome, r.attempts, r.connected, r.first_connected_attempt,
         r.first_attempt_at, r.last_attempt_at, r.business_days_since_last, r.since_last_bucket
  from cma.tenant t
  cross join lateral cma.attempts_per_deal_of(t.id, null, null, 'counted') r
  where cma_read.reader_sees(t.id)
$$;

do $$
begin
  execute 'revoke execute on function cma_read.attempts_per_deal_rows() from public';
  execute 'grant execute on function cma_read.attempts_per_deal_rows() to cma_readonly';
end
$$;

create or replace view cma_read.attempts_per_deal as
  select * from cma_read.attempts_per_deal_rows();

-- ---------------------------------------------------------------------------------------------
-- 8. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008y', 'Attempts per deal: the settings attempts.max_bucket and attempts.since_last_buckets_business_days, attempts in reports.per_person, the deal population written once (cma.counted_deals_of under cma.lead_deals_of), the definition cma.attempts_per_deal_of (outbound CRM calls up to the close, connected, the first connected attempt, the outcome, the business days since the last attempt), the deal and per-person pages, the stored calls of a line, the reporting view')
on conflict (version) do nothing;

commit;
reset role;
