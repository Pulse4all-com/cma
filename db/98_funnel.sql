-- =============================================================================================
-- 98_funnel.sql: addition 0008zb, reasons, record kinds and the funnel reports
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 96_stage_times.sql
-- (0008za). Rerunnable, forward-only, in one transaction. Run as your own IAM login: dev first, then
-- 99_verify_funnel.sql (dev; from the Terminal: its volume part runs longer than Studio likes), normal and provoked,
-- then 97, 95, 93, 91, 85, 81, 73 and 41 again; then 03 again in dev (the per-person key deals); then prod. The web and
-- the ingest of main read and write nothing this addition changes in shape, so both run on the migrated database
-- unchanged (docs/funnel-2026-10/RUNBOOK.md).
--
-- Brief N21, part 2 (Martin, 20 October 2026; README Decision log; backlog CMA-043, CMA-048, CMA-049 without CCL):
-- Kira's KPIs 4 and 5 in the Workspace: how deals move through their stages, why deals are lost, and how many
-- cancellation requests come in per market per week. Pipelines, stages, reasons and kinds are configuration; ids and
-- choice values only, never free text from the CRM.
--
-- What it adds
--   reason             connection_field takes the field reason for deals and tickets; connection_field.source_type and
--                      checked_at: the source's data type of the mapped property as the adapter last read it, and when
--                      (cleared when the property changes). crm_record.reason (at most 100 characters): the option's
--                      internal value, stored by cma.ingest_upsert_records only while the connection's reason field of
--                      the record type is an enumeration (source_type 'enumeration'): a text property is refused, since
--                      free text can hold personal data (0008p's choice answers only), and Sources says so
--   the catalog        cma.connection_reason (connection, record type, value, label, sort order, is_data_quality,
--                      status active or archived): the property's options, refreshed by cma.ingest_upsert_reasons (labels
--                      and order from the source, an option gone archived, never deleted); is_data_quality is set by a
--                      person on Sources (cma.set_reason_data_quality) and no refresh touches it. It splits the reasons
--                      that say the lead was never a lead (a duplicate, a wrong number) from the real lost reasons
--   record kinds       cma.record_kind, the tenant's catalog (key, label, record type, status, sort order); the rules
--                      cma.connection_record_kind (connection, kind, a pipeline and/or a category value, status); a
--                      record has a kind when an active rule of an active kind matches its pipeline and category
--                      (cma.kind_rule_matches, written once); cma.record_kind_of() gives a record's kinds; the
--                      configuration cma.set_record_kind, set_record_kind_status, set_record_kind_rule and the read
--                      cma.record_kinds() (tenant.configure). No kind is seeded here
--   settings           reports.cancellation_kind (the key of the kind Reports, Cancellations counts; empty: none);
--                      reports.per_person takes deals
--   the deals          cma.funnel_deal and cma.funnel_deals_of(tenant, now): 0008z's sales deals (cma.sales_deals_of,
--                      never copied) since intake.start_date with the stage's outcome, the source channel, the reason,
--                      the owner's person, the amount and currency, the creation and close as business dates and times
--                      in the tenant's zone; cma.funnel_rows_of() reads them in one pass with the tenant and the
--                      instant as literals (as 0008z's cma.attempts_rows_of)
--   reads              cma.deal_funnel_page(from, to, pipeline, market, source_channel): per stage that reads times,
--                      the deals that entered it in the period, still there now, moved on, the median days in the
--                      stage of those that moved on (medians only, Decision log, 15 October 2026), and the share that
--                      reached won; per pipeline the deals created, won and lost, the win rate by close date, the
--                      median days from the creation to won and to lost; the previous period like for like.
--                      cma.lost_reasons_page(from, to, pipeline, market, source_channel, group): the lost deals by
--                      close date per reason, per market (with the top 3), per source channel and per day or ISO week;
--                      the data-quality reasons apart; no reason as its own row (a KPI 11 figure); the lost deals
--                      without a reason as a list with their links.
--                      cma.cancellations_page(from, to, market, group): the tickets of the cancellation kind by
--                      creation date, per market and day or ISO week, open and closed, the median days to close, the
--                      reason where one is mapped, the history start, the newest requests with their links. It counts
--                      the request (the ticket), never the contract: Shopify and Juo own the contract.
--                      cma.deals_per_person_page(from, to, pipeline, market, source_channel): won, lost and the amount
--                      won per currency (never summed across currencies) per deal owner through the linked accounts,
--                      never ranked; performance.team and reports.per_person holding deals.
--                      Each is one read for its page, at most 92 days, reports.view or performance.team
--   reporting views    cma_read.deal_funnel_rows (per sales deal and stage: ids, dates, the stage, the reason value
--                      and the market) and cma_read.cancellation_rows (the cancellation kind's tickets), over their
--                      own SECURITY DEFINER functions; cma_read.connection_reason, record_kind,
--                      connection_record_kind; cma_read.crm_record_detail gains reason last
--
-- Definitions (one place each; README, Data model: reasons, kinds and the funnel). 0007d's, 0008u's and 0008z's are
-- reused, never copied:
--   deal               a sales deal (cma.sales_deals_of: a counted lead pipeline that is no order pipeline, not deleted,
--                      created on or after intake.start_date)
--   won, lost          the current stage's outcome (connection_stage.outcome, 0008u), by the close's business date in
--                      the tenant's zone; a lost deal whose customer ordered another way is lost here (Attempts per deal
--                      calls it ordered)
--   win rate           won over won and lost, of the deals closed in the period
--   entered            a deal whose stage time (crm_record_stage.entered_at, its latest entry) falls in the period, of
--                      a stage that reads times
--   still there        it entered in the period and the deal's current stage is the stage; moved on otherwise
--   days in stage      of the deals that moved on, from the entry to the exit (when the exit is after the entry)
--   reached won        of the deals that entered, those won now
--   lost reason        crm_record.reason: real, data quality (the catalog flags it), or none
--   cancellation       a ticket (the kind's record type), not deleted, of a counted pipeline, created on or after
--                      intake.start_date, matched by an active rule of the kind reports.cancellation_kind names; its
--                      market the ticket's own, else its primary contact's country (0007d's rule), unknown otherwise
--
-- Everything is SECURITY INVOKER and executable by the application only; the cma_read functions of the reporting
-- views are SECURITY DEFINER, owned by cma_owner, search path pinned with pg_temp last, executable by readers only.
-- The reads return ids, codes, counts, links and times; a person's name only on the per-person page.
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
  if not exists (select 1 from cma.schema_migration where version = '0008za') then
    raise exception 'addition 0008za (96_stage_times.sql) must run before 0008zb';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Record kinds (configuration), before the setting that names one
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.record_kind (
  id           uuid primary key default uuidv7(),
  tenant_id    uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key          text not null check (key ~ '^[a-z][a-z0-9_-]{1,40}$'),
  label        text not null check (length(label) between 1 and 80 and label = btrim(label)),
  record_type  text not null check (record_type in ('deal', 'ticket')),
  status       text not null default 'active' check (status in ('active', 'archived')),
  sort_order   integer not null default 100 check (sort_order between 0 and 10000),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (tenant_id, key),
  unique (tenant_id, id)
);
comment on table cma.record_kind is
  'The tenant''s kinds of CRM records (0008zb): a key, a label and the record type, as configuration (a cancellation request, later a CCL call and others); never deleted, archived switches one off. Which records have a kind: cma.connection_record_kind';
create or replace trigger set_updated_at before update on cma.record_kind
  for each row execute function cma.set_updated_at();
select cma.setup_tenant_table('cma.record_kind');
revoke delete on cma.record_kind from cma_app;

create table if not exists cma.connection_record_kind (
  id             uuid primary key default uuidv7(),
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id  uuid not null,
  kind_key       text not null,
  pipeline_id    text check (length(pipeline_id) between 1 and 100),
  category       text check (length(category) between 1 and 100),
  status         text not null default 'active' check (status in ('active', 'archived')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (pipeline_id is not null or category is not null),
  unique nulls not distinct (tenant_id, connection_id, kind_key, pipeline_id, category),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id),
  foreign key (tenant_id, kind_key) references cma.record_kind (tenant_id, key)
);
comment on table cma.connection_record_kind is
  'The rules that give records a kind (0008zb): per connection a kind with a pipeline, a category value (crm_record.category) or both; a record of the kind''s record type matches when every value the rule holds equals its own. Never deleted, archived switches a rule off';
create or replace trigger set_updated_at before update on cma.connection_record_kind
  for each row execute function cma.set_updated_at();
select cma.setup_tenant_table('cma.connection_record_kind');
revoke delete on cma.connection_record_kind from cma_app;

-- Whether a rule (its pipeline and category, null for any) matches a record's pipeline and category, written once
create or replace function cma.kind_rule_matches(p_rule_pipeline text, p_rule_category text, p_pipeline text, p_category text)
returns boolean
language sql immutable
as $$
  select (p_rule_pipeline is not null or p_rule_category is not null)
     and (p_rule_pipeline is null or p_rule_pipeline = p_pipeline)
     and (p_rule_category is null or p_rule_category = p_category)
$$;

-- A record's kinds: the active kinds of its record type with an active rule of its connection that matches it, by
-- their sort order and key
create or replace function cma.record_kind_of(p_tenant_id uuid, p_connection_id uuid, p_record_type text, p_pipeline_id text,
                                              p_category text)
returns text[]
language sql stable
as $$
  select coalesce(array_agg(k.key order by k.sort_order, k.key), '{}')
  from cma.record_kind k
  where k.tenant_id = p_tenant_id and k.status = 'active' and k.record_type = p_record_type
    and exists (select 1 from cma.connection_record_kind r
                where r.tenant_id = k.tenant_id and r.kind_key = k.key and r.connection_id = p_connection_id and r.status = 'active'
                  and cma.kind_rule_matches(r.pipeline_id, r.category, p_pipeline_id, p_category))
$$;

-- Adds a kind or changes its label and sort order (null keeps 100 for a new one, the stored one otherwise); its record
-- type is set once (CMA03 to change it). tenant.configure
create or replace function cma.set_record_kind(p_key text, p_label text, p_record_type text, p_sort_order integer default null)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_type   text;
begin
  perform cma.assert_permission('tenant.configure');
  if p_key is null or p_key !~ '^[a-z][a-z0-9_-]{1,40}$' then
    raise exception 'a kind''s key is 2 to 41 characters: a lower-case letter, then lower-case letters, digits, underscores or hyphens'
      using errcode = 'CMA04';
  end if;
  if p_label is null or length(btrim(p_label)) not between 1 and 80 then
    raise exception 'a kind''s label has 1 to 80 characters' using errcode = 'CMA04';
  end if;
  if p_record_type is null or p_record_type not in ('deal', 'ticket') then
    raise exception 'a kind is of deals or tickets, not %', coalesce(p_record_type, 'nothing') using errcode = 'CMA04';
  end if;
  if p_sort_order is not null and p_sort_order not between 0 and 10000 then
    raise exception 'a sort order is 0 to 10000' using errcode = 'CMA04';
  end if;
  select k.record_type into v_type from cma.record_kind k where k.tenant_id = v_tenant and k.key = p_key;
  if v_type is not null and v_type <> p_record_type then
    raise exception 'kind % is of % records; its record type stays', p_key, v_type using errcode = 'CMA03';
  end if;
  insert into cma.record_kind as k (tenant_id, key, label, record_type, sort_order)
  values (v_tenant, p_key, btrim(p_label), p_record_type, coalesce(p_sort_order, 100))
  on conflict (tenant_id, key) do update
    set label = excluded.label, sort_order = coalesce(p_sort_order, k.sort_order);
end
$$;

-- A kind active or archived (archived: no record has it; nothing is deleted). tenant.configure; CMA02 unknown
create or replace function cma.set_record_kind_status(p_key text, p_status text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  if p_status is null or p_status not in ('active', 'archived') then
    raise exception 'a kind is active or archived' using errcode = 'CMA04';
  end if;
  update cma.record_kind k set status = p_status where k.tenant_id = cma.current_tenant_id() and k.key = p_key;
  if not found then
    raise exception 'no record kind %', p_key using errcode = 'CMA02';
  end if;
end
$$;

-- A rule of a connection for a kind: a pipeline (the kind's record type's), a category value, or both (empty for
-- none); p_active true adds it or puts it back, false archives it. tenant.configure; CMA02 for an unknown kind or
-- connection, or a pipeline the connection has not read for the kind's record type; CMA04 without either value
create or replace function cma.set_record_kind_rule(p_connection_id uuid, p_kind_key text, p_pipeline_id text, p_category text,
                                                    p_active boolean default true)
returns void
language plpgsql
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_type     text;
  v_pipeline text := nullif(btrim(p_pipeline_id), '');
  v_category text := nullif(btrim(p_category), '');
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  select k.record_type into v_type from cma.record_kind k where k.tenant_id = v_tenant and k.key = p_kind_key;
  if v_type is null then
    raise exception 'no record kind %', coalesce(p_kind_key, 'null') using errcode = 'CMA02';
  end if;
  if v_pipeline is null and v_category is null then
    raise exception 'a rule needs a pipeline, a category value or both' using errcode = 'CMA04';
  end if;
  if p_active is null then
    raise exception 'a rule is active (true) or archived (false)' using errcode = 'CMA04';
  end if;
  if length(v_pipeline) > 100 or length(v_category) > 100 then
    raise exception 'a pipeline and a category value have at most 100 characters' using errcode = 'CMA04';
  end if;
  if v_pipeline is not null and not exists (select 1 from cma.connection_pipeline p
                                            where p.tenant_id = v_tenant and p.connection_id = p_connection_id
                                              and p.record_type = v_type and p.source_pipeline_id = v_pipeline) then
    raise exception 'no % pipeline % in connection %', v_type, v_pipeline, p_connection_id using errcode = 'CMA02';
  end if;
  if p_active then
    insert into cma.connection_record_kind as r (tenant_id, connection_id, kind_key, pipeline_id, category)
    values (v_tenant, p_connection_id, p_kind_key, v_pipeline, v_category)
    on conflict (tenant_id, connection_id, kind_key, pipeline_id, category) do update set status = 'active'
      where r.status <> 'active';
  else
    update cma.connection_record_kind r set status = 'archived'
    where r.tenant_id = v_tenant and r.connection_id = p_connection_id and r.kind_key = p_kind_key
      and r.pipeline_id is not distinct from v_pipeline and r.category is not distinct from v_category and r.status = 'active';
  end if;
end
$$;

-- The tenant's kinds with their rules, for Configuration, Sources (tenant.configure): key, label, record type, status,
-- sort order, the rules (connection, pipeline with its label, category, status), and whether the tenant's
-- reports.cancellation_kind names the kind
create or replace function cma.record_kinds()
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('tenant.configure');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'key', k.key, 'label', k.label, 'recordType', k.record_type, 'status', k.status, 'sortOrder', k.sort_order,
             'isCancellationKind', k.key = cma.setting_of(v_tenant, 'reports.cancellation_kind'),
             'rules', coalesce((select jsonb_agg(jsonb_build_object('connectionId', r.connection_id, 'pipelineId', r.pipeline_id,
                                                                     'pipelineLabel', p.label, 'category', r.category, 'status', r.status)
                                                  order by r.status, r.connection_id, p.label nulls first, r.pipeline_id, r.category)
                                from cma.connection_record_kind r
                                left join cma.connection_pipeline p
                                  on p.tenant_id = r.tenant_id and p.connection_id = r.connection_id and p.record_type = k.record_type
                                 and p.source_pipeline_id = r.pipeline_id
                                where r.tenant_id = k.tenant_id and r.kind_key = k.key), '[]'::jsonb))
           order by k.status, k.sort_order, k.key)
    from cma.record_kind k where k.tenant_id = v_tenant), '[]'::jsonb);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('reports.cancellation_kind', 'text', null, '',
     'The record kind Reports, Cancellations counts: the key of an active kind (Configuration, Sources); empty for none'),
  ('reports.per_person',        'text', null, '',
     'Per-person report pages switched on: comma-separated keys from email, orders, attempts and deals, each once, lower case, no spaces; empty for none. Calls per agent is not under this setting')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- reports.per_person: empty, or one to four of email, orders, attempts and deals, each once, comma-separated without spaces
create or replace function cma.is_per_person_list(p_value text)
returns boolean
language sql immutable
as $$
  select coalesce(p_value = ''
                  or (p_value ~ '^(email|orders|attempts|deals)(,(email|orders|attempts|deals)){0,3}$'
                      and (select count(*) = count(distinct x) from unnest(string_to_array(p_value, ',')) x)), false)
$$;

-- As 0008z, plus deals in reports.per_person and reports.cancellation_kind (an active kind of the tenant, or nothing)
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
  if new.key in ('leads.age_buckets_business_days', 'attempts.since_last_buckets_business_days', 'attempts.speed_buckets_business_minutes') then
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
  elsif new.key = 'attempts.reached_min_talk_seconds'
        and (case when length(new.value) > 3 then true else new.value::integer not between 0 and 600 end) then
    raise exception 'Setting % takes a whole number of seconds from 0 to 600', new.key using errcode = 'CMA04';
  elsif new.key = 'attempts.speed_buckets_business_minutes' and not cma.is_bucket_list(new.value, 6) then
    raise exception 'Setting % takes one to six increasing whole numbers of business minutes, comma-separated, such as 5,15,60,240,1440', new.key using errcode = 'CMA04';
  -- the funnel reports (0008zb): the record kind Reports, Cancellations counts, an active kind of the tenant, or nothing
  elsif new.key = 'reports.cancellation_kind' then
    new.value := btrim(new.value);
    if new.value <> '' and not exists (select 1 from cma.record_kind k
                                       where k.tenant_id = new.tenant_id and k.key = new.value and k.status = 'active') then
      raise exception 'Setting % takes the key of an active record kind, or nothing', new.key using errcode = 'CMA04';
    end if;
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The reason field and its catalog
-- ---------------------------------------------------------------------------------------------
alter table cma.connection_field drop constraint if exists connection_field_field_check;
alter table cma.connection_field add constraint connection_field_field_check
  check (field = any (array['market', 'language', 'country', 'currency', 'store', 'amount', 'source_channel', 'category', 'ref', 'created_at',
                            'reason']));
alter table cma.connection_field drop constraint if exists connection_field_entity_field_check;
alter table cma.connection_field add constraint connection_field_entity_field_check
  check (case when entity = 'contact' then field = any (array['country', 'language', 'currency', 'store', 'ref', 'created_at'])
              when field = 'reason' then entity in ('deal', 'ticket')
              else field = any (array['market', 'language', 'currency', 'amount', 'source_channel', 'category']) end);
alter table cma.connection_field add column if not exists source_type text;
alter table cma.connection_field add column if not exists checked_at timestamptz;
alter table cma.connection_field drop constraint if exists connection_field_source_type_check;
alter table cma.connection_field add constraint connection_field_source_type_check
  check (source_type ~ '^[a-z][a-z0-9_]{0,39}$' and checked_at is not null or source_type is null);
comment on column cma.connection_field.source_type is
  'The source''s data type of the mapped property as the adapter last read it (0008zb; for reason: a value is stored only from an enumeration); null until read, and again when the property changes';
comment on column cma.connection_field.checked_at is 'When the adapter last read the property''s data type (0008zb)';

alter table cma.crm_record add column if not exists reason text;
alter table cma.crm_record drop constraint if exists crm_record_reason_check;
alter table cma.crm_record add constraint crm_record_reason_check check (length(reason) between 1 and 100);
comment on column cma.crm_record.reason is
  'The internal value of the record''s reason option (0008zb; a deal''s lost reason, a ticket''s reason) from the mapped enumeration property; never free text: null while the property is unmapped, unread or not an enumeration';

-- As 0008u, and a changed property loses its checked data type (the adapter reads the new one's)
create or replace function cma.set_connection_field(p_connection_id uuid, p_entity text, p_field text,
                                                    p_ref_system text, p_source_property text, p_slot smallint)
returns void
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_slot    smallint := coalesce(p_slot, 1);
  v_slotted boolean := p_entity = 'contact' and p_field in ('country', 'created_at');
  v_first   smallint := case when p_entity = 'contact' and p_field = 'created_at' then 2 else 1 end;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_entity = 'contact' and p_field = 'created_at' and v_slot < 2 then
    raise exception 'created_at slot 1 is the contact''s own creation time and takes no property: map slots 2 to 9' using errcode = 'CMA04';
  end if;
  if coalesce(btrim(p_source_property), '') = '' then
    if v_slotted and exists (select 1 from cma.connection_field f
                             where f.tenant_id = v_tenant and f.connection_id = p_connection_id
                               and f.entity = 'contact' and f.field = p_field and f.slot > v_slot) then
      raise exception '% slot % cannot go while a later slot maps a property: remove the last slot first', p_field, v_slot
        using errcode = 'CMA04';
    end if;
    delete from cma.connection_field f
    where f.tenant_id = v_tenant and f.connection_id = p_connection_id
      and f.entity = p_entity and f.field = p_field and f.ref_system = coalesce(p_ref_system, '')
      and f.slot = v_slot;
    return;
  end if;
  if v_slotted and v_slot > v_first
     and not exists (select 1 from cma.connection_field f
                     where f.tenant_id = v_tenant and f.connection_id = p_connection_id
                       and f.entity = 'contact' and f.field = p_field and f.slot = v_slot - 1) then
    raise exception '% slot % needs slot % first: the slots are contiguous', p_field, v_slot, v_slot - 1 using errcode = 'CMA04';
  end if;
  if v_slotted and exists (select 1 from cma.connection_field f
                           where f.tenant_id = v_tenant and f.connection_id = p_connection_id
                             and f.entity = 'contact' and f.field = p_field and f.slot <> v_slot
                             and lower(f.source_property) = lower(btrim(p_source_property))) then
    raise exception 'the property % already feeds another % slot of this connection', btrim(p_source_property), p_field
      using errcode = 'CMA03';
  end if;
  insert into cma.connection_field as cf (tenant_id, connection_id, entity, field, ref_system, slot, source_property)
  values (v_tenant, p_connection_id, p_entity, p_field, coalesce(p_ref_system, ''), v_slot, btrim(p_source_property))
  on conflict (tenant_id, connection_id, entity, field, ref_system, slot)
    do update set source_property = excluded.source_property,
                  source_type = case when lower(cf.source_property) = lower(excluded.source_property) then cf.source_type end,
                  checked_at = case when lower(cf.source_property) = lower(excluded.source_property) then cf.checked_at end;
exception when check_violation or not_null_violation then
  raise exception 'invalid field mapping (%, %, %, slot %): %', p_entity, p_field, p_ref_system, p_slot, sqlerrm using errcode = 'CMA04';
end
$$;

-- As 0007, plus the reason: stored only while the connection's reason field of the record type is an enumeration
-- (connection_field.source_type); the option's value, trimmed, at most 100 characters
create or replace function cma.ingest_upsert_records(p_connection_id uuid, p_records jsonb)
returns table (record_type text, source_id text, outcome text, is_closed boolean)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  r          jsonb;
  v_type     text;
  v_src      text;
  v_updated  timestamptz;
  v_deleted  timestamptz;
  v_closed   boolean;
  v_old      cma.crm_record;
  v_new_id   uuid;
  v_reasons  text[];
  v_reason   text;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  -- the record types whose reason field is an enumeration: only their reasons are stored (0008zb)
  select coalesce(array_agg(f.entity), '{}') into v_reasons
  from cma.connection_field f
  where f.tenant_id = v_tenant and f.connection_id = p_connection_id and f.field = 'reason' and f.source_type = 'enumeration';
  if p_records is null or jsonb_typeof(p_records) <> 'array' or jsonb_array_length(p_records) > 500 then
    raise exception 'records must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for r in select value from jsonb_array_elements(p_records) loop
    v_type := r ->> 'recordType';
    v_src  := r ->> 'sourceId';
    if coalesce(v_type, '') !~ '^[a-z][a-z0-9_]*$' or v_type = 'contact' or coalesce(v_src, '') = '' then
      raise exception 'every record needs a recordType and a sourceId' using errcode = 'CMA04';
    end if;
    v_updated := cma.json_time(r -> 'updatedAt', 'updatedAt');
    v_deleted := cma.json_time(r -> 'deletedAt', 'deletedAt');
    select * into v_old from cma.crm_record cr
    where cr.tenant_id = v_tenant and cr.connection_id = p_connection_id and cr.record_type = v_type and cr.source_id = v_src
    for update;

    if v_deleted is not null then
      if v_old.id is null then
        return query select v_type, v_src, 'unknown'::text, null::boolean;
      else
        update cma.crm_record cr set source_deleted_at = v_deleted, synced_at = now()
        where cr.tenant_id = v_tenant and cr.id = v_old.id and cr.source_deleted_at is distinct from v_deleted;
        return query select v_type, v_src, 'deleted'::text, v_old.is_closed;
      end if;
      continue;
    end if;

    if v_old.id is not null and v_old.source_updated_at is not null
       and (v_updated is null or v_updated < v_old.source_updated_at) then
      return query select v_type, v_src, 'stale'::text, v_old.is_closed;
      continue;
    end if;

    v_reason := case when v_type = any (v_reasons) then left(nullif(btrim(r ->> 'reason'), ''), 100) end;

    select s.is_closed into v_closed
    from cma.connection_stage s
    where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.record_type = v_type
      and s.source_pipeline_id = r ->> 'pipelineId' and s.source_stage_id = r ->> 'stageId';

    if v_old.id is null then
      insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id,
                                  owner_ref, contact_source_id, market, language, is_closed, closed_at,
                                  source_created_at, source_updated_at, raw,
                                  amount, currency, source_channel, category, reason)
      values (v_tenant, p_connection_id, v_system, v_type, v_src, nullif(r ->> 'pipelineId', ''), nullif(r ->> 'stageId', ''),
              nullif(r ->> 'ownerRef', ''), nullif(r ->> 'contactId', ''), cma.normalize_market(r ->> 'market'),
              nullif(btrim(r ->> 'language'), ''), v_closed,
              case when v_closed then coalesce(cma.json_time(r -> 'closedAt', 'closedAt'), now()) end,
              coalesce(cma.json_time(r -> 'createdAt', 'createdAt'), now()), v_updated, coalesce(r -> 'raw', '{}'::jsonb),
              cma.json_amount(r -> 'amount'), cma.json_currency(r ->> 'currency'),
              left(nullif(btrim(r ->> 'sourceChannel'), ''), 100), left(nullif(btrim(r ->> 'category'), ''), 100), v_reason)
      returning id into v_new_id;
      return query select v_type, v_src, 'inserted'::text, v_closed;
    else
      update cma.crm_record cr
         set pipeline_id = nullif(r ->> 'pipelineId', ''),
             stage_id = nullif(r ->> 'stageId', ''),
             owner_ref = nullif(r ->> 'ownerRef', ''),
             contact_source_id = coalesce(nullif(r ->> 'contactId', ''), cr.contact_source_id),
             market = cma.normalize_market(r ->> 'market'),
             language = nullif(btrim(r ->> 'language'), ''),
             is_closed = v_closed,
             closed_at = case when v_closed then coalesce(cma.json_time(r -> 'closedAt', 'closedAt'),
                                                          case when cr.is_closed then cr.closed_at end, now()) end,
             source_created_at = coalesce(cma.json_time(r -> 'createdAt', 'createdAt'), cr.source_created_at),
             source_updated_at = v_updated,
             source_deleted_at = null,
             synced_at = now(),
             raw = coalesce(r -> 'raw', '{}'::jsonb),
             amount = cma.json_amount(r -> 'amount'),
             currency = cma.json_currency(r ->> 'currency'),
             source_channel = left(nullif(btrim(r ->> 'sourceChannel'), ''), 100),
             category = left(nullif(btrim(r ->> 'category'), ''), 100),
             reason = v_reason
       where cr.tenant_id = v_tenant and cr.id = v_old.id;
      return query select v_type, v_src, 'updated'::text, v_closed;
    end if;
  end loop;
end
$$;

create table if not exists cma.connection_reason (
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id    uuid not null,
  record_type      text not null check (record_type in ('deal', 'ticket')),
  value            text not null check (length(value) between 1 and 100),
  label            text not null check (length(label) between 1 and 200),
  sort_order       integer not null default 0,
  is_data_quality  boolean not null default false,
  status           text not null default 'active' check (status in ('active', 'archived')),
  refreshed_at     timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  primary key (tenant_id, connection_id, record_type, value),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.connection_reason is
  'The options of a connection''s reason property per record type (0008zb): value and label from the source (refreshed by the adapter; an option gone archived, never deleted), is_data_quality set by a person on Configuration, Sources and kept by every refresh';
create or replace trigger set_updated_at before update on cma.connection_reason
  for each row execute function cma.set_updated_at();
select cma.setup_tenant_table('cma.connection_reason');
revoke delete on cma.connection_reason from cma_app;

-- The adapter's read of the reason properties: [{recordType, property, type, options: [{value, label, order}]}] (at
-- most 10 items, 500 options each). Each item sets its field's source_type and checked_at (the field of that record
-- type mapping that property; none: the item is skipped); an enumeration's options refresh the catalog (label and order
-- from the source, active; an option gone archived), keeping is_data_quality; any other type leaves the catalog as it
-- is and stores no reason from then on. Answers how many options it wrote. ingest.write; CMA04 for a malformed item
create or replace function cma.ingest_upsert_reasons(p_connection_id uuid, p_items jsonb)
returns integer
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  i        jsonb;
  o        jsonb;
  v_found  boolean;
  v_n      integer := 0;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 10 then
    raise exception 'reason properties must be an array of at most 10' using errcode = 'CMA04';
  end if;
  for i in select value from jsonb_array_elements(p_items) loop
    if coalesce(i ->> 'recordType', '') not in ('deal', 'ticket') or coalesce(btrim(i ->> 'property'), '') = ''
       or coalesce(i ->> 'type', '') !~ '^[a-z][a-z0-9_]{0,39}$'
       or (i ->> 'type' = 'enumeration' and (jsonb_typeof(i -> 'options') is distinct from 'array' or jsonb_array_length(i -> 'options') > 500)) then
      raise exception 'every reason property needs recordType deal or ticket, property, type and, for an enumeration, an options array of at most 500'
        using errcode = 'CMA04';
    end if;
    update cma.connection_field f set source_type = i ->> 'type', checked_at = now()
    where f.tenant_id = v_tenant and f.connection_id = p_connection_id and f.entity = i ->> 'recordType' and f.field = 'reason'
      and lower(f.source_property) = lower(btrim(i ->> 'property'));
    v_found := found;
    if not v_found or i ->> 'type' <> 'enumeration' then
      continue;
    end if;
    for o in select value from jsonb_array_elements(i -> 'options') loop
      if coalesce(o ->> 'value', '') = '' or length(o ->> 'value') > 100 then
        raise exception 'every option needs a value of 1 to 100 characters' using errcode = 'CMA04';
      end if;
      insert into cma.connection_reason as cr (tenant_id, connection_id, record_type, value, label, sort_order, status, refreshed_at)
      values (v_tenant, p_connection_id, i ->> 'recordType', o ->> 'value',
              left(coalesce(nullif(btrim(o ->> 'label'), ''), o ->> 'value'), 200),
              case when (o ->> 'order') ~ '^-?[0-9]{1,9}$' then (o ->> 'order')::integer else 0 end, 'active', now())
      on conflict (tenant_id, connection_id, record_type, value) do update
        set label = excluded.label, sort_order = excluded.sort_order, status = 'active', refreshed_at = now()
        where cr.label is distinct from excluded.label or cr.sort_order is distinct from excluded.sort_order or cr.status <> 'active';
      v_n := v_n + 1;
    end loop;
    update cma.connection_reason cr set status = 'archived'
    where cr.tenant_id = v_tenant and cr.connection_id = p_connection_id and cr.record_type = i ->> 'recordType' and cr.status = 'active'
      and not exists (select 1 from jsonb_array_elements(i -> 'options') x where x ->> 'value' = cr.value);
  end loop;
  return v_n;
end
$$;

-- A person's flag on a reason option: data quality (true) or a real lost reason (false). Kept by every refresh.
-- tenant.configure; CMA02 for an option the connection has not read
create or replace function cma.set_reason_data_quality(p_connection_id uuid, p_record_type text, p_value text, p_is_data_quality boolean)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_is_data_quality is null then
    raise exception 'is_data_quality must be true or false' using errcode = 'CMA04';
  end if;
  update cma.connection_reason cr set is_data_quality = p_is_data_quality
  where cr.tenant_id = cma.current_tenant_id() and cr.connection_id = p_connection_id and cr.record_type = p_record_type
    and cr.value = p_value;
  if not found then
    raise exception 'no % reason % in connection %', p_record_type, p_value, p_connection_id using errcode = 'CMA02';
  end if;
end
$$;

-- The state of a connection's reason field of a record type, written once: none (not mapped), unchecked (mapped, its
-- data type not read yet), enumeration (its values are stored) or refused (another data type: nothing is stored)
create or replace function cma.reason_state_of(p_source_property text, p_source_type text)
returns text
language sql immutable
as $$
  select case when p_source_property is null then 'none' when p_source_type is null then 'unchecked'
              when p_source_type = 'enumeration' then 'enumeration' else 'refused' end
$$;

-- As 0008za, and each field gives its source type and when it was read (sourceType, checkedAt) and, for reason, its
-- state; the reason options per record type (reasons)
create or replace function cma.connection_config(p_connection_id uuid)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['ingest.write', 'tenant.configure']);
  if not exists (select 1 from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id) then
    raise exception 'no connection % in the current tenant', p_connection_id using errcode = 'CMA02';
  end if;
  return jsonb_build_object(
    'fields', coalesce((select jsonb_agg(jsonb_build_object('entity', f.entity, 'field', f.field,
                                                             'refSystem', nullif(f.ref_system, ''), 'slot', f.slot,
                                                             'property', f.source_property, 'sourceType', f.source_type,
                                                             'checkedAt', f.checked_at)
                                         || case when f.field = 'reason'
                                                 then jsonb_build_object('state', cma.reason_state_of(f.source_property, f.source_type)) else '{}'::jsonb end
                                         order by f.entity, f.field, f.ref_system, f.slot)
                        from cma.connection_field f where f.tenant_id = v_tenant and f.connection_id = p_connection_id), '[]'::jsonb),
    'reasons', coalesce((select jsonb_agg(jsonb_build_object('recordType', cr.record_type, 'value', cr.value, 'label', cr.label,
                                                              'order', cr.sort_order, 'isDataQuality', cr.is_data_quality, 'status', cr.status)
                                          order by cr.record_type, cr.status, cr.sort_order, cr.label, cr.value)
                         from cma.connection_reason cr where cr.tenant_id = v_tenant and cr.connection_id = p_connection_id), '[]'::jsonb),
    'pipelines', coalesce((select jsonb_agg(jsonb_build_object('recordType', p.record_type, 'pipelineId', p.source_pipeline_id,
                                                                'label', p.label, 'isCounted', p.is_counted, 'isRouted', p.is_routed,
                                                                'isLead', p.is_lead, 'isOrder', p.is_order, 'workType', s.key, 'status', p.status,
                                                                'stages', coalesce((select jsonb_agg(jsonb_build_object(
                                                                    'stageId', st.source_stage_id, 'label', st.label, 'order', st.display_order,
                                                                    'isClosed', st.is_closed, 'outcome', st.outcome, 'outcomeSource', st.outcome_source,
                                                                    'status', st.status, 'readTimes', cma.read_times_of(st.read_times, p.is_counted),
                                                                    'readTimesSet', st.read_times is not null)
                                                                  order by st.display_order, st.label, st.source_stage_id)
                                                                  from cma.connection_stage st
                                                                  where st.tenant_id = p.tenant_id and st.connection_id = p.connection_id
                                                                    and st.record_type = p.record_type and st.source_pipeline_id = p.source_pipeline_id),
                                                                  '[]'::jsonb))
                                            order by p.record_type, p.label, p.source_pipeline_id)
                           from cma.connection_pipeline p
                           left join cma.skill s on s.tenant_id = p.tenant_id and s.id = p.work_type_skill_id
                           where p.tenant_id = v_tenant and p.connection_id = p_connection_id), '[]'::jsonb),
    'settings', (select c.settings from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id),
    'store', (select jsonb_build_object('handle', s.handle, 'name', s.name, 'market', s.market, 'currency', s.currency,
                                        'timeZone', s.time_zone)
              from cma.commerce_store s where s.tenant_id = v_tenant and s.connection_id = p_connection_id),
    'writeback', coalesce((select jsonb_agg(jsonb_build_object('field', w.field, 'slot', w.slot, 'property', w.target_property,
                                                                'mode', w.mode, 'enabled', w.enabled)
                                            order by w.field, w.slot)
                           from cma.writeback_field w where w.tenant_id = v_tenant and w.connection_id = p_connection_id), '[]'::jsonb),
    'inboxes', coalesce((select jsonb_agg(jsonb_build_object('inboxId', b.source_inbox_id, 'name', b.name, 'isCounted', b.is_counted,
                                                              'market', b.market, 'workType', s.key, 'channel', ch.key, 'status', b.status)
                                          order by b.name, b.source_inbox_id)
                         from cma.connection_inbox b
                         left join cma.skill s on s.tenant_id = b.tenant_id and s.id = b.work_type_skill_id
                         left join cma.channel ch on ch.tenant_id = b.tenant_id and ch.id = b.channel_id
                         where b.tenant_id = v_tenant and b.connection_id = p_connection_id), '[]'::jsonb),
    'inboxChannels', coalesce((select jsonb_agg(jsonb_build_object('channelId', k.source_channel_id, 'name', k.name, 'kind', k.kind,
                                                                    'channel', ch.key, 'isCounted', k.is_counted, 'status', k.status)
                                                order by k.name, k.source_channel_id)
                               from cma.connection_inbox_channel k
                               left join cma.channel ch on ch.tenant_id = k.tenant_id and ch.id = k.channel_id
                               where k.tenant_id = v_tenant and k.connection_id = p_connection_id), '[]'::jsonb),
    'inboxAccounts', coalesce((select jsonb_agg(jsonb_build_object('accountId', a.source_account_id, 'name', a.name, 'label', a.label,
                                                                    'inboxId', a.inbox_source_id, 'channelId', a.channel_source_id,
                                                                    'isCounted', a.is_counted, 'market', a.market, 'status', a.status)
                                                order by coalesce(a.label, a.name), a.source_account_id)
                               from cma.connection_inbox_account a
                               where a.tenant_id = v_tenant and a.connection_id = p_connection_id), '[]'::jsonb),
    'emailRules', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'appliesTo', r.applies_to, 'words', to_jsonb(r.words),
                                                                 'excludeWords', to_jsonb(r.exclude_words), 'category', r.category,
                                                                 'order', r.sort_order, 'status', r.status)
                                             order by r.sort_order, r.created_at, r.id)
                            from cma.connection_email_rule r
                            where r.tenant_id = v_tenant and r.connection_id = p_connection_id), '[]'::jsonb));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The deals: 0008z's sales deals with what the funnel reads besides
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if to_regtype('cma.funnel_deal') is null then
    create type cma.funnel_deal as (
      tenant_id        uuid,
      deal_id          uuid,
      connection_id    uuid,
      source_system    text,
      deal_source_id   text,
      pipeline_id      text,
      pipeline_label   text,
      stage_id         text,
      stage_label      text,
      market           text,
      source_channel   text,
      reason           text,
      owner_ref        text,
      owner_user_id    uuid,
      created_at       timestamptz,
      created_date     date,
      created_time     time,
      closed_at        timestamptz,
      closed_date      date,
      closed_time      time,
      stage_outcome    text,
      outcome          text,
      amount           numeric,
      currency         text
    );
  end if;
end
$$;
comment on type cma.funnel_deal is
  'One sales deal as the funnel reads it (0008zb): 0008z''s sales deal (cma.sales_deals_of) with its current stage''s outcome, source channel, reason, owner''s person, amount and currency (the deal''s, else its market''s), its creation and close as business dates and times in the tenant''s zone';

-- Every sales deal since intake.start_date as of p_now, as cma.funnel_deal: cma.sales_deals_of (0008z, read once), the
-- record's own columns by its id, the stage's outcome, the owner through the linked account <source>_owner
create or replace function cma.funnel_deals_of(p_tenant_id uuid, p_now timestamptz default now())
returns setof cma.funnel_deal
language sql stable
as $$
  with s as materialized (
    select t.timezone as zone from cma.tenant t where t.id = p_tenant_id
  )
  select p_tenant_id, d.deal_id, d.connection_id, d.source_system, d.source_id, d.pipeline_id, d.pipeline_label, d.stage_id, d.stage_label,
         d.market, r.source_channel, r.reason, d.owner_ref, xo.user_id, d.created_at, d.business_date, (d.created_at at time zone s.zone)::time,
         d.closed_at, (d.closed_at at time zone s.zone)::date, (d.closed_at at time zone s.zone)::time,
         case when d.is_closed then st.outcome end, d.outcome, r.amount, coalesce(r.currency, mk.currency)
  from cma.sales_deals_of(p_tenant_id, null, null, p_now) d
  cross join s
  join cma.crm_record r on r.tenant_id = p_tenant_id and r.id = d.deal_id
  left join cma.connection_stage st
    on st.tenant_id = p_tenant_id and st.connection_id = d.connection_id and st.record_type = d.record_type
   and st.source_pipeline_id = d.pipeline_id and st.source_stage_id = d.stage_id
  left join cma.app_user_external_id xo
    on xo.tenant_id = p_tenant_id and xo.system = d.source_system || '_owner' and xo.external_id = d.owner_ref
  left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = d.market
$$;

-- The tenant's sales deals in one pass. The tenant and the instant reach the query as literals, so the definition is
-- inlined and planned for this tenant (as 0008z's cma.attempts_rows_of)
create or replace function cma.funnel_rows_of(p_tenant_id uuid, p_now timestamptz)
returns cma.funnel_deal[]
language plpgsql stable
as $$
declare
  v_rows cma.funnel_deal[];
begin
  execute format('select coalesce(array_agg(x::cma.funnel_deal), ''{}'') from cma.funnel_deals_of(%L::uuid, %L::timestamptz) x',
                 p_tenant_id, p_now)
  into v_rows;
  return v_rows;
end
$$;

-- Whether a business date and time lie in [p_from, p_to], the last date cut at p_until (a time of day: the previous
-- span like for like, as cma.forms_previous_of gives it; null: the whole last date), written once
create or replace function cma.in_period(p_date date, p_time time, p_from date, p_to date, p_until time)
returns boolean
language sql immutable
as $$
  select p_date between p_from and p_to and (p_until is null or p_date < p_to or p_time <= p_until)
$$;

-- The filters the funnel pages take: a market a two-letter code or unknown, a pipeline '<connection id>:<pipeline id>'
-- (0008y's cma.attempts_filters_check), a source channel 1 to 100 characters without control characters; a group day
-- or week. Anything else CMA04
create or replace function cma.funnel_filters_check(p_market text, p_pipeline text, p_source_channel text, p_group text)
returns void
language plpgsql immutable
as $$
begin
  perform cma.attempts_filters_check(p_market, p_pipeline);
  if p_source_channel is not null and (length(p_source_channel) not between 1 and 100 or p_source_channel ~ '[[:cntrl:]]') then
    raise exception 'a source channel filter has 1 to 100 characters' using errcode = 'CMA04';
  end if;
  if p_group is not null and p_group not in ('day', 'week') then
    raise exception 'group by day or week, not %', p_group using errcode = 'CMA04';
  end if;
end
$$;

-- The deals the filters keep
create or replace function cma.funnel_filter(p_rows cma.funnel_deal[], p_pipeline text, p_market text, p_source_channel text)
returns cma.funnel_deal[]
language sql immutable
as $$
  select coalesce(array_agg(r order by r.created_at, r.deal_id), '{}')
  from unnest(coalesce(p_rows, '{}')) r
  where (p_pipeline is null or r.connection_id::text || ':' || r.pipeline_id = p_pipeline)
    and (p_market is null or r.market = p_market)
    and (p_source_channel is null or r.source_channel = p_source_channel)
$$;

-- The filter lists from the deals without the filters: the markets (unknown last), the pipelines ('<connection
-- id>:<pipeline id>' with the label, by label) and the source channels (by value)
create or replace function cma.funnel_filter_lists_from(p_rows cma.funnel_deal[])
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

-- ---------------------------------------------------------------------------------------------
-- 5. The funnel
-- ---------------------------------------------------------------------------------------------
-- The figures of a set of deals in [p_from, p_to] (the last date cut at p_until): created (by the creation's business
-- date); won and lost (by the close's), the win rate (won over won and lost), the median days from the creation to won
-- and to lost
create or replace function cma.funnel_figures_from(p_rows cma.funnel_deal[], p_from date, p_to date, p_until time)
returns jsonb
language sql immutable
as $$
  with r as (
    select x.*, cma.in_period(x.created_date, x.created_time, p_from, p_to, p_until) as in_created,
           x.closed_date is not null and cma.in_period(x.closed_date, x.closed_time, p_from, p_to, p_until) as in_closed,
           extract(epoch from x.closed_at - x.created_at) / 86400.0 as days
    from unnest(coalesce(p_rows, '{}')) x
  )
  select jsonb_build_object(
    'created', count(*) filter (where r.in_created),
    'won', count(*) filter (where r.in_closed and r.stage_outcome = 'won'),
    'lost', count(*) filter (where r.in_closed and r.stage_outcome = 'lost'),
    'win_rate', round(count(*) filter (where r.in_closed and r.stage_outcome = 'won')::numeric
                      / nullif(count(*) filter (where r.in_closed and r.stage_outcome in ('won', 'lost')), 0), 4),
    'median_days_to_won', round((percentile_cont(0.5) within group (order by r.days) filter (where r.in_closed and r.stage_outcome = 'won'))::numeric, 1),
    'median_days_to_lost', round((percentile_cont(0.5) within group (order by r.days) filter (where r.in_closed and r.stage_outcome = 'lost'))::numeric, 1))
  from r
$$;

-- Per pipeline ('<connection id>:<pipeline id>' with the label, by label) and in total: the figures of the period and
-- of the previous span like for like
create or replace function cma.funnel_pipelines_from(p_rows cma.funnel_deal[], p_from date, p_to date, p_prev_from date, p_prev_to date,
                                                     p_until time)
returns jsonb
language sql immutable
as $$
  with r as (
    select row(x.*)::cma.funnel_deal as rec, x.connection_id::text || ':' || x.pipeline_id as k, x.pipeline_label as lbl
    from unnest(coalesce(p_rows, '{}')) x
  ),
  g as (
    select r.k, max(r.lbl) as lbl, array_agg(r.rec) as recs from r group by r.k
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('key', g.k, 'label', g.lbl,
                                                          'current', cma.funnel_figures_from(g.recs, p_from, p_to, null),
                                                          'previous', cma.funnel_figures_from(g.recs, p_prev_from, p_prev_to, p_until))
                                       order by g.lbl, g.k)
                      from g), '[]'::jsonb),
    'total', jsonb_build_object('current', cma.funnel_figures_from(p_rows, p_from, p_to, null),
                                'previous', cma.funnel_figures_from(p_rows, p_prev_from, p_prev_to, p_until)))
$$;

-- Per stage of the deals' pipelines (and of every active lead pipeline that is no order pipeline, counted, of the
-- tenant's connections; one pipeline with a pipeline filter), in the pipeline's order: whether its times are read
-- (cma.read_times_of), and of the deals whose entry falls in the period: entered, still there (their current stage is
-- this one), moved on, the median days in the stage of those that moved on (exit after entry; the median only, as every
-- report since 15 October 2026), reached won (won now); entered in the previous span like for like. A stage that reads
-- no times has no figures
create or replace function cma.funnel_stages_of(p_tenant_id uuid, p_rows cma.funnel_deal[], p_pipeline text, p_from date, p_to date,
                                                p_prev_from date, p_prev_to date, p_until time)
returns jsonb
language sql stable
as $$
  with s as materialized (
    select t.timezone as zone from cma.tenant t where t.id = p_tenant_id
  ),
  d as materialized (
    select x.* from unnest(coalesce(p_rows, '{}')) x
  ),
  pl as materialized (
    select p.connection_id, p.source_pipeline_id as pipeline_id, p.label, p.is_counted
    from cma.connection_pipeline p
    where p.tenant_id = p_tenant_id and p.record_type = 'deal'
      and ((p.status = 'active' and coalesce(p.is_counted, true) and coalesce(p.is_lead, true) and not coalesce(p.is_order, false))
           or exists (select 1 from d where d.connection_id = p.connection_id and d.pipeline_id = p.source_pipeline_id))
      and (p_pipeline is null or p.connection_id::text || ':' || p.source_pipeline_id = p_pipeline)
  ),
  st as materialized (
    select pl.connection_id, pl.pipeline_id, pl.label as pipeline_label, c.source_stage_id as stage_id, c.label, c.display_order,
           c.is_closed, c.outcome, cma.read_times_of(c.read_times, pl.is_counted) as reads
    from pl
    join cma.connection_stage c
      on c.tenant_id = p_tenant_id and c.connection_id = pl.connection_id and c.record_type = 'deal'
     and c.source_pipeline_id = pl.pipeline_id and c.status = 'active'
  ),
  e as materialized (
    select rs.connection_id, rs.source_pipeline_id as pipeline_id, rs.source_stage_id as stage_id, rs.entered_at, rs.exited_at,
           (rs.entered_at at time zone s.zone)::date as entered_date, (rs.entered_at at time zone s.zone)::time as entered_time,
           d.stage_id as current_stage_id, d.stage_outcome
    from cma.crm_record_stage rs
    cross join s
    join d on d.connection_id = rs.connection_id and d.deal_source_id = rs.source_id
    where rs.tenant_id = p_tenant_id and rs.record_type = 'deal' and rs.entered_at is not null
      and rs.entered_at >= (least(p_from, p_prev_from)::timestamp at time zone s.zone)
      and rs.entered_at < ((p_to + 1)::timestamp at time zone s.zone)
  ),
  f as (
    select e.connection_id, e.stage_id,
           count(*) filter (where cma.in_period(e.entered_date, e.entered_time, p_from, p_to, null)) as entered,
           count(*) filter (where cma.in_period(e.entered_date, e.entered_time, p_from, p_to, null) and e.current_stage_id = e.stage_id) as still_there,
           count(*) filter (where cma.in_period(e.entered_date, e.entered_time, p_from, p_to, null)
                            and e.current_stage_id is distinct from e.stage_id) as moved_on,
           percentile_cont(0.5) within group (order by extract(epoch from e.exited_at - e.entered_at) / 86400.0)
             filter (where cma.in_period(e.entered_date, e.entered_time, p_from, p_to, null) and e.current_stage_id is distinct from e.stage_id
                     and e.exited_at >= e.entered_at) as median_days,
           count(*) filter (where cma.in_period(e.entered_date, e.entered_time, p_from, p_to, null) and e.current_stage_id is distinct from e.stage_id
                            and e.exited_at >= e.entered_at) as timed,
           count(*) filter (where cma.in_period(e.entered_date, e.entered_time, p_from, p_to, null) and e.stage_outcome = 'won') as reached_won,
           count(*) filter (where cma.in_period(e.entered_date, e.entered_time, p_prev_from, p_prev_to, p_until)) as entered_previous
    from e
    group by e.connection_id, e.stage_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'pipeline', st.connection_id::text || ':' || st.pipeline_id, 'pipeline_label', st.pipeline_label,
           'stage_id', st.stage_id, 'label', st.label, 'order', st.display_order, 'is_closed', st.is_closed, 'outcome', st.outcome,
           'reads_times', st.reads,
           'entered', case when st.reads then coalesce(f.entered, 0) end,
           'still_there', case when st.reads then coalesce(f.still_there, 0) end,
           'moved_on', case when st.reads then coalesce(f.moved_on, 0) end,
           'timed', case when st.reads then coalesce(f.timed, 0) end,
           'median_days', case when st.reads then round(f.median_days::numeric, 1) end,
           'reached_won', case when st.reads then coalesce(f.reached_won, 0) end,
           'won_share', case when st.reads then round(f.reached_won::numeric / nullif(f.entered, 0), 4) end,
           'entered_previous', case when st.reads then coalesce(f.entered_previous, 0) end)
         order by st.pipeline_label, st.connection_id, st.display_order, st.label, st.stage_id), '[]'::jsonb)
  from st
  left join f on f.connection_id = st.connection_id and f.stage_id = st.stage_id
$$;

-- When the funnel's histories start: the deals' (the later of intake.start_date and the earliest sales deal's creation
-- date) and the stage times' (the earliest stored entry of a deal stage, the tenant's zone; null before the first)
create or replace function cma.funnel_history_start_of(p_tenant_id uuid, p_rows cma.funnel_deal[])
returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'deals', (select greatest(cma.setting_of(p_tenant_id, 'intake.start_date')::date, min(x.created_date)) from unnest(coalesce(p_rows, '{}')) x),
    'stages', (select (min(rs.entered_at) at time zone t.timezone)::date
               from cma.tenant t
               left join cma.crm_record_stage rs on rs.tenant_id = t.id and rs.record_type = 'deal'
               where t.id = p_tenant_id
               group by t.timezone))
$$;

-- The funnel of an explicit tenant as of p_now in one pass, as one JSON object: stages (per stage that reads times, of
-- the deals the filters keep), by_pipeline (per pipeline and in total, current and previous), the filter lists of the
-- deals without the filters, the previous span, the history starts, and how many stages read times
create or replace function cma.deal_funnel_page_of(p_tenant_id uuid, p_from date, p_to date, p_pipeline text, p_market text,
                                                   p_source_channel text, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone  text;
  v_prev  record;
  v_until time;
  v_all   cma.funnel_deal[];
  v_rows  cma.funnel_deal[];
begin
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  select * into v_prev from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now);
  v_until := (v_prev.until at time zone v_zone)::time;
  v_all := cma.funnel_rows_of(p_tenant_id, p_now);
  v_rows := cma.funnel_filter(v_all, p_pipeline, p_market, p_source_channel);
  return jsonb_build_object(
    'stages', cma.funnel_stages_of(p_tenant_id, v_rows, p_pipeline, p_from, p_to, v_prev.prev_from, v_prev.prev_to, v_until),
    'by_pipeline', cma.funnel_pipelines_from(v_rows, p_from, p_to, v_prev.prev_from, v_prev.prev_to, v_until),
    'previous_from', v_prev.prev_from, 'previous_to', v_prev.prev_to, 'previous_partial', v_prev.until is not null,
    'history_start', cma.funnel_history_start_of(p_tenant_id, v_all),
    'timed_stages', (select count(*) from cma.connection_stage c
                     left join cma.connection_pipeline p
                       on p.tenant_id = c.tenant_id and p.connection_id = c.connection_id and p.record_type = c.record_type
                      and p.source_pipeline_id = c.source_pipeline_id
                     where c.tenant_id = p_tenant_id and c.record_type = 'deal' and c.status = 'active'
                       and cma.read_times_of(c.read_times, p.is_counted)))
    || cma.funnel_filter_lists_from(v_all);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Lost reasons
-- ---------------------------------------------------------------------------------------------
-- The lost deals of a set in [p_from, p_to] (the last date cut at p_until), by the close's business date
create or replace function cma.funnel_lost_in(p_rows cma.funnel_deal[], p_from date, p_to date, p_until time)
returns cma.funnel_deal[]
language sql immutable
as $$
  select coalesce(array_agg(x order by x.closed_at, x.deal_id), '{}')
  from unnest(coalesce(p_rows, '{}')) x
  where x.stage_outcome = 'lost' and x.closed_date is not null and cma.in_period(x.closed_date, x.closed_time, p_from, p_to, p_until)
$$;

-- The deal reason options of the tenant by value (the label and flag of any connection's option of that value, an
-- active one first): a lost deal's reason reads its label and whether it is a data-quality reason here
create or replace function cma.deal_reasons_of(p_tenant_id uuid)
returns table (value text, label text, is_data_quality boolean, sort_order integer)
language sql stable
as $$
  select distinct on (cr.value) cr.value, cr.label, cr.is_data_quality, cr.sort_order
  from cma.connection_reason cr
  where cr.tenant_id = p_tenant_id and cr.record_type = 'deal'
  order by cr.value, cr.status = 'active' desc, cr.connection_id
$$;

-- The state of the tenant's reason field of a record type across its connections (cma.reason_state_of): enumeration when one
-- connection stores reasons, else refused, else unchecked, else none
create or replace function cma.reason_field_state_of(p_tenant_id uuid, p_record_type text)
returns text
language sql stable
as $$
  select coalesce((select s from (select cma.reason_state_of(f.source_property, f.source_type) as s
                                  from cma.connection_field f
                                  where f.tenant_id = p_tenant_id and f.entity = p_record_type and f.field = 'reason') x
                   order by array_position(array['enumeration', 'refused', 'unchecked'], s) limit 1), 'none')
$$;

-- The figures of a set of lost deals: lost, with a reason, without one, data quality (the catalog flags the reason),
-- real (a reason that is no data-quality reason)
create or replace function cma.lost_figures_from(p_tenant_id uuid, p_rows cma.funnel_deal[])
returns jsonb
language sql stable
as $$
  with r as (
    select x.reason, coalesce(c.is_data_quality, false) as dq
    from unnest(coalesce(p_rows, '{}')) x
    left join cma.deal_reasons_of(p_tenant_id) c on c.value = x.reason
  )
  select jsonb_build_object(
    'lost', count(*), 'with_reason', count(r.reason), 'no_reason', count(*) filter (where r.reason is null),
    'data_quality', count(*) filter (where r.reason is not null and r.dq), 'real', count(*) filter (where r.reason is not null and not r.dq))
  from r
$$;

-- The lost deals of the period (p_rows) per reason, market, source channel and day or ISO week: the real reasons with
-- their share of the real lost deals, by count then label; the data-quality reasons apart with their share of every
-- lost deal; no reason; per market and per source channel the counts and the top 3 real reasons; per day or week (the
-- week's Monday) the counts and every real reason's count; the lost deals without a reason, the newest close first,
-- p_limit of them with the total, ids, the market and the link only
create or replace function cma.lost_reasons_from(p_tenant_id uuid, p_rows cma.funnel_deal[], p_group text, p_limit integer)
returns jsonb
language sql stable
as $$
  with k as materialized (
    select x.*, c.label as reason_label, c.sort_order as reason_order,
           case when x.reason is null then 'none' when coalesce(c.is_data_quality, false) then 'data_quality' else 'real' end as kind,
           case p_group when 'week' then date_trunc('week', x.closed_date)::date else x.closed_date end as period_key
    from unnest(coalesce(p_rows, '{}')) x
    left join cma.deal_reasons_of(p_tenant_id) c on c.value = x.reason
  ),
  tot as (
    select count(*) filter (where k.kind = 'real') as real_n, count(*) as all_n from k
  ),
  rr as (
    select k.reason, max(coalesce(k.reason_label, k.reason)) as label, k.kind, count(*) as n, min(k.reason_order) as ord
    from k where k.kind <> 'none' group by k.reason, k.kind
  ),
  -- per market and per source channel: the real reasons' counts, ranked
  gm as (
    select k.market as g, k.reason, max(coalesce(k.reason_label, k.reason)) as label, count(*) as n,
           row_number() over (partition by k.market order by count(*) desc, max(coalesce(k.reason_label, k.reason)), k.reason) as rn
    from k where k.kind = 'real' group by k.market, k.reason
  ),
  gs as (
    select k.source_channel as g, k.reason, max(coalesce(k.reason_label, k.reason)) as label, count(*) as n,
           row_number() over (partition by k.source_channel order by count(*) desc, max(coalesce(k.reason_label, k.reason)), k.reason) as rn
    from k where k.kind = 'real' group by k.source_channel, k.reason
  ),
  nr as (
    select k.*, row_number() over (order by k.closed_at desc, k.deal_source_id) as ord from k where k.kind = 'none'
  )
  select jsonb_build_object(
    'reasons', coalesce((select jsonb_agg(jsonb_build_object('value', rr.reason, 'label', rr.label, 'deals', rr.n,
                                                             'share', round(rr.n::numeric / nullif(tot.real_n, 0), 4))
                                          order by rr.n desc, rr.label, rr.reason)
                         from rr cross join tot where rr.kind = 'real'), '[]'::jsonb),
    'data_quality_reasons', coalesce((select jsonb_agg(jsonb_build_object('value', rr.reason, 'label', rr.label, 'deals', rr.n,
                                                                          'share', round(rr.n::numeric / nullif(tot.all_n, 0), 4))
                                                       order by rr.n desc, rr.label, rr.reason)
                                      from rr cross join tot where rr.kind = 'data_quality'), '[]'::jsonb),
    'no_reason', jsonb_build_object('deals', (select count(*) from k where k.kind = 'none'),
                                    'share', (select round(count(*) filter (where k.kind = 'none')::numeric / nullif(count(*), 0), 4) from k)),
    'by_market', coalesce((select jsonb_agg(jsonb_build_object(
                                    'market', m.market, 'lost', m.lost, 'real', m.real_n, 'no_reason', m.none_n, 'data_quality', m.dq_n,
                                    'top', coalesce((select jsonb_agg(jsonb_build_object('value', gm.reason, 'label', gm.label, 'deals', gm.n) order by gm.rn)
                                                     from gm where gm.g = m.market and gm.rn <= 3), '[]'::jsonb))
                                  order by m.market = 'unknown', m.market)
                           from (select k.market, count(*) as lost, count(*) filter (where k.kind = 'real') as real_n,
                                        count(*) filter (where k.kind = 'none') as none_n, count(*) filter (where k.kind = 'data_quality') as dq_n
                                 from k group by k.market) m), '[]'::jsonb),
    'by_source', coalesce((select jsonb_agg(jsonb_build_object(
                                    'source_channel', c.source_channel, 'lost', c.lost, 'real', c.real_n, 'no_reason', c.none_n, 'data_quality', c.dq_n,
                                    'top', coalesce((select jsonb_agg(jsonb_build_object('value', gs.reason, 'label', gs.label, 'deals', gs.n) order by gs.rn)
                                                     from gs where gs.g is not distinct from c.source_channel and gs.rn <= 3), '[]'::jsonb))
                                  order by c.source_channel nulls last)
                           from (select k.source_channel, count(*) as lost, count(*) filter (where k.kind = 'real') as real_n,
                                        count(*) filter (where k.kind = 'none') as none_n, count(*) filter (where k.kind = 'data_quality') as dq_n
                                 from k group by k.source_channel) c), '[]'::jsonb),
    'by_period', coalesce((select jsonb_agg(jsonb_build_object(
                                    'key', p.period_key, 'lost', p.lost, 'real', p.real_n, 'no_reason', p.none_n, 'data_quality', p.dq_n,
                                    'reasons', coalesce((select jsonb_object_agg(z.reason, z.n)
                                                         from (select k2.reason, count(*) as n from k k2
                                                               where k2.period_key = p.period_key and k2.kind = 'real' group by k2.reason) z), '{}'::jsonb))
                                  order by p.period_key)
                           from (select k.period_key, count(*) as lost, count(*) filter (where k.kind = 'real') as real_n,
                                        count(*) filter (where k.kind = 'none') as none_n, count(*) filter (where k.kind = 'data_quality') as dq_n
                                 from k group by k.period_key) p), '[]'::jsonb),
    'list', jsonb_build_object(
      'total', (select count(*) from nr),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('deal_id', nr.deal_id, 'deal_source_id', nr.deal_source_id,
                                                            'record_url', cma.record_url(nr.connection_id, 'deal', nr.deal_source_id),
                                                            'pipeline_label', nr.pipeline_label, 'market', nr.market,
                                                            'created_at', nr.created_at, 'closed_at', nr.closed_at)
                                         order by nr.ord)
                        from nr where nr.ord <= p_limit), '[]'::jsonb)))
$$;

-- Lost reasons of an explicit tenant as of p_now in one pass, as one JSON object: the figures of the period and of the
-- previous span like for like, the reasons (cma.lost_reasons_from), the state of the reason field, the filter lists,
-- the previous span and the history start
create or replace function cma.lost_reasons_page_of(p_tenant_id uuid, p_from date, p_to date, p_pipeline text, p_market text,
                                                    p_source_channel text, p_group text, p_rows integer, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone  text;
  v_prev  record;
  v_until time;
  v_all   cma.funnel_deal[];
  v_rows  cma.funnel_deal[];
  v_lost  cma.funnel_deal[];
begin
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  select * into v_prev from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now);
  v_until := (v_prev.until at time zone v_zone)::time;
  v_all := cma.funnel_rows_of(p_tenant_id, p_now);
  v_rows := cma.funnel_filter(v_all, p_pipeline, p_market, p_source_channel);
  v_lost := cma.funnel_lost_in(v_rows, p_from, p_to, null);
  return jsonb_build_object(
    'current', cma.lost_figures_from(p_tenant_id, v_lost),
    'previous', cma.lost_figures_from(p_tenant_id, cma.funnel_lost_in(v_rows, v_prev.prev_from, v_prev.prev_to, v_until)),
    'previous_from', v_prev.prev_from, 'previous_to', v_prev.prev_to, 'previous_partial', v_prev.until is not null,
    'reason_state', cma.reason_field_state_of(p_tenant_id, 'deal'),
    'history_start', cma.funnel_history_start_of(p_tenant_id, v_all) -> 'deals')
    || cma.lost_reasons_from(p_tenant_id, v_lost, p_group, p_rows)
    || cma.funnel_filter_lists_from(v_all);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Cancellations: the requests of the cancellation kind
-- ---------------------------------------------------------------------------------------------
-- The records of the tenant's cancellation kind (reports.cancellation_kind) created in [p_from, p_to) (null: since
-- intake.start_date): of the kind's record type, not deleted, of a counted pipeline (a pipeline not yet seen counts),
-- created on or after intake.start_date, matched by an active rule of the active kind (cma.kind_rule_matches); with the
-- market as 0007d's rule gives it (the record's own value, else its primary contact's country, each only when it names
-- a catalog market, unknown otherwise; cma.market_code_of once per distinct value), the reason, the creation and close
create or replace function cma.cancellation_records_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  record_id          uuid,
  connection_id      uuid,
  source_system      text,
  record_type        text,
  source_id          text,
  pipeline_id        text,
  pipeline_label     text,
  stage_id           text,
  market             text,
  reason             text,
  is_closed          boolean,
  created_at         timestamptz,
  created_date       date,
  created_time       time,
  closed_at          timestamptz,
  kind_key           text
)
language sql stable
as $$
  with s as materialized (
    select t.timezone as zone, cma.setting_of(t.id, 'intake.start_date')::date as start_date,
           k.key as kind_key, k.record_type
    from cma.tenant t
    join cma.record_kind k on k.tenant_id = t.id and k.key = cma.setting_of(t.id, 'reports.cancellation_kind') and k.status = 'active'
    where t.id = p_tenant_id
  ),
  rules as materialized (
    select r.connection_id, r.pipeline_id, r.category
    from cma.connection_record_kind r cross join s
    where r.tenant_id = p_tenant_id and r.kind_key = s.kind_key and r.status = 'active'
  ),
  x as materialized (
    select d.*
    from cma.crm_record d
    cross join s
    left join cma.connection_pipeline p
      on p.tenant_id = d.tenant_id and p.connection_id = d.connection_id and p.record_type = d.record_type and p.source_pipeline_id = d.pipeline_id
    where d.tenant_id = p_tenant_id and d.record_type = s.record_type and d.source_deleted_at is null
      and coalesce(p.is_counted, true)
      and d.source_created_at >= (s.start_date::timestamp at time zone s.zone)
      and d.source_created_at >= coalesce(p_from, '-infinity'::timestamptz)
      and d.source_created_at < coalesce(p_to, 'infinity'::timestamptz)
      and exists (select 1 from rules r where r.connection_id = d.connection_id and cma.kind_rule_matches(r.pipeline_id, r.category, d.pipeline_id, d.category))
  ),
  code_of as materialized (
    select coalesce(jsonb_object_agg(v.value, cma.market_code_of(p_tenant_id, v.value)), '{}'::jsonb) as m
    from (select x.market as value from x
          union
          select c.country from x join cma.crm_contact c
            on c.tenant_id = x.tenant_id and c.connection_id = x.connection_id and c.source_id = x.contact_source_id) v
    where v.value is not null
  )
  select x.id, x.connection_id, x.source_system, x.record_type, x.source_id, x.pipeline_id, coalesce(p.label, x.pipeline_id), x.stage_id,
         coalesce(code_of.m ->> x.market, code_of.m ->> cc.country, 'unknown'), x.reason, coalesce(x.is_closed, false),
         x.source_created_at, (x.source_created_at at time zone s.zone)::date, (x.source_created_at at time zone s.zone)::time,
         x.closed_at, s.kind_key
  from x
  cross join s
  cross join code_of
  left join cma.connection_pipeline p
    on p.tenant_id = x.tenant_id and p.connection_id = x.connection_id and p.record_type = x.record_type and p.source_pipeline_id = x.pipeline_id
  left join cma.crm_contact cc on cc.tenant_id = x.tenant_id and cc.connection_id = x.connection_id and cc.source_id = x.contact_source_id
$$;

-- The figures of a set of requests in [p_from, p_to] (the last date cut at p_until): requests, open now, closed now, the
-- median days from the creation to the close of the closed ones
create or replace function cma.cancellation_figures_from(p_rows jsonb, p_from date, p_to date, p_until time)
returns jsonb
language sql immutable
as $$
  with r as (
    select (x ->> 'created_date')::date as d, (x ->> 'created_time')::time as t, (x ->> 'is_closed')::boolean as closed,
           (x ->> 'days_to_close')::numeric as days
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
  )
  select jsonb_build_object(
    'requests', count(*) filter (where cma.in_period(r.d, r.t, p_from, p_to, p_until)),
    'open', count(*) filter (where cma.in_period(r.d, r.t, p_from, p_to, p_until) and not r.closed),
    'closed', count(*) filter (where cma.in_period(r.d, r.t, p_from, p_to, p_until) and r.closed),
    'median_days_to_close', round((percentile_cont(0.5) within group (order by r.days)
                                   filter (where cma.in_period(r.d, r.t, p_from, p_to, p_until) and r.closed and r.days is not null))::numeric, 1))
  from r
$$;

-- Cancellations of an explicit tenant as of p_now in one pass, as one JSON object: whether a kind is set (kind, with
-- its key, label, record type and status), the figures of the period and of the previous span like for like (the
-- market filter applied), per market, per day or ISO week (the week's Monday) and market, the reasons when the kind's
-- record type maps one (reason_state, cma.reason_state_of), the newest requests with their links (p_limit, the
-- total), the markets, the previous span and the history start (the later of intake.start_date and the earliest
-- request's creation date)
create or replace function cma.cancellations_page_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_group text,
                                                     p_limit integer, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone   text;
  v_prev   record;
  v_until  time;
  v_kind   jsonb;
  v_type   text;
  v_all    jsonb;
  v_cur    jsonb;
  v_first  date;
begin
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  select * into v_prev from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now);
  v_until := (v_prev.until at time zone v_zone)::time;
  select jsonb_build_object('key', k.key, 'label', k.label, 'record_type', k.record_type, 'status', k.status), k.record_type
    into v_kind, v_type
  from cma.record_kind k where k.tenant_id = p_tenant_id and k.key = cma.setting_of(p_tenant_id, 'reports.cancellation_kind');
  -- the requests from the previous span's first date to the period's last, in one pass, with the market filter
  select coalesce(jsonb_agg(jsonb_build_object(
           'record_id', c.record_id, 'connection_id', c.connection_id, 'record_type', c.record_type, 'source_id', c.source_id,
           'pipeline_label', c.pipeline_label, 'market', c.market, 'reason', c.reason, 'is_closed', c.is_closed, 'created_at', c.created_at,
           'created_date', c.created_date, 'created_time', c.created_time, 'closed_at', c.closed_at,
           'days_to_close', case when c.is_closed and c.closed_at is not null
                                 then round((extract(epoch from c.closed_at - c.created_at) / 86400.0)::numeric, 2) end)
           order by c.created_at desc, c.source_id), '[]'::jsonb)
    into v_all
  from cma.cancellation_records_of(p_tenant_id, least(v_prev.prev_from, p_from)::timestamp at time zone v_zone,
                                   (p_to + 1)::timestamp at time zone v_zone) c
  where p_market is null or c.market = p_market;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_cur
  from jsonb_array_elements(v_all) x where cma.in_period((x ->> 'created_date')::date, (x ->> 'created_time')::time, p_from, p_to, null);
  select (min(c.created_at) at time zone v_zone)::date into v_first from cma.cancellation_records_of(p_tenant_id, null, null) c;
  return jsonb_build_object(
    'kind', v_kind,
    'current', cma.cancellation_figures_from(v_cur, p_from, p_to, null),
    'previous', cma.cancellation_figures_from(v_all, v_prev.prev_from, v_prev.prev_to, v_until),
    'previous_from', v_prev.prev_from, 'previous_to', v_prev.prev_to, 'previous_partial', v_prev.until is not null,
    'by_market', coalesce((select jsonb_agg(cma.cancellation_figures_from(m.rows, p_from, p_to, null) || jsonb_build_object('market', m.market)
                                            order by m.market = 'unknown', m.market)
                           from (select x ->> 'market' as market, jsonb_agg(x) as rows from jsonb_array_elements(v_cur) x group by 1) m), '[]'::jsonb),
    'by_period', coalesce((select jsonb_agg(cma.cancellation_figures_from(g.rows, p_from, p_to, null)
                                            || jsonb_build_object('key', g.k, 'market', g.market)
                                            order by g.k, g.market = 'unknown', g.market)
                           from (select case p_group when 'week' then date_trunc('week', (x ->> 'created_date')::date)::date
                                                     else (x ->> 'created_date')::date end as k,
                                        x ->> 'market' as market, jsonb_agg(x) as rows
                                 from jsonb_array_elements(v_cur) x group by 1, 2) g), '[]'::jsonb),
    'reason_state', case when v_type is null then 'none' else cma.reason_field_state_of(p_tenant_id, v_type) end,
    'reasons', coalesce((select jsonb_agg(jsonb_build_object('value', z.reason, 'label', coalesce(z.label, z.reason), 'requests', z.n)
                                          order by z.reason is null, z.n desc, z.label, z.reason)
                         from (select y.reason, y.n,
                                      (select max(cr.label) from cma.connection_reason cr
                                       where cr.tenant_id = p_tenant_id and cr.record_type = v_type and cr.value = y.reason) as label
                               from (select x ->> 'reason' as reason, count(*) as n from jsonb_array_elements(v_cur) x group by 1) y) z), '[]'::jsonb),
    'list', jsonb_build_object(
      'total', jsonb_array_length(v_cur),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('record_id', x -> 'record_id', 'source_id', x -> 'source_id',
                                                            'record_url', cma.record_url((x ->> 'connection_id')::uuid, x ->> 'record_type', x ->> 'source_id'),
                                                            'pipeline_label', x -> 'pipeline_label', 'market', x -> 'market',
                                                            'is_closed', x -> 'is_closed', 'created_at', x -> 'created_at', 'closed_at', x -> 'closed_at',
                                                            'reason', x -> 'reason')
                                         order by o.n)
                        from jsonb_array_elements(v_cur) with ordinality o(x, n) where o.n <= p_limit), '[]'::jsonb)),
    'markets', coalesce((select jsonb_agg(m order by m = 'unknown', m)
                         from (select distinct x ->> 'market' as m from jsonb_array_elements(v_all) x) q), '[]'::jsonb),
    'history_start', case when v_first is not null then greatest(cma.setting_of(p_tenant_id, 'intake.start_date')::date, v_first) end);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Deals per person (behind reports.per_person: deals)
-- ---------------------------------------------------------------------------------------------
-- The figures of a set of decided deals: won, lost, and the amount won per currency (never summed across currencies;
-- a deal without an amount counts, adds nothing, and is counted apart)
create or replace function cma.deal_person_figures_from(p_rows cma.funnel_deal[])
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'won', (select count(*) from unnest(coalesce(p_rows, '{}')) x where x.stage_outcome = 'won'),
    'lost', (select count(*) from unnest(coalesce(p_rows, '{}')) x where x.stage_outcome = 'lost'),
    'won_without_amount', (select count(*) from unnest(coalesce(p_rows, '{}')) x where x.stage_outcome = 'won' and x.amount is null),
    'amounts', coalesce((select jsonb_agg(jsonb_build_object('currency', a.currency, 'amount', a.amount, 'deals', a.n) order by a.currency nulls last)
                         from (select x.currency, sum(x.amount) as amount, count(*) as n from unnest(coalesce(p_rows, '{}')) x
                               where x.stage_outcome = 'won' and x.amount is not null group by x.currency) a), '[]'::jsonb))
$$;

-- Deals per person of an explicit tenant as of p_now, as one JSON object: the deals won or lost in the period (by the
-- close's business date) per deal owner by name, never ranked (rows: user_id, display_name and the figures); the deals of
-- an owner id without a person, or without an owner, as one not-linked row with how many owner ids that is, never which;
-- the total; the filter lists
create or replace function cma.deals_per_person_of(p_tenant_id uuid, p_from date, p_to date, p_pipeline text, p_market text,
                                                   p_source_channel text, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_all  cma.funnel_deal[];
  v_cur  cma.funnel_deal[];
begin
  v_all := cma.funnel_rows_of(p_tenant_id, p_now);
  select coalesce(array_agg(x), '{}') into v_cur
  from unnest(cma.funnel_filter(v_all, p_pipeline, p_market, p_source_channel)) x
  where x.stage_outcome in ('won', 'lost') and x.closed_date is not null and cma.in_period(x.closed_date, x.closed_time, p_from, p_to, null);
  return jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', p.uid, 'display_name', p.uname) || p.f order by p.uname, p.uid)
      from (select u.id as uid, u.display_name as uname, cma.deal_person_figures_from(array_agg(r)) as f
            from unnest(v_cur) r
            join cma.app_user u on u.tenant_id = p_tenant_id and u.id = r.owner_user_id
            group by u.id, u.display_name) p), '[]'::jsonb),
    'not_linked', (
      select jsonb_build_object('unlinked_owners', count(distinct r.owner_ref)) || cma.deal_person_figures_from(array_agg(r))
      from unnest(v_cur) r
      left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = r.owner_user_id
      where u.id is null
      having count(*) > 0),
    'total', cma.deal_person_figures_from(v_cur))
    || cma.funnel_filter_lists_from(v_all);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. The application's reads (permission checked, parameters checked, current tenant, row-level security)
-- ---------------------------------------------------------------------------------------------
-- Reports, Funnel: the funnel in one read (reports.view or performance.team; at most 92 days)
create or replace function cma.deal_funnel_page(p_from date, p_to date, p_pipeline text default null, p_market text default null,
                                                p_source_channel text default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.funnel_filters_check(p_market, p_pipeline, p_source_channel, null);
  return cma.deal_funnel_page_of(v_tenant, p_from, p_to, p_pipeline, p_market, p_source_channel, now());
end
$$;

-- Reports, Funnel: lost reasons in one read (reports.view or performance.team; at most 92 days; grouped by day or week),
-- the list capped by follow_up.list_rows
create or replace function cma.lost_reasons_page(p_from date, p_to date, p_pipeline text default null, p_market text default null,
                                                 p_source_channel text default null, p_group text default 'week')
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  if p_group is null then
    raise exception 'group by day or week' using errcode = 'CMA04';
  end if;
  perform cma.funnel_filters_check(p_market, p_pipeline, p_source_channel, p_group);
  return cma.lost_reasons_page_of(v_tenant, p_from, p_to, p_pipeline, p_market, p_source_channel, p_group,
                                  least(500, greatest(1, cma.setting_of(v_tenant, 'follow_up.list_rows')::integer)), now());
end
$$;

-- Reports, Cancellations in one read (reports.view or performance.team; at most 92 days; grouped by day or week), the
-- list capped by follow_up.list_rows
create or replace function cma.cancellations_page(p_from date, p_to date, p_market text default null, p_group text default 'week')
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  if p_group is null then
    raise exception 'group by day or week' using errcode = 'CMA04';
  end if;
  perform cma.funnel_filters_check(p_market, null, null, p_group);
  return cma.cancellations_page_of(v_tenant, p_from, p_to, p_market, p_group,
                                   least(500, greatest(1, cma.setting_of(v_tenant, 'follow_up.list_rows')::integer)), now());
end
$$;

-- Reports, Funnel: deals per person in one read: performance.team, and the tenant's reports.per_person holding deals
-- (cma.assert_per_person; CMA06 otherwise); at most 92 days
create or replace function cma.deals_per_person_page(p_from date, p_to date, p_pipeline text default null, p_market text default null,
                                                     p_source_channel text default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_per_person('deals');
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.funnel_filters_check(p_market, p_pipeline, p_source_channel, null);
  return cma.deals_per_person_of(v_tenant, p_from, p_to, p_pipeline, p_market, p_source_channel, now());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.kind_rule_matches(text,text,text,text)',
    'cma.record_kind_of(uuid,uuid,text,text,text)',
    'cma.set_record_kind(text,text,text,integer)',
    'cma.set_record_kind_status(text,text)',
    'cma.set_record_kind_rule(uuid,text,text,text,boolean)',
    'cma.record_kinds()',
    'cma.is_per_person_list(text)',
    'cma.set_connection_field(uuid,text,text,text,text,smallint)',
    'cma.ingest_upsert_records(uuid,jsonb)',
    'cma.ingest_upsert_reasons(uuid,jsonb)',
    'cma.set_reason_data_quality(uuid,text,text,boolean)',
    'cma.reason_state_of(text,text)',
    'cma.connection_config(uuid)',
    'cma.funnel_deals_of(uuid,timestamptz)',
    'cma.funnel_rows_of(uuid,timestamptz)',
    'cma.in_period(date,time,date,date,time)',
    'cma.funnel_filters_check(text,text,text,text)',
    'cma.funnel_filter(cma.funnel_deal[],text,text,text)',
    'cma.funnel_filter_lists_from(cma.funnel_deal[])',
    'cma.funnel_figures_from(cma.funnel_deal[],date,date,time)',
    'cma.funnel_pipelines_from(cma.funnel_deal[],date,date,date,date,time)',
    'cma.funnel_stages_of(uuid,cma.funnel_deal[],text,date,date,date,date,time)',
    'cma.funnel_history_start_of(uuid,cma.funnel_deal[])',
    'cma.deal_funnel_page_of(uuid,date,date,text,text,text,timestamptz)',
    'cma.funnel_lost_in(cma.funnel_deal[],date,date,time)',
    'cma.deal_reasons_of(uuid)',
    'cma.reason_field_state_of(uuid,text)',
    'cma.lost_figures_from(uuid,cma.funnel_deal[])',
    'cma.lost_reasons_from(uuid,cma.funnel_deal[],text,integer)',
    'cma.lost_reasons_page_of(uuid,date,date,text,text,text,text,integer,timestamptz)',
    'cma.cancellation_records_of(uuid,timestamptz,timestamptz)',
    'cma.cancellation_figures_from(jsonb,date,date,time)',
    'cma.cancellations_page_of(uuid,date,date,text,text,integer,timestamptz)',
    'cma.deal_person_figures_from(cma.funnel_deal[])',
    'cma.deals_per_person_of(uuid,date,date,text,text,text,timestamptz)',
    'cma.deal_funnel_page(date,date,text,text,text)',
    'cma.lost_reasons_page(date,date,text,text,text,text)',
    'cma.cancellations_page(date,date,text,text)',
    'cma.deals_per_person_page(date,date,text,text,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 11. Reporting views
-- ---------------------------------------------------------------------------------------------
-- Every sales deal since each tenant's intake start with its stage times, for readers (so the funnel can be cut in
-- BigQuery): one row per deal and stage with a time (the stage, its entry and exit), a deal without any as one row
-- without a stage; ids, dates, the stages, the outcomes, the reason value and the market only. Over a SECURITY DEFINER
-- function in cma_read (owned by cma_owner, search path pinned, executable by readers only) that reads every tenant the
-- reader sees
create or replace function cma_read.deal_funnel_rows_of()
returns table (tenant_id uuid, deal_id uuid, connection_id uuid, deal_source_id text, pipeline_id text, current_stage_id text,
               created_at timestamptz, closed_at timestamptz, stage_outcome text, outcome text, reason text, market text,
               stage_id text, entered_at timestamptz, exited_at timestamptz)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, d.deal_id, d.connection_id, d.deal_source_id, d.pipeline_id, d.stage_id, d.created_at, d.closed_at, d.stage_outcome,
         d.outcome, d.reason, d.market, rs.source_stage_id, rs.entered_at, rs.exited_at
  from cma.tenant t
  cross join lateral cma.funnel_deals_of(t.id, now()) d
  left join cma.crm_record_stage rs
    on rs.tenant_id = t.id and rs.connection_id = d.connection_id and rs.record_type = 'deal' and rs.source_id = d.deal_source_id
  where cma_read.reader_sees(t.id)
$$;

-- Every request of each tenant's cancellation kind since its intake start, for readers: ids, the kind, dates, the
-- stage, the reason value and the market only
create or replace function cma_read.cancellation_rows_of()
returns table (tenant_id uuid, kind_key text, record_id uuid, connection_id uuid, record_type text, source_id text, pipeline_id text,
               stage_id text, created_at timestamptz, is_closed boolean, closed_at timestamptz, reason text, market text)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, c.kind_key, c.record_id, c.connection_id, c.record_type, c.source_id, c.pipeline_id, c.stage_id, c.created_at, c.is_closed,
         c.closed_at, c.reason, c.market
  from cma.tenant t
  cross join lateral cma.cancellation_records_of(t.id, null, null) c
  where cma_read.reader_sees(t.id)
$$;

do $$
declare
  f text;
begin
  foreach f in array array['cma_read.deal_funnel_rows_of()', 'cma_read.cancellation_rows_of()'] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_readonly', f);
  end loop;
end
$$;

create or replace view cma_read.deal_funnel_rows as
  select * from cma_read.deal_funnel_rows_of();

create or replace view cma_read.cancellation_rows as
  select * from cma_read.cancellation_rows_of();

create or replace view cma_read.connection_reason as
  select tenant_id, connection_id, record_type, value, label, sort_order, is_data_quality, status, refreshed_at, updated_at
  from cma.connection_reason
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.record_kind as
  select id, tenant_id, key, label, record_type, status, sort_order, created_at, updated_at
  from cma.record_kind
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.connection_record_kind as
  select id, tenant_id, connection_id, kind_key, pipeline_id, category, status, created_at, updated_at
  from cma.connection_record_kind
  where cma_read.reader_sees(tenant_id);

-- As 0007, with the reason last
create or replace view cma_read.crm_record_detail as
  select id, tenant_id, connection_id, record_type, source_id, amount, currency, source_channel, category, reason
  from cma.crm_record
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 12. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zb', 'Reasons, record kinds and the funnel reports: connection_field reason for deals and tickets with the source type checked (an enumeration only), crm_record.reason, the reason catalog cma.connection_reason with is_data_quality kept by every refresh (cma.ingest_upsert_reasons, cma.set_reason_data_quality); record kinds cma.record_kind and their rules cma.connection_record_kind by pipeline and category (cma.kind_rule_matches, cma.record_kind_of, the configuration functions, cma.record_kinds); the settings reports.cancellation_kind and deals in reports.per_person; the funnel deals over 0008z''s sales deals (cma.funnel_deals_of); the page reads cma.deal_funnel_page, lost_reasons_page, cancellations_page and deals_per_person_page; the reporting views deal_funnel_rows, cancellation_rows, connection_reason, record_kind, connection_record_kind, and reason on crm_record_detail')
on conflict (version) do nothing;

commit;
reset role;
