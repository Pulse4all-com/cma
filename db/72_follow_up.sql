-- =============================================================================================
-- 72_follow_up.sql: addition 0008o, the follow-up layer (open leads, tickets against their SLA, open
-- tasks, the summary, per person, the person's own; four data-quality changes)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 70_crm_tasks.sql (0008n). Rerunnable, forward-only, in one transaction. Run as your own IAM login,
-- dev first, then prod, then 02_seed_<customer>.sql again (the follow-up settings as seed values);
-- then 73_verify_follow_up.sql (dev), then 41_verify_lead_metrics.sql and 69_verify_email_activity.sql
-- (dev) again (unchanged).
--
-- Night run N16-B (README Decision log, 16 October 2026; backlog CMA-015, CMA-036, CMA-045, CMA-046,
-- CMA-050, CMA-052): what is waiting right now, for Reports → Follow-up, Welcome's Needs attention, the
-- Live board's tiles and the person's own Waiting for you. Everything is tenant configuration: the SLA
-- in business minutes of the ticket's market (a tenant default and a per-pipeline override), the share
-- of it that means at risk, the age buckets of open leads in business days, the callback window; the
-- lead target is 0007d's speed_to_lead.target_minutes, never a second one. Every read is a function
-- of an explicit tenant (cma.*_of, in the caller's rights) with the application's wrapper that checks
-- the permission and reads the current tenant under row-level security, as 0007d and 0008i do, and a
-- reader view in cma_read (ids, codes and counts only).
--
-- What it adds
--   settings              tickets.sla_minutes (240), tickets.sla_warning_pct (75),
--                         leads.age_buckets_business_days ('1,2,5'), tasks.callback_window_minutes (240);
--                         cma.check_tenant_setting() checks the four (0008m's branches unchanged)
--   connection_pipeline   sla_minutes, nullable (null: the tenant default); cma.set_pipeline_sla()
--                         (tenant.configure); the reader view cma_read.connection_pipeline_sla
--   cma.open_leads_of     the open lead deals not called (speed_to_lead_of's not_called_open), each with
--                         the owner (person or not mapped), market, pipeline, created, business minutes
--                         waited, the age bucket in business days from the setting, past the target or
--                         not, and the last linked call
--   cma.open_tickets_of   the open tickets of counted pipelines with pipeline, stage, market, owner,
--                         created, business minutes open (null, no business hours, for an unknown
--                         market), the SLA in force, the state ok, at_risk, breached or no_hours and the
--                         minutes to breach; sorted by minutes to breach
--   cma.open_tasks_of     the open tasks (status not done by the catalog, type counted) with type,
--                         priority, owner, due, the state overdue, today, later or none against the
--                         tenant's business date, the record they belong to (deal, ticket; never the
--                         contact's details) and the market
--   cma.follow_up_summary_of, cma.follow_up_by_owner_of, cma.my_follow_up_of   counts only; per mapped
--                         person with one not-mapped row; the caller's own rows as JSON
--   data quality          telephony_call_unlinked skips outbound calls never connected and untagged
--                         when the telephony connection's setting dq_unlinked_skip is
--                         outbound_unanswered_untagged (the default for a connection of kind telephony);
--                         ticket_no_owner and ticket_no_market (open tickets, per pipeline) once the
--                         tenant has configured ticket SLAs; crm_task_owner_unlinked (open tasks whose
--                         owner maps to no person) once the tenant has tasks
--   wrappers              cma.open_leads(), open_tickets(), open_tasks() (reports.view, performance.team or
--                         monitoring.live); follow_up_summary() (monitoring.live, performance.team or
--                         workday.team); follow_up_by_owner() (performance.team only: per-person figures
--                         sit under the employee-monitoring point); my_follow_up() (leads.accept or
--                         workday.own)
--   reporting views       cma_read.open_lead, open_ticket, open_task, follow_up_summary,
--                         follow_up_by_owner (ids only), dq_ticket_no_owner, dq_ticket_no_market,
--                         dq_crm_task_owner_unlinked, connection_pipeline_sla
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
  if not exists (select 1 from cma.schema_migration where version = '0008n') then
    raise exception 'addition 0008n (70_crm_tasks.sql) must run before 0008o';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('tickets.sla_minutes',              'integer', null, '240',
     'A ticket is answered within this many business minutes of its market (four hours, KPI 9); a ticket pipeline can set its own'),
  ('tickets.sla_warning_pct',          'integer', null, '75',
     'An open ticket past this share of its SLA is at risk'),
  ('leads.age_buckets_business_days',  'text',    null, '1,2,5',
     'The edges, in business days, of the age buckets of open leads not called: increasing whole numbers, comma-separated'),
  ('tasks.callback_window_minutes',    'integer', null, '240',
     'A callback task counts as kept when a call to its contact starts within this many minutes before or after its due time (KPI 5)')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- Increasing whole numbers from 1, comma-separated without spaces, one to five of them
create or replace function cma.is_bucket_list(p_value text)
returns boolean
language sql immutable
as $$
  select p_value ~ '^[1-9][0-9]{0,3}(,[1-9][0-9]{0,3}){0,4}$'
     and not exists (select 1 from (select x::integer as e, ord from unnest(string_to_array(p_value, ',')) with ordinality as u(x, ord)) a
                     join (select x::integer as e, ord from unnest(string_to_array(p_value, ',')) with ordinality as u(x, ord)) b
                       on b.ord = a.ord + 1
                     where b.e <= a.e)
$$;

-- 0008m's checks, and the four follow-up settings
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
  if new.key = 'leads.age_buckets_business_days' then
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
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;
revoke execute on function cma.check_tenant_setting() from public;

-- ---------------------------------------------------------------------------------------------
-- 2. The SLA per pipeline
-- ---------------------------------------------------------------------------------------------
alter table cma.connection_pipeline add column if not exists sla_minutes integer;
alter table cma.connection_pipeline drop constraint if exists connection_pipeline_sla_minutes_check;
alter table cma.connection_pipeline add constraint connection_pipeline_sla_minutes_check check (sla_minutes between 1 and 100000);
comment on column cma.connection_pipeline.sla_minutes is 'The pipeline''s own SLA in business minutes of the record''s market; null: the tenant''s tickets.sla_minutes (0008o)';

-- One pipeline's SLA in business minutes, or null for the tenant default (tenant.configure). The
-- pipeline must exist in the connection's catalog (CMA02); 1 to 100000 (CMA04)
create or replace function cma.set_pipeline_sla(p_connection_id uuid, p_record_type text, p_pipeline_id text, p_sla_minutes integer)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_sla_minutes is not null and p_sla_minutes not between 1 and 100000 then
    raise exception 'an SLA is 1 to 100000 business minutes, or empty for the tenant default' using errcode = 'CMA04';
  end if;
  update cma.connection_pipeline p set sla_minutes = p_sla_minutes
  where p.tenant_id = v_tenant and p.connection_id = p_connection_id and p.record_type = p_record_type and p.source_pipeline_id = p_pipeline_id;
  if not found then
    raise exception 'no pipeline % of % on this connection', p_pipeline_id, p_record_type using errcode = 'CMA02';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Row types (the functions for the application and for readers share them)
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if to_regtype('cma.open_lead_row') is null then
    create type cma.open_lead_row as (
      tenant_id                 uuid,
      deal_id                   uuid,
      connection_id             uuid,
      deal_source_id            text,
      pipeline_id               text,
      pipeline_label            text,
      owner_user_id             uuid,
      owner_ref                 text,
      market                    text,
      created_at                timestamptz,
      waiting_business_seconds  integer,
      age_business_days         integer,
      bucket_from               integer,
      bucket_to                 integer,
      past_target               boolean,
      last_call_at              timestamptz,
      last_call_days            integer
    );
  end if;
  if to_regtype('cma.open_ticket_row') is null then
    create type cma.open_ticket_row as (
      tenant_id              uuid,
      ticket_id              uuid,
      connection_id          uuid,
      ticket_source_id       text,
      pipeline_id            text,
      pipeline_label         text,
      stage_id               text,
      stage_label            text,
      owner_user_id          uuid,
      owner_ref              text,
      market                 text,
      created_at             timestamptz,
      open_business_seconds  integer,
      sla_minutes            integer,
      sla_state              text,
      minutes_to_breach      integer
    );
  end if;
  if to_regtype('cma.open_task_row') is null then
    create type cma.open_task_row as (
      tenant_id         uuid,
      task_id           uuid,
      connection_id     uuid,
      task_source_id    text,
      type_ref          text,
      type_label        text,
      is_callback       boolean,
      priority_ref      text,
      status_ref        text,
      status_label      text,
      owner_user_id     uuid,
      owner_ref         text,
      market            text,
      due_at            timestamptz,
      due_state         text,
      record_type       text,
      record_source_id  text,
      created_at        timestamptz
    );
  end if;
  if to_regtype('cma.follow_up_summary_row') is null then
    create type cma.follow_up_summary_row as (
      tenant_id              uuid,
      leads_open_not_called  integer,
      leads_past_target      integer,
      tickets_at_risk        integer,
      tickets_breached       integer,
      tickets_without_owner  integer,
      tasks_overdue          integer,
      tasks_due_today        integer,
      tasks_unmapped_owner   integer
    );
  end if;
  if to_regtype('cma.follow_up_owner_row') is null then
    create type cma.follow_up_owner_row as (
      tenant_id                    uuid,
      owner_user_id                uuid,
      display_name                 text,
      open_leads                   integer,
      leads_past_target            integer,
      open_tickets                 integer,
      tickets_at_risk_or_breached  integer,
      tasks_overdue                integer,
      tasks_due_today              integer
    );
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Helpers for an explicit tenant
-- ---------------------------------------------------------------------------------------------
-- The person a source's owner id maps to (app_user_external_id, system <source system>_owner), or null
create or replace function cma.owner_user_of(p_tenant_id uuid, p_source_system text, p_owner_ref text)
returns uuid
language sql stable
as $$
  select x.user_id from cma.app_user_external_id x
  where x.tenant_id = p_tenant_id and x.system = p_source_system || '_owner' and x.external_id = p_owner_ref
  limit 1
$$;

-- Working days in a market between two instants: the dates after p_from's local date up to p_to's,
-- with office hours (the market's own, else *) and no holiday; 0 when p_to is on p_from's date or
-- earlier; null for an unknown market
create or replace function cma.business_days_of(p_tenant_id uuid, p_market text, p_from timestamptz, p_to timestamptz)
returns integer
language plpgsql stable
as $$
declare
  v_zone   text;
  v_sched  text;
  v_a      date;
  v_b      date;
begin
  if p_tenant_id is null or p_market is null or p_from is null or p_to is null then
    return null;
  end if;
  select m.time_zone into v_zone from cma.market m where m.tenant_id = p_tenant_id and m.code = p_market;
  if v_zone is null then
    return null;
  end if;
  v_a := (p_from at time zone v_zone)::date;
  v_b := (p_to at time zone v_zone)::date;
  if v_b <= v_a then
    return 0;
  end if;
  v_sched := case when exists (select 1 from cma.business_hours h where h.tenant_id = p_tenant_id and h.market = p_market)
                  then p_market else '*' end;
  return (
    select count(*)::integer
    from generate_series(v_a + 1, v_b, interval '1 day') g(ts)
    where exists (select 1 from cma.business_hours h
                  where h.tenant_id = p_tenant_id and h.market = v_sched and h.weekday = extract(isodow from g.ts::date))
      and not exists (select 1 from cma.business_holiday b
                      where b.tenant_id = p_tenant_id and b.market in (p_market, '*') and b.day = g.ts::date)
  );
end
$$;

-- The age bucket of a number of business days against the edges '1,2,5': from the previous edge (0
-- first) to the first edge at or above the days, the last bucket open (to null); null days give nulls
create or replace function cma.age_bucket_of(p_days integer, p_edges text, out bucket_from integer, out bucket_to integer)
language plpgsql immutable
as $$
declare
  v_prev integer := 0;
  v_edge integer;
begin
  if p_days is null then
    return;
  end if;
  for v_edge in select x::integer from unnest(string_to_array(regexp_replace(coalesce(p_edges, ''), '[[:space:]]', '', 'g'), ',')) x
                where x ~ '^[0-9]+$' order by x::integer loop
    if p_days <= v_edge then
      bucket_from := v_prev;
      bucket_to := v_edge;
      return;
    end if;
    v_prev := v_edge;
  end loop;
  bucket_from := v_prev;
  bucket_to := null;
end
$$;

-- A task's market: the associated deal's, else the ticket's (each its own market, else its contact's
-- country, 0007d), else the task's own contact's stored country (0008m's slots already chose it); null
-- when none names a catalog market
create or replace function cma.task_market_of(p_tenant_id uuid, p_connection_id uuid, p_deal_source_id text, p_ticket_source_id text,
                                              p_contact_source_id text)
returns text
language sql stable
as $$
  select coalesce(
    (select nullif(rm.code, 'unknown') from cma.crm_record d
     cross join lateral cma.record_market_of(p_tenant_id, d.connection_id, d.market, d.contact_source_id) rm
     where d.tenant_id = p_tenant_id and d.connection_id = p_connection_id and d.record_type = 'deal' and d.source_id = p_deal_source_id
       and d.source_deleted_at is null limit 1),
    (select nullif(rm.code, 'unknown') from cma.crm_record x
     cross join lateral cma.record_market_of(p_tenant_id, x.connection_id, x.market, x.contact_source_id) rm
     where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id and x.record_type = 'ticket' and x.source_id = p_ticket_source_id
       and x.source_deleted_at is null limit 1),
    (select cma.market_code_of(p_tenant_id, k.country) from cma.crm_contact k
     where k.tenant_id = p_tenant_id and k.connection_id = p_connection_id and k.source_id = p_contact_source_id limit 1))
$$;

-- True once the tenant has configured ticket SLAs (an own value of a tickets.* setting, or an SLA on a
-- pipeline): the ticket data-quality checks run from then on
create or replace function cma.follow_up_configured_of(p_tenant_id uuid)
returns boolean
language sql stable
as $$
  select exists (select 1 from cma.tenant_setting ts where ts.tenant_id = p_tenant_id and ts.key like 'tickets.%')
      or exists (select 1 from cma.connection_pipeline p where p.tenant_id = p_tenant_id and p.sla_minutes is not null)
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The reads of an explicit tenant
-- ---------------------------------------------------------------------------------------------
-- The open lead deals not called (0007d's rows with status not_called_open): the owner is the
-- deal's owner mapped to a person (speed_to_lead_of's agent, from the deal while no call exists); the
-- age in business days of the market since the deal was created, bucketed by the setting; past the
-- target when the target's business minutes have passed; the last call linked to the deal or its
-- contacts (any direction) and the days since it
create or replace function cma.open_leads_of(p_tenant_id uuid)
returns setof cma.open_lead_row
language sql stable
as $$
  with s as (
    select cma.setting_of(p_tenant_id, 'leads.age_buckets_business_days') as edges,
           greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min
  ),
  r as (
    select * from cma.speed_to_lead_of(p_tenant_id, null, null) x where x.status = 'not_called_open'
  )
  select p_tenant_id, r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label,
         r.agent_user_id, r.agent_ref, r.market, r.created_at, r.waiting_business_seconds,
         a.days, b.bucket_from, b.bucket_to,
         case when r.within_target is false then true when r.waiting_business_seconds is null then null else false end,
         lc.last_at,
         case when lc.last_at is not null then floor(extract(epoch from now() - lc.last_at) / 86400)::integer end
  from r
  cross join s
  join cma.lead_deals_of(p_tenant_id, null, null) d on d.deal_id = r.deal_id
  cross join lateral (select cma.business_days_of(p_tenant_id, nullif(r.market, 'unknown'), r.created_at, now()) as days) a
  cross join lateral cma.age_bucket_of(a.days, s.edges) b
  left join lateral (
    select max(c.effective_at) as last_at
    from cma.lead_calls_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts, d.created_at - make_interval(mins => s.pre_min)) c) lc on true
  order by r.waiting_business_seconds desc nulls last, r.created_at
$$;

-- The open tickets of counted pipelines (not closed by their stage, not deleted): the SLA in force is
-- the pipeline's own, else the tenant's; business minutes open in the ticket's market (0007d's market
-- rule: the ticket's own, else its contact's country); the state ok, at_risk (at or past the warning
-- share), breached (at or past the SLA) or no_hours (an unknown market: counted apart); the minutes to
-- breach, negative once breached. Sorted by the minutes to breach, no_hours last.
create or replace function cma.open_tickets_of(p_tenant_id uuid)
returns setof cma.open_ticket_row
language sql stable
as $$
  with s as (
    select greatest(1, cma.setting_of(p_tenant_id, 'tickets.sla_minutes')::integer) as sla_default,
           least(100, greatest(0, cma.setting_of(p_tenant_id, 'tickets.sla_warning_pct')::integer)) as warn_pct
  ),
  k as (
    select r.id, r.connection_id, r.source_system, r.source_id, r.pipeline_id, coalesce(p.label, r.pipeline_id) as pipeline_label,
           r.stage_id, coalesce(st.label, r.stage_id) as stage_label, r.owner_ref, r.source_created_at,
           coalesce(p.sla_minutes, s.sla_default) as sla, s.warn_pct, rm.code as market
    from cma.crm_record r
    cross join s
    left join cma.connection_pipeline p
      on p.tenant_id = r.tenant_id and p.connection_id = r.connection_id and p.record_type = r.record_type and p.source_pipeline_id = r.pipeline_id
    left join cma.connection_stage st
      on st.tenant_id = r.tenant_id and st.connection_id = r.connection_id and st.record_type = r.record_type
     and st.source_pipeline_id = r.pipeline_id and st.source_stage_id = r.stage_id
    cross join lateral cma.record_market_of(r.tenant_id, r.connection_id, r.market, r.contact_source_id) rm
    where r.tenant_id = p_tenant_id and r.record_type = 'ticket' and r.source_deleted_at is null
      and not coalesce(r.is_closed, false) and coalesce(p.is_counted, true)
  ),
  m as (
    select k.*, cma.business_seconds_of(p_tenant_id, nullif(k.market, 'unknown'), k.source_created_at, now()) as open_s from k
  )
  select p_tenant_id, m.id, m.connection_id, m.source_id, m.pipeline_id, m.pipeline_label, m.stage_id, m.stage_label,
         cma.owner_user_of(p_tenant_id, m.source_system, m.owner_ref), m.owner_ref, m.market, m.source_created_at,
         m.open_s, m.sla,
         case when m.open_s is null then 'no_hours'
              when m.open_s >= m.sla * 60 then 'breached'
              when m.open_s * 100 >= m.sla * 60 * m.warn_pct then 'at_risk'
              else 'ok' end,
         case when m.open_s is null then null else m.sla - floor(m.open_s / 60.0)::integer end
  from m
  order by case when m.open_s is null then 1 else 0 end, (m.sla * 60 - m.open_s), m.source_created_at, m.source_id
$$;

-- The open tasks: not deleted, status not done by the catalog (a status not in the catalog is open),
-- type counted (a type not in the catalog counts). due_state against the tenant's business date:
-- overdue (due on an earlier date), today, later, none (no due time). The record it belongs to: the
-- deal, else the ticket, by id; never the contact's details.
create or replace function cma.open_tasks_of(p_tenant_id uuid)
returns setof cma.open_task_row
language sql stable
as $$
  with s as (
    select t.timezone as zone, (now() at time zone t.timezone)::date as today from cma.tenant t where t.id = p_tenant_id
  )
  select p_tenant_id, k.id, k.connection_id, k.source_id, k.type_ref, coalesce(y.label, k.type_ref), coalesce(y.is_callback, false),
         k.priority_ref, k.status_ref, coalesce(st.label, k.status_ref),
         cma.owner_user_of(p_tenant_id, k.source_system, k.owner_ref), k.owner_ref,
         cma.task_market_of(p_tenant_id, k.connection_id, k.deal_source_id, k.ticket_source_id, k.contact_source_id),
         k.due_at,
         case when k.due_at is null then 'none'
              when (k.due_at at time zone s.zone)::date < s.today then 'overdue'
              when (k.due_at at time zone s.zone)::date = s.today then 'today'
              else 'later' end,
         case when k.deal_source_id is not null then 'deal' when k.ticket_source_id is not null then 'ticket' end,
         coalesce(k.deal_source_id, k.ticket_source_id),
         k.source_created_at
  from cma.crm_task k
  cross join s
  left join cma.connection_task_status st
    on st.tenant_id = k.tenant_id and st.connection_id = k.connection_id and st.status_ref = k.status_ref
  left join cma.connection_task_type y
    on y.tenant_id = k.tenant_id and y.connection_id = k.connection_id and y.type_ref = k.type_ref
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and not coalesce(st.is_done, false) and coalesce(y.is_counted, true)
  order by k.due_at nulls last, k.source_created_at, k.source_id
$$;

-- Counts only
create or replace function cma.follow_up_summary_of(p_tenant_id uuid)
returns setof cma.follow_up_summary_row
language sql stable
as $$
  with l as materialized (select * from cma.open_leads_of(p_tenant_id)),
       t as materialized (select * from cma.open_tickets_of(p_tenant_id)),
       k as materialized (select * from cma.open_tasks_of(p_tenant_id))
  select p_tenant_id,
         (select count(*)::integer from l),
         (select count(*)::integer from l where l.past_target),
         (select count(*)::integer from t where t.sla_state = 'at_risk'),
         (select count(*)::integer from t where t.sla_state = 'breached'),
         (select count(*)::integer from t where t.owner_ref is null),
         (select count(*)::integer from k where k.due_state = 'overdue'),
         (select count(*)::integer from k where k.due_state = 'today'),
         (select count(*)::integer from k where k.owner_ref is not null and k.owner_user_id is null)
$$;

-- Per mapped person (by name), and one row without a person (owner_user_id null) for every lead,
-- ticket or task whose owner maps to nobody or is empty; nothing for a person with nothing waiting
create or replace function cma.follow_up_by_owner_of(p_tenant_id uuid)
returns setof cma.follow_up_owner_row
language sql stable
as $$
  with l as materialized (select * from cma.open_leads_of(p_tenant_id)),
       t as materialized (select * from cma.open_tickets_of(p_tenant_id)),
       k as materialized (select * from cma.open_tasks_of(p_tenant_id)),
       o as (
         select l.owner_user_id as uid, 1 as leads, (l.past_target is true)::integer as past, 0 as tickets, 0 as risk, 0 as overdue, 0 as today from l
         union all
         select t.owner_user_id, 0, 0, 1, (t.sla_state in ('at_risk', 'breached'))::integer, 0, 0 from t
         union all
         select k.owner_user_id, 0, 0, 0, 0, (k.due_state = 'overdue')::integer, (k.due_state = 'today')::integer from k
       )
  select p_tenant_id, o.uid, u.display_name,
         sum(o.leads)::integer, sum(o.past)::integer, sum(o.tickets)::integer, sum(o.risk)::integer, sum(o.overdue)::integer, sum(o.today)::integer
  from o
  left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = o.uid
  group by o.uid, u.display_name
  order by case when o.uid is null then 1 else 0 end, u.display_name, o.uid
$$;

-- The person's own rows: the leads, tickets and tasks whose owner maps to them, as JSON arrays of the
-- row types above (snake_case keys), with the counts
create or replace function cma.my_follow_up_of(p_tenant_id uuid, p_user_id uuid)
returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'leads', coalesce((select jsonb_agg(to_jsonb(l)) from cma.open_leads_of(p_tenant_id) l where l.owner_user_id = p_user_id), '[]'::jsonb),
    'tickets', coalesce((select jsonb_agg(to_jsonb(t)) from cma.open_tickets_of(p_tenant_id) t where t.owner_user_id = p_user_id), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(to_jsonb(k)) from cma.open_tasks_of(p_tenant_id) k where k.owner_user_id = p_user_id), '[]'::jsonb))
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Data quality (0007d's and 0008m's checks, plus the four changes)
-- ---------------------------------------------------------------------------------------------
-- 0008m's cma.data_quality_added_checks() stays as it is (69 pins it to contact_country_fallback); the
-- follow-up layer's checks are listed apart and shown after it
create or replace function cma.data_quality_follow_up_checks()
returns table (check_key text, sort_order integer, description text)
language sql immutable
as $$
  values
    ('ticket_no_owner',           170, 'Open tickets without an owner, per pipeline'),
    ('ticket_no_market',          180, 'Open tickets without a market, per pipeline (no business hours to count the SLA in)'),
    ('crm_task_owner_unlinked',   190, 'Open tasks whose owner is not linked to a person')
$$;

-- 0008m's findings, and: telephony_call_unlinked skips outbound calls never connected (talk time under
-- telephony.connected_min_seconds) and without a current tag when the telephony connection's setting
-- dq_unlinked_skip is outbound_unanswered_untagged (the default for a connection of kind telephony;
-- 'none' switches it off); missed inbound calls stay in the check. ticket_no_owner and ticket_no_market
-- once the tenant has configured ticket SLAs (follow_up_configured_of), per pipeline (the value);
-- crm_task_owner_unlinked for every open task whose owner maps to no person
create or replace function cma.data_quality_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_start timestamptz;
  v_connected integer;
begin
  select cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone into v_start
  from cma.tenant t where t.id = p_tenant_id;
  v_connected := greatest(0, coalesce(cma.setting_of(p_tenant_id, 'telephony.connected_min_seconds'), '0')::integer);

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
  -- outbound call never connected and without a current tag is skipped when the connection says so
  -- (dq_unlinked_skip = outbound_unanswered_untagged, the default for a telephony connection; 0008o)
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
             and coalesce(tc.talk_seconds, 0) < greatest(1, v_connected)
             and not exists (select 1 from cma.telephony_call_tag g
                             where g.tenant_id = tc.tenant_id and g.connection_id = tc.connection_id
                               and g.call_source_id = tc.source_id and g.untagged_at is null))
  union all
  -- commerce customers whose id no contact holds, or several contacts hold
  select case when h.contacts = 0 then 'commerce_unmatched' else 'commerce_ambiguous' end,
         cu.connection_id, 'commerce_customer', cu.source_id, null
  from cma.commerce_customer cu
  cross join lateral (select count(distinct r.contact_id) as contacts
                      from cma.crm_contact_ref r
                      where r.tenant_id = cu.tenant_id and r.system = cu.source_system and r.external_id = cu.source_id) h
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null and h.contacts <> 1
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
  where k.owner_ref is not null and k.owner_user_id is null;

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

-- 0007d's totals per check, plus the added checks: contact_country_fallback as 0008m lists it; the ticket
-- checks once ticket SLAs are configured; the task check once the tenant holds a task (each also while
-- it finds something, so it shows muted at zero on the Data page); a tenant without any of that keeps
-- 0007d's fifteen rows exactly (41 pins them)
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
    )
    select c.check_key, c.description,
           case when c.check_key = 'writeback_parked' and to_regclass('cma.outbox_action') is null then null
                else (select count(*) from q where q.check_key = c.check_key)::integer end
    from c
    order by c.sort_order;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. The application's reads (permission checked, current tenant, row-level security)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.open_leads()
returns setof cma.open_lead_row
language plpgsql stable
as $$
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team', 'monitoring.live']);
  return query select * from cma.open_leads_of(cma.current_tenant_id());
end
$$;

create or replace function cma.open_tickets()
returns setof cma.open_ticket_row
language plpgsql stable
as $$
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team', 'monitoring.live']);
  return query select * from cma.open_tickets_of(cma.current_tenant_id());
end
$$;

create or replace function cma.open_tasks()
returns setof cma.open_task_row
language plpgsql stable
as $$
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team', 'monitoring.live']);
  return query select * from cma.open_tasks_of(cma.current_tenant_id());
end
$$;

create or replace function cma.follow_up_summary()
returns setof cma.follow_up_summary_row
language plpgsql stable
as $$
begin
  perform cma.assert_any_permission(array['monitoring.live', 'performance.team', 'workday.team']);
  return query select * from cma.follow_up_summary_of(cma.current_tenant_id());
end
$$;

-- Per-person figures sit under the employee-monitoring point with Yordi, like Calls per agent:
-- performance.team only
create or replace function cma.follow_up_by_owner()
returns setof cma.follow_up_owner_row
language plpgsql stable
as $$
begin
  perform cma.assert_permission('performance.team');
  return query select * from cma.follow_up_by_owner_of(cma.current_tenant_id());
end
$$;

-- The caller's own rows (owner mapped to the caller through app_user_external_id), with the record
-- links from the connection's templates (cma.record_url: deal, ticket, task)
create or replace function cma.my_follow_up()
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid := cma.current_user_id();
  v_res    jsonb;
begin
  perform cma.assert_any_permission(array['leads.accept', 'workday.own']);
  if v_user is null then
    raise exception 'no acting user' using errcode = 'CMA01';
  end if;
  v_res := cma.my_follow_up_of(v_tenant, v_user);
  return jsonb_build_object(
    'leads', coalesce((select jsonb_agg(x || jsonb_build_object('record_url', cma.record_url((x ->> 'connection_id')::uuid, 'deal', x ->> 'deal_source_id')))
                       from jsonb_array_elements(v_res -> 'leads') x), '[]'::jsonb),
    'tickets', coalesce((select jsonb_agg(x || jsonb_build_object('record_url', cma.record_url((x ->> 'connection_id')::uuid, 'ticket', x ->> 'ticket_source_id')))
                         from jsonb_array_elements(v_res -> 'tickets') x), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(x || jsonb_build_object('record_url', cma.record_url((x ->> 'connection_id')::uuid, 'task', x ->> 'task_source_id')))
                       from jsonb_array_elements(v_res -> 'tasks') x), '[]'::jsonb));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.set_pipeline_sla(uuid,text,text,integer)',
    'cma.open_leads()', 'cma.open_tickets()', 'cma.open_tasks()',
    'cma.follow_up_summary()', 'cma.follow_up_by_owner()', 'cma.my_follow_up()',
    'cma.data_quality()', 'cma.data_quality_of(uuid)', 'cma.data_quality_added_checks()', 'cma.data_quality_follow_up_checks()',
    -- the reads of an explicit tenant, which the functions above call in the caller's rights
    -- (row-level security keeps them to the current tenant whatever tenant they are given)
    'cma.open_leads_of(uuid)', 'cma.open_tickets_of(uuid)', 'cma.open_tasks_of(uuid)',
    'cma.follow_up_summary_of(uuid)', 'cma.follow_up_by_owner_of(uuid)', 'cma.my_follow_up_of(uuid,uuid)',
    'cma.owner_user_of(uuid,text,text)', 'cma.business_days_of(uuid,text,timestamptz,timestamptz)',
    'cma.age_bucket_of(integer,text)', 'cma.task_market_of(uuid,uuid,text,text,text)',
    'cma.follow_up_configured_of(uuid)', 'cma.is_bucket_list(text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Reporting: the readers' functions and views (every tenant the reader sees; ids and counts only)
-- ---------------------------------------------------------------------------------------------
create or replace function cma_read.open_leads_rows()
returns setof cma.open_lead_row
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select r.* from cma.tenant t cross join lateral cma.open_leads_of(t.id) r where cma_read.reader_sees(t.id)
$$;

create or replace function cma_read.open_tickets_rows()
returns setof cma.open_ticket_row
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select r.* from cma.tenant t cross join lateral cma.open_tickets_of(t.id) r where cma_read.reader_sees(t.id)
$$;

create or replace function cma_read.open_tasks_rows()
returns setof cma.open_task_row
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select r.* from cma.tenant t cross join lateral cma.open_tasks_of(t.id) r where cma_read.reader_sees(t.id)
$$;

create or replace function cma_read.follow_up_summary_rows()
returns setof cma.follow_up_summary_row
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select r.* from cma.tenant t cross join lateral cma.follow_up_summary_of(t.id) r where cma_read.reader_sees(t.id)
$$;

create or replace function cma_read.follow_up_by_owner_rows()
returns setof cma.follow_up_owner_row
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select r.* from cma.tenant t cross join lateral cma.follow_up_by_owner_of(t.id) r where cma_read.reader_sees(t.id)
$$;

do $$
declare
  f text;
begin
  foreach f in array array[
    'cma_read.open_leads_rows()', 'cma_read.open_tickets_rows()', 'cma_read.open_tasks_rows()',
    'cma_read.follow_up_summary_rows()', 'cma_read.follow_up_by_owner_rows()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_readonly', f);
  end loop;
end
$$;

create or replace view cma_read.open_lead as
  select * from cma_read.open_leads_rows();

create or replace view cma_read.open_ticket as
  select * from cma_read.open_tickets_rows();

create or replace view cma_read.open_task as
  select * from cma_read.open_tasks_rows();

create or replace view cma_read.follow_up_summary as
  select * from cma_read.follow_up_summary_rows();

-- ids only: the person's name stays in the application
create or replace view cma_read.follow_up_by_owner as
  select tenant_id, owner_user_id, open_leads, leads_past_target, open_tickets, tickets_at_risk_or_breached, tasks_overdue, tasks_due_today
  from cma_read.follow_up_by_owner_rows();

create or replace view cma_read.connection_pipeline_sla as
  select tenant_id, connection_id, record_type, source_pipeline_id, sla_minutes
  from cma.connection_pipeline
  where cma_read.reader_sees(tenant_id);

-- The added data-quality checks' views, as 0007d's dq_ views (ids and codes only)
create or replace view cma_read.dq_ticket_no_owner as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'ticket_no_owner';

create or replace view cma_read.dq_ticket_no_market as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'ticket_no_market';

create or replace view cma_read.dq_crm_task_owner_unlinked as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'crm_task_owner_unlinked';

do $$
declare
  v text;
begin
  foreach v in array array['open_lead', 'open_ticket', 'open_task', 'follow_up_summary', 'follow_up_by_owner', 'connection_pipeline_sla',
                           'dq_ticket_no_owner', 'dq_ticket_no_market', 'dq_crm_task_owner_unlinked'] loop
    execute format('grant select on cma_read.%I to cma_readonly', v);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008o', 'The follow-up layer: the four settings (ticket SLA in business minutes and its warning share, the age buckets of open leads, the callback window), the SLA per pipeline, open leads not called with their age bucket and last call, open tickets against their SLA, open tasks with their due state, the summary, per person and the person''s own rows, the data-quality skip rule for unlinked outbound calls and the checks ticket_no_owner, ticket_no_market and crm_task_owner_unlinked, the reporting views')
on conflict (version) do nothing;

commit;
reset role;
