-- =============================================================================================
-- 74_forms_reporting.sql: addition 0008p, forms reporting
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 72_follow_up.sql (0008o). Rerunnable, forward-only, in one transaction. Run as your own IAM login,
-- dev first, then prod; then 75_verify_forms_reporting.sql (dev), then 33_verify_intake_core.sql and
-- 41_verify_lead_metrics.sql, and in dev 53_verify_sources_configuration.sql,
-- 69_verify_email_activity.sql, 71_verify_crm_tasks.sql and 73_verify_follow_up.sql again (unchanged).
--
-- Brief B17d with its amendment (README Decision log, 16 October 2026): every form's submissions per
-- form and per market in a report of their own, with forms polled whether or not they count as leads
-- in Intake. Until now is_counted meant both "poll this form" and "count it in Intake"; a support form
-- (a cancellation, a replacement device, a bank detail change) was therefore never read. Now:
--   is_polled          whether the poll and the backfill read the form. A counted form is always
--                      polled (a check); existing forms are polled exactly when they count
--   is_counted         whether its submissions count in Intake (KPI 1), unchanged: every intake,
--                      speed-to-lead and lead-metrics figure reads is_counted only
--   category           a code of the tenant's form categories (configuration, cma.form_category);
--                      no category is named in code or here
--   answers            a form's kept fields name choice fields only (dropdown, radio, multiple
--                      checkboxes, single checkbox) once the source has described the form's fields
--                      (cma.connection_form_field, refreshed with the catalog); an answer is kept only
--                      when every value of it is one of the field's current options. Never free
--                      text, an address, a serial number or a bank field. A form the source has not
--                      described yet keeps 0007's rule by field name (33, which has run in prod,
--                      configures such forms); the ingest keeps no answer without the field's options
--   lead rule          lead_condition: a kept field and the values that make a submission a lead.
--                      Intake's form count takes a counted form's submission only when its form has
--                      no condition or the submission's answer is one of the values; a missing answer
--                      is not a lead
--   market             of a submission, read at query time: the form's market; else the answer of the
--                      form's market_field (a kept choice field such as a country dropdown) through the
--                      market aliases; else the resolved contact's country (its slots of 0008m);
--                      else unknown
--
-- What it adds
--   categories          cma.form_category (code, name, order, active or inactive; never deleted),
--                       cma.set_form_category(), cma.set_form_category_status(), cma.form_categories()
--   forms               connection_form.is_polled, category, market_field, lead_condition and
--                       fields_refreshed_at; cma.set_form() keeps its signature (a counted form is
--                       polled; kept fields choice fields of a described form); cma.set_form_reporting()
--                       (polled, category, market), cma.set_form_market_field(),
--                       cma.set_form_lead_condition(); cma.connection_catalogs() gives them with the
--                       form's fields (connection_config gives no forms: the ingest reads the forms
--                       itself, as since 0007)
--   field catalog       cma.connection_form_field: per form its fields' names, kinds and option values
--                       (names and option values only), refreshed by cma.ingest_upsert_forms() when an
--                       item carries fields; an option the source drops is kept as retired, so a stored
--                       answer stays explainable
--   submissions         cma.ingest_upsert_form_submissions() keeps choice answers only, checked against
--                       the options, and fills the answers of a stored submission whose answers are
--                       empty (the backfill; the only update besides the contact resolution); a
--                       submission whose answers a privacy deletion cleared is never filled again
--                       (form_submission.kept_cleared_at, set by cma.ingest_contact_forget())
--   intake              cma.intake_per_day_of(): the lead rule on the form count; everything else as 0007d
--   runs                cma.ingest_sync_run_finish() takes the count dropped (answers the forms poll left
--                       out because no option of their field accounts for them)
--   reads               cma.forms_report(from, to, group, market, category, form): per form and market
--                       and day or ISO week the submissions and their contact resolution, the period's
--                       totals per form and market, and the previous period's, like for like (as
--                       0008j); cma.forms_answers(from, to, market, category, form, field, value): per
--                       form, market, kept field and value the submissions, with the previous period;
--                       cma.forms_history_start() (as 0008k); reports.view or performance.team
--   data quality        the check form_answer_not_in_options: kept answers no option of their field
--                       accounts for (0 by construction), with its dq_ view
--   reporting views     cma_read.form_category, cma_read.connection_form_field; connection_form and
--                       form_submission gain their new columns at the end
--
-- Nothing personal: ids, form and field names, option values and counts. A submission's kept answers
-- are option values of the form's choice fields; the reads return no submission id and no contact id.
--
-- How the reads are made (as 0007d, 0008j and 0008k): each is a function of an explicit tenant
-- (cma.*_of) in the caller's rights; the application's functions check the permission and call it for
-- the current tenant under row-level security. Every function is SECURITY INVOKER and executable by
-- the application only.
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
  if not exists (select 1 from cma.schema_migration where version = '0008o') then
    raise exception 'addition 0008o (72_follow_up.sql) must run before 0008p';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Helpers the tables' checks use
-- ---------------------------------------------------------------------------------------------
-- The canonical kinds of a form field. The four choice kinds are the only fields whose answers may be
-- kept; every other field (text, email, phone, number, date, file, ...) is 'other'
create or replace function cma.form_choice_kind(p_kind text)
returns boolean
language sql immutable
as $$
  select coalesce(p_kind in ('dropdown', 'radio', 'multiple_checkboxes', 'single_checkbox'), false)
$$;

-- A field's option values as stored: each 1 to 200 characters, each once
create or replace function cma.form_options_ok(p_options text[])
returns boolean
language sql immutable
as $$
  select not exists (select 1 from unnest(p_options) o where o is null or length(o) not between 1 and 200)
     and (select count(distinct o) from unnest(p_options) o) = cardinality(p_options)
$$;

-- Kept answers as stored: an object whose values are an option value (1 to 200 characters) or, for
-- a multiple-checkboxes field, an array of 1 to 50 of them
create or replace function cma.form_kept_values_ok(p_values jsonb)
returns boolean
language plpgsql immutable
as $$
declare
  e record;
begin
  if p_values is null or jsonb_typeof(p_values) <> 'object' then
    return false;
  end if;
  for e in select key, value from jsonb_each(p_values) loop
    if jsonb_typeof(e.value) = 'string' then
      if length(e.value #>> '{}') not between 1 and 200 then
        return false;
      end if;
    elsif jsonb_typeof(e.value) = 'array' then
      if jsonb_array_length(e.value) not between 1 and 50
         or exists (select 1 from jsonb_array_elements(e.value) v
                    where jsonb_typeof(v) <> 'string' or length(v #>> '{}') not between 1 and 200) then
        return false;
      end if;
    else
      return false;
    end if;
  end loop;
  return true;
end
$$;

-- A lead condition: {"field": a field name, "values": 1 to 50 distinct values of 1 to 200 characters}
create or replace function cma.form_lead_condition_ok(p_condition jsonb)
returns boolean
language plpgsql immutable
as $$
begin
  if p_condition is null or jsonb_typeof(p_condition) <> 'object' then
    return false;
  end if;
  if (select count(*) from jsonb_object_keys(p_condition)) <> 2
     or jsonb_typeof(p_condition -> 'field') is distinct from 'string'
     or (p_condition ->> 'field') !~ '^[A-Za-z0-9_.-]{1,100}$'
     or jsonb_typeof(p_condition -> 'values') is distinct from 'array' then
    return false;
  end if;
  return jsonb_array_length(p_condition -> 'values') between 1 and 50
     and not exists (select 1 from jsonb_array_elements(p_condition -> 'values') v
                     where jsonb_typeof(v) <> 'string' or length(v #>> '{}') not between 1 and 200)
     and (select count(distinct v) from jsonb_array_elements_text(p_condition -> 'values') v)
         = jsonb_array_length(p_condition -> 'values');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Form categories (tenant configuration)
-- ---------------------------------------------------------------------------------------------
-- What a form is for, as the tenant names it (a lead form, a cancellation, a support request ...): a
-- code the forms refer to, a name for the screens and an order. Never deleted: switched off, and a
-- form keeps the category it has. 'none' is reserved for the reports' filter (forms without one).
create table if not exists cma.form_category (
  id          uuid primary key default uuidv7(),
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  code        text not null check (code ~ '^[a-z][a-z0-9_]{0,39}$' and code <> 'none'),
  name        text not null check (length(btrim(name)) between 1 and 60),
  sort_order  integer not null default 100,
  status      text not null default 'active' check (status in ('active', 'inactive')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, code)
);
comment on table cma.form_category is 'Form categories per tenant (configuration): a code the forms refer to, a name, an order; switched off, never deleted';
create or replace trigger set_updated_at before update on cma.form_category
  for each row execute function cma.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- 3. Forms: polled apart from counted, category, market field, lead condition
-- ---------------------------------------------------------------------------------------------
-- A form found by the catalog counts (0007's default) and so is polled; an existing form is polled
-- exactly when it counts today, so nothing is read that was not read before this addition
alter table cma.connection_form add column if not exists is_polled boolean;
update cma.connection_form set is_polled = is_counted where is_polled is null;
alter table cma.connection_form alter column is_polled set default true;
alter table cma.connection_form alter column is_polled set not null;
alter table cma.connection_form add column if not exists category text;
alter table cma.connection_form add column if not exists market_field text;
alter table cma.connection_form add column if not exists lead_condition jsonb;
alter table cma.connection_form add column if not exists fields_refreshed_at timestamptz;

alter table cma.connection_form drop constraint if exists connection_form_polled_check;
alter table cma.connection_form add constraint connection_form_polled_check check (is_polled or not is_counted);
alter table cma.connection_form drop constraint if exists connection_form_category_fkey;
alter table cma.connection_form add constraint connection_form_category_fkey
  foreign key (tenant_id, category) references cma.form_category (tenant_id, code);
alter table cma.connection_form drop constraint if exists connection_form_market_field_check;
alter table cma.connection_form add constraint connection_form_market_field_check
  check (market_field is null or market_field = any (kept_fields));
alter table cma.connection_form drop constraint if exists connection_form_lead_condition_check;
alter table cma.connection_form add constraint connection_form_lead_condition_check
  check (lead_condition is null or (cma.form_lead_condition_ok(lead_condition) and (lead_condition ->> 'field') = any (kept_fields)));

comment on column cma.connection_form.is_polled is 'Whether the poll and the backfill read the form (0008p); a counted form is always polled';
comment on column cma.connection_form.is_counted is 'Whether the form''s submissions count in Intake (lead forms); implies is_polled';
comment on column cma.connection_form.category is 'A code of the tenant''s form categories (configuration, 0008p)';
comment on column cma.connection_form.market_field is 'A kept choice field whose answer gives a submission''s market when the form has none, through the market aliases (0008p)';
comment on column cma.connection_form.lead_condition is 'A kept field and the values that make a submission a lead: {"field": ..., "values": [...]}; null: every submission of a counted form is one (0008p)';
comment on column cma.connection_form.fields_refreshed_at is 'When the source last described the form''s fields (cma.connection_form_field); null: never, and 0007''s rule by field name applies (0008p)';
comment on column cma.connection_form.kept_fields is 'Names of the form''s choice fields whose answers are kept (option values only); before the source described the fields, names of fields whose values are not personal (0007)';

-- ---------------------------------------------------------------------------------------------
-- 4. The forms' fields (names, kinds and option values only)
-- ---------------------------------------------------------------------------------------------
-- Per form the fields the source describes: name, the adapter's canonical kind and, for a choice
-- field, its current option values. An option the source no longer lists moves to retired_options
-- (answers stored with it stay explainable) and back when it returns; a field the source dropped is
-- archived. Labels are not stored: the reports label an answer with its option value.
create table if not exists cma.connection_form_field (
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id    uuid not null,
  source_form_id   text not null,
  name             text not null check (name ~ '^[A-Za-z0-9_.-]{1,100}$'),
  kind             text not null check (kind in ('dropdown', 'radio', 'multiple_checkboxes', 'single_checkbox', 'other')),
  options          text[] not null default '{}' check (cardinality(options) <= 500 and cma.form_options_ok(options)),
  retired_options  text[] not null default '{}' check (cardinality(retired_options) <= 1000 and cma.form_options_ok(retired_options)),
  sort_order       integer not null default 0,
  status           text not null default 'active' check (status in ('active', 'archived')),
  refreshed_at     timestamptz,
  updated_at       timestamptz not null default now(),
  primary key (tenant_id, connection_id, source_form_id, name),
  foreign key (tenant_id, connection_id, source_form_id)
    references cma.connection_form (tenant_id, connection_id, source_form_id),
  check (cma.form_choice_kind(kind) or (cardinality(options) = 0 and cardinality(retired_options) = 0))
);
comment on table cma.connection_form_field is 'Fields of the source''s forms: name, canonical kind and the option values of choice fields (names and option values only), refreshed with the form catalog';
create or replace trigger set_updated_at before update on cma.connection_form_field
  for each row execute function cma.set_updated_at();

select cma.setup_tenant_table('cma.form_category');
select cma.setup_tenant_table('cma.connection_form_field');
-- written through the functions below only, never deleted
revoke delete on cma.form_category, cma.connection_form_field from cma_app;

-- ---------------------------------------------------------------------------------------------
-- 5. Submissions: the answers as stored, and the privacy deletion's mark
-- ---------------------------------------------------------------------------------------------
-- 0007 stored kept values as strings; answers are option values, a multiple-checkboxes answer an array
alter table cma.form_submission drop constraint if exists form_submission_kept_values_check;
alter table cma.form_submission add constraint form_submission_kept_values_check check (cma.form_kept_values_ok(kept_values));
-- Set when a privacy deletion cleared the submission's answers: a later read never fills them again
alter table cma.form_submission add column if not exists kept_cleared_at timestamptz;
comment on column cma.form_submission.kept_cleared_at is 'When a privacy deletion cleared the kept answers; a later read never fills them again (0008p)';
comment on column cma.form_submission.kept_values is 'Answers of the form''s kept choice fields: an option value, or an array of them for multiple checkboxes (0008p); before the source described the form''s fields, values of kept fields (0007)';
comment on table cma.form_submission is 'Form submissions: ids, form, time, page without query string, UTM tags, the resolved contact id; answers only of the form''s kept choice fields. Insert-only apart from the contact resolution and filling empty answers';
grant update (kept_cleared_at) on cma.form_submission to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 6. Answers, the lead rule and the market of a submission
-- ---------------------------------------------------------------------------------------------
-- An answer as kept, or null when it is none: a dropdown, radio or single-checkbox answer is one of
-- the field's options; a multiple-checkboxes answer is an array of 1 to 50 of them (stored sorted,
-- each once). Anything else (another kind, a value no option accounts for, free text) is null
create or replace function cma.form_answer_of(p_kind text, p_options text[], p_value jsonb)
returns jsonb
language plpgsql immutable
as $$
begin
  if p_kind in ('dropdown', 'radio', 'single_checkbox') then
    if jsonb_typeof(p_value) = 'string' and (p_value #>> '{}') = any (p_options) then
      return p_value;
    end if;
  elsif p_kind = 'multiple_checkboxes' then
    if jsonb_typeof(p_value) = 'array' and jsonb_array_length(p_value) between 1 and 50
       and not exists (select 1 from jsonb_array_elements(p_value) v
                       where jsonb_typeof(v) <> 'string' or not ((v #>> '{}') = any (p_options))) then
      return (select jsonb_agg(distinct v order by v) from jsonb_array_elements_text(p_value) v);
    end if;
  end if;
  return null;
end
$$;

-- A submission's answers as stored for its form. A form the source has described (fields_refreshed_at
-- set): the answers of its kept fields that are active choice fields, each checked against the field's
-- current options (cma.form_answer_of); any other answer is dropped. A form the source has not
-- described yet: 0007's rule, the kept fields' values by name, scalars only, each at most 200
-- characters (an empty value is left out)
create or replace function cma.form_kept_values_of(p_tenant_id uuid, p_connection_id uuid, p_form_id text, p_values jsonb)
returns jsonb
language plpgsql stable
as $$
declare
  v_kept      text[];
  v_described timestamptz;
begin
  select f.kept_fields, f.fields_refreshed_at into v_kept, v_described
  from cma.connection_form f
  where f.tenant_id = p_tenant_id and f.connection_id = p_connection_id and f.source_form_id = p_form_id;
  if v_kept is null or cardinality(v_kept) = 0 or p_values is null or jsonb_typeof(p_values) <> 'object' then
    return '{}'::jsonb;
  end if;
  if v_described is null then
    return coalesce((select jsonb_object_agg(e.key, left(e.value #>> '{}', 200))
                     from jsonb_each(p_values) e
                     where e.key = any (v_kept) and jsonb_typeof(e.value) in ('string', 'number', 'boolean')
                       and length(e.value #>> '{}') > 0), '{}'::jsonb);
  end if;
  return coalesce((select jsonb_object_agg(e.key, a.answer)
                   from jsonb_each(p_values) e
                   join cma.connection_form_field ff
                     on ff.tenant_id = p_tenant_id and ff.connection_id = p_connection_id and ff.source_form_id = p_form_id
                    and ff.name = e.key and ff.status = 'active'
                   cross join lateral (select cma.form_answer_of(ff.kind, ff.options, e.value) as answer) a
                   where e.key = any (v_kept) and a.answer is not null), '{}'::jsonb);
end
$$;

-- Whether a submission is a lead by its form's condition: no condition, or the kept answer of the
-- condition's field is one of its values (for multiple checkboxes: one of the answer's values is). A
-- missing answer is no lead
create or replace function cma.form_is_lead(p_condition jsonb, p_values jsonb)
returns boolean
language plpgsql immutable
as $$
declare
  v_answer jsonb;
begin
  if p_condition is null then
    return true;
  end if;
  v_answer := p_values -> (p_condition ->> 'field');
  if jsonb_typeof(v_answer) = 'string' then
    return (v_answer #>> '{}') in (select jsonb_array_elements_text(p_condition -> 'values'));
  elsif jsonb_typeof(v_answer) = 'array' then
    return exists (select 1 from jsonb_array_elements_text(v_answer) a
                   where a in (select jsonb_array_elements_text(p_condition -> 'values')));
  end if;
  return false;
end
$$;

-- A submission's market, read at query time: the form's market; else the answer of the form's
-- market field, through the market aliases; else the resolved contact's stored country (its country
-- slots, 0008m); each only when it names a catalog market; 'unknown' otherwise. source says which step
-- gave it: form, answer or contact (null for unknown)
create or replace function cma.form_submission_market_of(p_tenant_id uuid, p_connection_id uuid, p_form_market text,
                                                         p_market_field text, p_values jsonb, p_contact_source_id text,
                                                         out code text, out source text)
language sql stable
as $$
  with v as (
    select cma.market_code_of(p_tenant_id, p_form_market) as form,
           case when p_market_field is not null and jsonb_typeof(p_values -> p_market_field) = 'string'
                then cma.market_code_of(p_tenant_id, p_values ->> p_market_field) end as answer,
           (select cma.market_code_of(p_tenant_id, cc.country)
            from cma.crm_contact cc
            where cc.tenant_id = p_tenant_id and cc.connection_id = p_connection_id
              and cc.source_id = p_contact_source_id) as contact
  )
  select coalesce(v.form, v.answer, v.contact, 'unknown'),
         case when v.form is not null then 'form' when v.answer is not null then 'answer'
              when v.contact is not null then 'contact' end
  from v
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Configuration (tenant.configure)
-- ---------------------------------------------------------------------------------------------
-- Kept fields of a form the source has described must be its active choice fields (CMA04); a form
-- not described yet keeps 0007's rule (field names)
create or replace function cma.form_kept_fields_check(p_connection_id uuid, p_form_id text, p_fields text[])
returns void
language plpgsql stable
as $$
declare
  v_bad text;
begin
  if not exists (select 1 from cma.connection_form f
                 where f.tenant_id = cma.current_tenant_id() and f.connection_id = p_connection_id
                   and f.source_form_id = p_form_id and f.fields_refreshed_at is not null) then
    return;
  end if;
  select string_agg(x, ', ' order by x) into v_bad
  from unnest(p_fields) x
  where not exists (select 1 from cma.connection_form_field ff
                    where ff.tenant_id = cma.current_tenant_id() and ff.connection_id = p_connection_id
                      and ff.source_form_id = p_form_id and ff.name = x and ff.status = 'active'
                      and cma.form_choice_kind(ff.kind));
  if v_bad is not null then
    raise exception 'a kept field must be a choice field of the form (dropdown, radio, multiple checkboxes, single checkbox), not %', v_bad
      using errcode = 'CMA04';
  end if;
end
$$;

-- A form's configuration: counted, lead source label, market and the kept fields (0007's signature).
-- A counted form is polled; a form set not counted keeps whether it is polled (cma.set_form_reporting
-- sets that), and a form not yet read from the source is added with its id as name, polled when
-- counted. Kept fields: at most 30 names; of a form the source has described, its choice fields only;
-- a field the market field or the lead condition uses stays kept (CMA03)
create or replace function cma.set_form(p_connection_id uuid, p_form_id text, p_is_counted boolean, p_lead_source text,
                                        p_market text, p_kept_fields text[])
returns void
language plpgsql
as $$
declare
  v_fields text[];
  v_used   text;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_is_counted is null then
    raise exception 'is_counted must be true or false' using errcode = 'CMA04';
  end if;
  if p_market is not null then
    perform cma.assert_market(p_market, false);
  end if;
  select coalesce(array_agg(distinct btrim(f) order by btrim(f)), '{}') into v_fields
  from unnest(coalesce(p_kept_fields, '{}')) f;
  if exists (select 1 from unnest(v_fields) f where f !~ '^[A-Za-z0-9_.-]{1,100}$') or cardinality(v_fields) > 30 then
    raise exception 'kept fields are at most 30 field names of letters, digits, _ . -' using errcode = 'CMA04';
  end if;
  perform cma.form_kept_fields_check(p_connection_id, p_form_id, v_fields);
  select string_agg(u, ', ' order by u) into v_used
  from (select f.market_field as u from cma.connection_form f
        where f.tenant_id = cma.current_tenant_id() and f.connection_id = p_connection_id and f.source_form_id = p_form_id
        union
        select f.lead_condition ->> 'field' from cma.connection_form f
        where f.tenant_id = cma.current_tenant_id() and f.connection_id = p_connection_id and f.source_form_id = p_form_id) x
  where u is not null and not (u = any (v_fields));
  if v_used is not null then
    raise exception 'the market field or the lead condition uses %; keep it, or change them first', v_used using errcode = 'CMA03';
  end if;
  insert into cma.connection_form as f (tenant_id, connection_id, source_form_id, name, is_counted, is_polled, lead_source, market, kept_fields)
  values (cma.current_tenant_id(), p_connection_id, p_form_id, p_form_id, p_is_counted, p_is_counted, nullif(btrim(p_lead_source), ''),
          p_market, v_fields)
  on conflict (tenant_id, connection_id, source_form_id) do update
    set is_counted = excluded.is_counted, is_polled = f.is_polled or excluded.is_counted, lead_source = excluded.lead_source,
        market = excluded.market, kept_fields = excluded.kept_fields;
exception when check_violation or not_null_violation then
  raise exception 'invalid form: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- A form's reporting: polled, category (a code of the tenant's categories, or null) and market. A
-- counted form is always polled (CMA03); an unknown category or market CMA02; a switched-off category
-- only when the form has it already (CMA04). A form not yet read from the source is added with its id
-- as name, not counted
create or replace function cma.set_form_reporting(p_connection_id uuid, p_form_id text, p_is_polled boolean, p_category text,
                                                  p_market text)
returns void
language plpgsql
as $$
declare
  v_status text;
  v_old    cma.connection_form;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_is_polled is null then
    raise exception 'is_polled must be true or false' using errcode = 'CMA04';
  end if;
  if coalesce(p_form_id, '') = '' or length(p_form_id) > 100 then
    raise exception 'a form id has 1 to 100 characters' using errcode = 'CMA04';
  end if;
  select * into v_old from cma.connection_form f
  where f.tenant_id = cma.current_tenant_id() and f.connection_id = p_connection_id and f.source_form_id = p_form_id;
  if p_category is not null then
    select c.status into v_status from cma.form_category c where c.tenant_id = cma.current_tenant_id() and c.code = p_category;
    if v_status is null then
      raise exception 'no form category % in the current tenant', p_category using errcode = 'CMA02';
    end if;
    if v_status <> 'active' and v_old.category is distinct from p_category then
      raise exception 'form category % is switched off', p_category using errcode = 'CMA04';
    end if;
  end if;
  if p_market is not null then
    perform cma.assert_market(p_market, false);
  end if;
  if not p_is_polled and coalesce(v_old.is_counted, false) then
    raise exception 'a counted form is always polled; set it not counted first' using errcode = 'CMA03';
  end if;
  insert into cma.connection_form (tenant_id, connection_id, source_form_id, name, is_counted, is_polled, category, market)
  values (cma.current_tenant_id(), p_connection_id, p_form_id, p_form_id, false, p_is_polled, p_category, p_market)
  on conflict (tenant_id, connection_id, source_form_id) do update
    set is_polled = excluded.is_polled, category = excluded.category, market = excluded.market;
exception when check_violation or not_null_violation then
  raise exception 'invalid form: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- The field whose answer gives a submission's market when the form has none: a kept field, of a form
-- the source has described a dropdown or radio field (one answer); null clears it. Unknown form CMA02,
-- anything else CMA04
create or replace function cma.set_form_market_field(p_connection_id uuid, p_form_id text, p_field text)
returns void
language plpgsql
as $$
declare
  v_form cma.connection_form;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  select * into v_form from cma.connection_form f
  where f.tenant_id = cma.current_tenant_id() and f.connection_id = p_connection_id and f.source_form_id = p_form_id;
  if v_form.source_form_id is null then
    raise exception 'no form % on connection %', p_form_id, p_connection_id using errcode = 'CMA02';
  end if;
  if p_field is not null then
    if not (p_field = any (v_form.kept_fields)) then
      raise exception 'the market field must be a kept field of the form, not %', p_field using errcode = 'CMA04';
    end if;
    if v_form.fields_refreshed_at is not null
       and not exists (select 1 from cma.connection_form_field ff
                       where ff.tenant_id = v_form.tenant_id and ff.connection_id = p_connection_id and ff.source_form_id = p_form_id
                         and ff.name = p_field and ff.status = 'active' and ff.kind in ('dropdown', 'radio')) then
      raise exception 'the market field must be a dropdown or radio field of the form, not %', p_field using errcode = 'CMA04';
    end if;
  end if;
  update cma.connection_form f set market_field = p_field
  where f.tenant_id = v_form.tenant_id and f.connection_id = p_connection_id and f.source_form_id = p_form_id;
end
$$;

-- The lead rule of a form: a kept field and the values that make a submission a lead (1 to 50, each
-- once; of a form the source has described, options of that choice field); a null field clears it,
-- and then every submission of a counted form is a lead. Unknown form CMA02, anything else CMA04
create or replace function cma.set_form_lead_condition(p_connection_id uuid, p_form_id text, p_field text, p_values text[])
returns void
language plpgsql
as $$
declare
  v_form   cma.connection_form;
  v_values text[];
  v_bad    text;
  v_field  cma.connection_form_field;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  select * into v_form from cma.connection_form f
  where f.tenant_id = cma.current_tenant_id() and f.connection_id = p_connection_id and f.source_form_id = p_form_id;
  if v_form.source_form_id is null then
    raise exception 'no form % on connection %', p_form_id, p_connection_id using errcode = 'CMA02';
  end if;
  if p_field is null then
    update cma.connection_form f set lead_condition = null
    where f.tenant_id = v_form.tenant_id and f.connection_id = p_connection_id and f.source_form_id = p_form_id;
    return;
  end if;
  if not (p_field = any (v_form.kept_fields)) then
    raise exception 'the lead condition''s field must be a kept field of the form, not %', p_field using errcode = 'CMA04';
  end if;
  select coalesce(array_agg(distinct v order by v), '{}') into v_values from unnest(coalesce(p_values, '{}')) v;
  if cardinality(v_values) not between 1 and 50 or exists (select 1 from unnest(v_values) v where v is null or length(v) not between 1 and 200) then
    raise exception 'a lead condition takes 1 to 50 values of 1 to 200 characters' using errcode = 'CMA04';
  end if;
  if v_form.fields_refreshed_at is not null then
    select * into v_field from cma.connection_form_field ff
    where ff.tenant_id = v_form.tenant_id and ff.connection_id = p_connection_id and ff.source_form_id = p_form_id
      and ff.name = p_field and ff.status = 'active';
    if v_field.name is null or not cma.form_choice_kind(v_field.kind) then
      raise exception 'the lead condition''s field must be a choice field of the form, not %', p_field using errcode = 'CMA04';
    end if;
    select string_agg(v, ', ' order by v) into v_bad from unnest(v_values) v where not (v = any (v_field.options));
    if v_bad is not null then
      raise exception 'not an option of %: %', p_field, v_bad using errcode = 'CMA04';
    end if;
  end if;
  update cma.connection_form f set lead_condition = jsonb_build_object('field', p_field, 'values', to_jsonb(v_values))
  where f.tenant_id = v_form.tenant_id and f.connection_id = p_connection_id and f.source_form_id = p_form_id;
end
$$;

-- Adds or renames a form category; a new one is active. The code: lower-case letters, digits and _,
-- starting with a letter, at most 40, not 'none'; the name 1 to 60 characters (CMA04)
create or replace function cma.set_form_category(p_code text, p_name text, p_sort_order integer)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  if coalesce(p_code, '') !~ '^[a-z][a-z0-9_]{0,39}$' or p_code = 'none' then
    raise exception 'a category code is lower-case letters, digits and _, starting with a letter, at most 40, and not none'
      using errcode = 'CMA04';
  end if;
  if length(btrim(coalesce(p_name, ''))) not between 1 and 60 then
    raise exception 'a category name has 1 to 60 characters' using errcode = 'CMA04';
  end if;
  insert into cma.form_category (tenant_id, code, name, sort_order)
  values (cma.current_tenant_id(), p_code, btrim(p_name), coalesce(p_sort_order, 100))
  on conflict (tenant_id, code) do update set name = excluded.name, sort_order = excluded.sort_order;
end
$$;

-- Switches a form category on or off; its forms keep it. Unknown CMA02, another status CMA04
create or replace function cma.set_form_category_status(p_code text, p_status text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  if p_status is null or p_status not in ('active', 'inactive') then
    raise exception 'a category is active or inactive, not %', p_status using errcode = 'CMA04';
  end if;
  update cma.form_category c set status = p_status where c.tenant_id = cma.current_tenant_id() and c.code = p_code;
  if not found then
    raise exception 'no form category % in the current tenant', p_code using errcode = 'CMA02';
  end if;
end
$$;

-- The categories with how many forms carry each, in their order (tenant.configure, reports.view or
-- performance.team: the Sources page and the report's filter)
create or replace function cma.form_categories()
returns table (code text, name text, sort_order integer, status text, forms integer)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['tenant.configure', 'reports.view', 'performance.team']);
  return query
    select c.code, c.name, c.sort_order, c.status,
           (select count(*)::integer from cma.connection_form f where f.tenant_id = c.tenant_id and f.category = c.code)
    from cma.form_category c
    where c.tenant_id = v_tenant
    order by c.sort_order, c.name, c.code;
end
$$;

-- 0008e's catalogs of a connection, the forms with their reporting, lead rule and fields (the Sources
-- page); everything else as 0008e
create or replace function cma.connection_catalogs(p_connection_id uuid)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  return jsonb_build_object(
    'forms', coalesce((select jsonb_agg(jsonb_build_object('formId', f.source_form_id, 'name', f.name, 'isCounted', f.is_counted,
                                                            'leadSource', f.lead_source, 'market', f.market,
                                                            'keptFields', to_jsonb(f.kept_fields), 'status', f.status,
                                                            'isPolled', f.is_polled, 'category', f.category,
                                                            'marketField', f.market_field, 'leadCondition', f.lead_condition,
                                                            'fieldsRefreshedAt', f.fields_refreshed_at,
                                                            'fields', coalesce((select jsonb_agg(jsonb_build_object('name', ff.name, 'kind', ff.kind,
                                                                                                                    'options', to_jsonb(ff.options))
                                                                                                 order by ff.sort_order, ff.name)
                                                                                from cma.connection_form_field ff
                                                                                where ff.tenant_id = f.tenant_id and ff.connection_id = f.connection_id
                                                                                  and ff.source_form_id = f.source_form_id and ff.status = 'active'),
                                                                               '[]'::jsonb))
                                        order by f.name, f.source_form_id)
                       from cma.connection_form f where f.tenant_id = v_tenant and f.connection_id = p_connection_id), '[]'::jsonb),
    'callOutcomes', coalesce((select jsonb_agg(jsonb_build_object('outcomeRef', o.outcome_ref, 'label', o.label,
                                                                   'isConnected', o.is_connected, 'status', o.status)
                                               order by o.label, o.outcome_ref)
                              from cma.connection_call_outcome o where o.tenant_id = v_tenant and o.connection_id = p_connection_id), '[]'::jsonb),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('lineRef', n.number_ref, 'name', n.name, 'digits', n.digits,
                                                            'market', n.market, 'isCounted', n.is_counted, 'status', n.status)
                                        order by n.name, n.number_ref)
                       from cma.telephony_number n where n.tenant_id = v_tenant and n.connection_id = p_connection_id), '[]'::jsonb),
    'tags', coalesce((select jsonb_agg(jsonb_build_object('tagRef', t.tag_ref, 'name', t.name, 'isCounted', t.is_counted,
                                                           'status', t.status)
                                       order by t.name, t.tag_ref)
                      from cma.telephony_tag t where t.tenant_id = v_tenant and t.connection_id = p_connection_id), '[]'::jsonb),
    'sampleIds', coalesce((select jsonb_object_agg(x.record_type, x.source_id)
                           from (select distinct on (r.record_type) r.record_type, r.source_id
                                 from cma.crm_record r
                                 where r.tenant_id = v_tenant and r.connection_id = p_connection_id and r.source_deleted_at is null
                                 order by r.record_type, r.source_created_at desc nulls last, r.source_id) x), '{}'::jsonb));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. The ingest writes (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- Refreshes the form catalog: [{formId, name, fields}], as 0007; counted, polled, lead source,
-- market, category, kept fields, market field and lead condition stay; a form missing from the list
-- is archived. An item with fields (an array of at most 200 {name, kind, options}) also refreshes the
-- form's field catalog: kind one of dropdown, radio, multiple_checkboxes, single_checkbox or other,
-- options (the values, at most 500, each once) for a choice field only; an option no longer listed
-- moves to retired_options, a field no longer listed is archived, and the form is marked described
-- (fields_refreshed_at). An item without fields leaves the form's fields as they are. Answers the
-- number of active forms.
create or replace function cma.ingest_upsert_forms(p_connection_id uuid, p_items jsonb)
returns integer
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  i        jsonb;
  fd       record;
  v_kind   text;
  v_opts   text[];
  v_n      integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'forms must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for i in select value from jsonb_array_elements(p_items) loop
    if coalesce(i ->> 'formId', '') = '' then
      raise exception 'every form needs a formId' using errcode = 'CMA04';
    end if;
    insert into cma.connection_form (tenant_id, connection_id, source_form_id, name, status, refreshed_at)
    values (v_tenant, p_connection_id, i ->> 'formId', left(coalesce(nullif(btrim(i ->> 'name'), ''), i ->> 'formId'), 200),
            'active', now())
    on conflict (tenant_id, connection_id, source_form_id)
      do update set name = excluded.name, status = 'active', refreshed_at = now();
    if jsonb_typeof(i -> 'fields') = 'array' then
      if jsonb_array_length(i -> 'fields') > 200 then
        raise exception 'a form has at most 200 fields' using errcode = 'CMA04';
      end if;
      for fd in select value as f, ordinality::integer as n from jsonb_array_elements(i -> 'fields') with ordinality loop
        v_kind := coalesce(fd.f ->> 'kind', 'other');
        if coalesce(fd.f ->> 'name', '') !~ '^[A-Za-z0-9_.-]{1,100}$'
           or v_kind not in ('dropdown', 'radio', 'multiple_checkboxes', 'single_checkbox', 'other')
           or (fd.f -> 'options' is not null and jsonb_typeof(fd.f -> 'options') not in ('array', 'null')) then
          raise exception 'a form field needs a name of letters, digits, _ . - and a known kind' using errcode = 'CMA04';
        end if;
        -- the options in the source's order, each once; none for a field that is no choice
        select coalesce(array_agg(o.v order by o.n), '{}') into v_opts
        from (select x.v, min(x.n) as n
              from jsonb_array_elements_text(case when cma.form_choice_kind(v_kind) and jsonb_typeof(fd.f -> 'options') = 'array'
                                                  then fd.f -> 'options' else '[]'::jsonb end) with ordinality x(v, n)
              where length(x.v) between 1 and 200
              group by x.v) o;
        insert into cma.connection_form_field as ff (tenant_id, connection_id, source_form_id, name, kind, options, sort_order, status, refreshed_at)
        values (v_tenant, p_connection_id, i ->> 'formId', fd.f ->> 'name', v_kind, v_opts[1:500], fd.n, 'active', now())
        on conflict (tenant_id, connection_id, source_form_id, name) do update
          set kind = excluded.kind, options = excluded.options, sort_order = excluded.sort_order, status = 'active', refreshed_at = now(),
              retired_options = case when cma.form_choice_kind(excluded.kind) then
                                  coalesce((select (array_agg(r order by r))[1:1000]
                                            from (select unnest(ff.options || ff.retired_options)
                                                  except select unnest(excluded.options)) x(r)), '{}')
                                else '{}' end;
      end loop;
      update cma.connection_form_field ff set status = 'archived'
      where ff.tenant_id = v_tenant and ff.connection_id = p_connection_id and ff.source_form_id = i ->> 'formId'
        and ff.status = 'active'
        and not exists (select 1 from jsonb_array_elements(i -> 'fields') x where x ->> 'name' = ff.name);
      update cma.connection_form f set fields_refreshed_at = now()
      where f.tenant_id = v_tenant and f.connection_id = p_connection_id and f.source_form_id = i ->> 'formId';
    end if;
  end loop;
  update cma.connection_form f set status = 'archived'
  where f.tenant_id = v_tenant and f.connection_id = p_connection_id and f.status = 'active'
    and not exists (select 1 from jsonb_array_elements(p_items) x where x ->> 'formId' = f.source_form_id);
  select count(*)::integer into v_n from cma.connection_form f
  where f.tenant_id = v_tenant and f.connection_id = p_connection_id and f.status = 'active';
  return v_n;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid form: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- A run finishes once, as 0007, and its counts may also hold dropped: the forms poll's answers that no
-- option of their field accounts for, which it leaves out (0008p)
create or replace function cma.ingest_sync_run_finish(p_run_id uuid, p_status text, p_counts jsonb, p_error text default null)
returns void
language plpgsql
as $$
declare
  v_status text;
begin
  perform cma.assert_permission('ingest.write');
  if p_status not in ('succeeded', 'failed') then
    raise exception 'status must be succeeded or failed' using errcode = 'CMA04';
  end if;
  if p_counts is not null and (jsonb_typeof(p_counts) <> 'object'
     or exists (select 1 from jsonb_each(p_counts) e
                where e.key not in ('fetched', 'upserted', 'stale', 'skipped', 'failed', 'dropped')
                   or jsonb_typeof(e.value) <> 'number' or (e.value #>> '{}') !~ '^\d+$')) then
    raise exception 'counts are whole numbers for fetched, upserted, stale, skipped, failed and dropped' using errcode = 'CMA04';
  end if;
  select r.status into v_status from cma.sync_run r where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id for update;
  if v_status is null then
    raise exception 'no sync run % in the current tenant', p_run_id using errcode = 'CMA02';
  end if;
  if v_status <> 'running' then
    raise exception 'sync run % is already finished', p_run_id using errcode = 'CMA03';
  end if;
  update cma.sync_run r
     set status = p_status, finished_at = now(), counts = coalesce(p_counts, '{}'::jsonb), error = left(nullif(btrim(p_error), ''), 200)
   where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id;
end
$$;

-- Records form submissions: [{sourceId, formId, submittedAt, pageHost, pagePath, utm, contactId,
-- contactResolution, keptValues}], at most 500, as 0007: the query string is cut off the page, UTM
-- keeps source, medium, campaign, term and content, a form not yet in the catalog is added (counted,
-- polled) with its id as name. keptValues are checked again for the form (cma.form_kept_values_of:
-- choice answers within the options of a described form; defence in depth, the service sends only
-- those). A known submission moves its contact resolution forward (never away from resolved), and
-- takes answers when it has none and no privacy deletion cleared them (the backfill fills them).
-- Outcomes: inserted, known, resolved, filled
create or replace function cma.ingest_upsert_form_submissions(p_connection_id uuid, p_items jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  i          jsonb;
  v_src      text;
  v_form     text;
  v_contact  text;
  v_res      text;
  v_kept     jsonb;
  v_old      cma.form_submission;
  v_path     text;
  v_host     text;
  v_resolve  boolean;
  v_fill     boolean;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'submissions must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for i in select value from jsonb_array_elements(p_items) loop
    v_src := i ->> 'sourceId';
    v_form := i ->> 'formId';
    if coalesce(v_src, '') = '' or coalesce(v_form, '') = '' then
      raise exception 'every submission needs a sourceId and a formId' using errcode = 'CMA04';
    end if;
    if (i -> 'utm') is not null and jsonb_typeof(i -> 'utm') not in ('object', 'null') then
      raise exception 'utm must be an object' using errcode = 'CMA04';
    end if;
    if (i -> 'keptValues') is not null and jsonb_typeof(i -> 'keptValues') not in ('object', 'null') then
      raise exception 'keptValues must be an object' using errcode = 'CMA04';
    end if;
    v_contact := nullif(btrim(i ->> 'contactId'), '');
    v_res := case when v_contact is not null then 'resolved'
                  else coalesce(nullif(i ->> 'contactResolution', ''), 'pending') end;
    if v_res not in ('resolved', 'no_email', 'not_found', 'ambiguous', 'pending') or (v_res = 'resolved' and v_contact is null) then
      raise exception 'contactResolution must be no_email, not_found, ambiguous or pending without a contactId, got %', v_res
        using errcode = 'CMA04';
    end if;

    select * into v_old from cma.form_submission s
    where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.source_id = v_src
    for update;
    if v_old.id is not null then
      v_resolve := v_old.contact_resolution <> 'resolved' and v_res <> v_old.contact_resolution;
      v_kept := case when v_old.kept_values = '{}'::jsonb and v_old.kept_cleared_at is null
                     then cma.form_kept_values_of(v_tenant, p_connection_id, v_old.source_form_id,
                                                  case when jsonb_typeof(i -> 'keptValues') = 'object' then i -> 'keptValues' end)
                     else '{}'::jsonb end;
      v_fill := v_kept <> '{}'::jsonb;
      if v_resolve or v_fill then
        update cma.form_submission s
           set contact_source_id = case when v_resolve then v_contact else s.contact_source_id end,
               contact_resolution = case when v_resolve then v_res else s.contact_resolution end,
               kept_values = case when v_fill then v_kept else s.kept_values end,
               synced_at = now()
        where s.tenant_id = v_tenant and s.id = v_old.id;
      end if;
      return query select v_src, case when v_resolve then 'resolved' when v_fill then 'filled' else 'known' end::text;
      continue;
    end if;

    insert into cma.connection_form (tenant_id, connection_id, source_form_id, name)
    values (v_tenant, p_connection_id, v_form, left(v_form, 200))
    on conflict (tenant_id, connection_id, source_form_id) do nothing;

    v_path := split_part(split_part(btrim(i ->> 'pagePath'), '?', 1), '#', 1);
    v_host := lower(nullif(btrim(i ->> 'pageHost'), ''));
    if v_host !~ '^[a-z0-9.-]{1,255}$' then
      v_host := null;
    end if;
    insert into cma.form_submission (tenant_id, connection_id, source_id, source_form_id, submitted_at, page_host, page_path,
                                     utm, contact_source_id, contact_resolution, kept_values)
    values (v_tenant, p_connection_id, v_src, v_form,
            coalesce(cma.json_time(i -> 'submittedAt', 'submittedAt'), now()),
            v_host, left(nullif(v_path, ''), 1000),
            coalesce((select jsonb_object_agg(e.key, left(e.value #>> '{}', 200))
                      from jsonb_each(case when jsonb_typeof(i -> 'utm') = 'object' then i -> 'utm' else '{}'::jsonb end) e
                      where e.key in ('source', 'medium', 'campaign', 'term', 'content')
                        and jsonb_typeof(e.value) in ('string', 'number')), '{}'::jsonb),
            v_contact, v_res,
            cma.form_kept_values_of(v_tenant, p_connection_id, v_form,
                                    case when jsonb_typeof(i -> 'keptValues') = 'object' then i -> 'keptValues' end));
    return query select v_src, 'inserted'::text;
  end loop;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid submission: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. The privacy deletion and Intake
-- ---------------------------------------------------------------------------------------------
-- As 0008n (contacts, refs, calls, submissions' answers, emails, threads and tasks; the answer's shape
-- unchanged), and every submission of the contact is marked (kept_cleared_at), so a later read of it
-- never fills its answers again
create or replace function cma.ingest_contact_forget(p_connection_id uuid, p_contact_source_id text)
returns jsonb
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_contact uuid;
  v_c       integer := 0;
  v_r       integer := 0;
  v_k       integer := 0;
  v_s       integer := 0;
  v_t       integer := 0;
  v_e       integer := 0;
  v_h       integer := 0;
  v_tk      integer := 0;
  v_res     jsonb;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if coalesce(p_contact_source_id, '') = '' then
    raise exception 'a contact id is needed' using errcode = 'CMA04';
  end if;
  update cma.crm_contact cc
     set country = null, country_source = null, language = null, currency = null, store = null, raw = '{}'::jsonb,
         source_deleted_at = coalesce(cc.source_deleted_at, now()), synced_at = now()
   where cc.tenant_id = v_tenant and cc.connection_id = p_connection_id and cc.source_id = p_contact_source_id
  returning cc.id into v_contact;
  get diagnostics v_c = row_count;
  if v_contact is not null then
    delete from cma.crm_contact_ref r where r.tenant_id = v_tenant and r.contact_id = v_contact;
    get diagnostics v_r = row_count;
  end if;
  -- telephony calls linked to the contact's CRM calls (whether or not those still hold a hash)
  update cma.telephony_call t set counterpart_hash = null, synced_at = now()
  where t.tenant_id = v_tenant and t.counterpart_hash is not null
    and exists (select 1 from cma.call_link l
                join cma.crm_call k on k.tenant_id = l.tenant_id and k.id = l.crm_call_id
                join cma.crm_association a
                  on a.tenant_id = k.tenant_id and a.connection_id = k.connection_id
                 and a.from_type = 'crm_call' and a.from_id = k.source_id
                 and a.to_type = 'contact' and a.to_id = p_contact_source_id
                where l.tenant_id = t.tenant_id and l.telephony_call_id = t.id
                  and k.connection_id = p_connection_id);
  get diagnostics v_t = row_count;
  update cma.crm_call k set counterpart_hash = null, synced_at = now()
  where k.tenant_id = v_tenant and k.connection_id = p_connection_id and k.counterpart_hash is not null
    and exists (select 1 from cma.crm_association a
                where a.tenant_id = k.tenant_id and a.connection_id = k.connection_id
                  and a.from_type = 'crm_call' and a.from_id = k.source_id
                  and a.to_type = 'contact' and a.to_id = p_contact_source_id);
  get diagnostics v_k = row_count;
  update cma.form_submission s set kept_values = '{}'::jsonb, kept_cleared_at = coalesce(s.kept_cleared_at, now()), synced_at = now()
  where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.contact_source_id = p_contact_source_id
    and s.kept_values <> '{}'::jsonb;
  get diagnostics v_s = row_count;
  -- 0008p: the contact's submissions without answers are marked too, so a later read never fills them
  update cma.form_submission s set kept_cleared_at = now()
  where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.contact_source_id = p_contact_source_id
    and s.kept_cleared_at is null;
  update cma.email_message em set contact_source_id = null, synced_at = now()
  where em.tenant_id = v_tenant and em.connection_id = p_connection_id and em.contact_source_id = p_contact_source_id;
  get diagnostics v_e = row_count;
  update cma.email_thread et set contact_source_id = null, synced_at = now()
  where et.tenant_id = v_tenant and et.connection_id = p_connection_id and et.contact_source_id = p_contact_source_id;
  get diagnostics v_h = row_count;
  update cma.crm_task tk set contact_source_id = null, synced_at = now()
  where tk.tenant_id = v_tenant and tk.connection_id = p_connection_id and tk.contact_source_id = p_contact_source_id;
  get diagnostics v_tk = row_count;
  v_res := jsonb_build_object('contacts', v_c, 'refs', v_r, 'calls', v_k, 'submissions', v_s);
  if v_t > 0 then
    v_res := v_res || jsonb_build_object('telephony_calls', v_t);
  end if;
  if v_e > 0 then
    v_res := v_res || jsonb_build_object('emails', v_e);
  end if;
  if v_h > 0 then
    v_res := v_res || jsonb_build_object('threads', v_h);
  end if;
  if v_tk > 0 then
    v_res := v_res || jsonb_build_object('tasks', v_tk);
  end if;
  return v_res;
end
$$;

-- As 0007d, and a counted form's submission counts only when it is a lead by its form's condition
-- (cma.form_is_lead: no condition, or the kept answer is one of the condition's values). A form that
-- is polled and does not count never counts, as before
create or replace function cma.intake_per_day_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns setof cma.intake_per_day_row
language sql stable
as $$
  with s as (
    select t.timezone as zone,
           greatest(coalesce(p_from, '-infinity'::timestamptz),
                    cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone) as from_at,
           coalesce(p_to, 'infinity'::timestamptz) as to_at
    from cma.tenant t where t.id = p_tenant_id
  ),
  e as (
    select fs.submitted_at as at, coalesce(cma.market_code_of(p_tenant_id, f.market), 'unknown') as market, 'form' as metric
    from cma.form_submission fs
    join cma.connection_form f
      on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
    cross join s
    where fs.tenant_id = p_tenant_id and f.is_counted and cma.form_is_lead(f.lead_condition, fs.kept_values)
      and fs.submitted_at >= s.from_at and fs.submitted_at < s.to_at
    union all
    select x.at, rm.code, x.metric
    from (select cr.*, cr.source_created_at as at, cr.record_type || '_created' as metric
          from cma.crm_record cr
          union all
          select cr.*, cr.closed_at, cr.record_type || '_closed'
          from cma.crm_record cr where cr.is_closed and cr.closed_at is not null) x
    left join cma.connection_pipeline p
      on p.tenant_id = x.tenant_id and p.connection_id = x.connection_id
     and p.record_type = x.record_type and p.source_pipeline_id = x.pipeline_id
    cross join s
    cross join lateral cma.record_market_of(x.tenant_id, x.connection_id, x.market, x.contact_source_id) rm
    where x.tenant_id = p_tenant_id and x.record_type in ('deal', 'ticket') and x.source_deleted_at is null
      and coalesce(p.is_counted, true) and x.at >= s.from_at and x.at < s.to_at
    union all
    select tc.started_at, coalesce(cma.market_code_of(p_tenant_id, n.market), 'unknown'), m.metric
    from cma.telephony_call tc
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    cross join s
    cross join lateral (
      select case tc.direction when 'inbound' then 'call_in' else 'call_out' end as metric
      union all
      select 'call_tagged'
      where exists (select 1 from cma.telephony_call_tag ct
                    left join cma.telephony_tag tg
                      on tg.tenant_id = ct.tenant_id and tg.connection_id = ct.connection_id and tg.tag_ref = ct.tag_ref
                    where ct.tenant_id = tc.tenant_id and ct.connection_id = tc.connection_id
                      and ct.call_source_id = tc.source_id and ct.untagged_at is null and coalesce(tg.is_counted, true))) m
    where tc.tenant_id = p_tenant_id and tc.source_deleted_at is null and coalesce(n.is_counted, true)
      and tc.started_at >= s.from_at and tc.started_at < s.to_at
    union all
    select cu.source_created_at, coalesce(cma.market_code_of(p_tenant_id, st.market), 'unknown'), 'customer'
    from cma.commerce_customer cu
    left join cma.commerce_store st on st.tenant_id = cu.tenant_id and st.connection_id = cu.connection_id
    cross join s
    where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null
      and cu.source_created_at >= s.from_at and cu.source_created_at < s.to_at
    union all
    select co.source_created_at, coalesce(cma.market_code_of(p_tenant_id, st.market), 'unknown'), 'order_' || co.order_kind
    from cma.commerce_order co
    left join cma.commerce_store st on st.tenant_id = co.tenant_id and st.connection_id = co.connection_id
    cross join s
    where co.tenant_id = p_tenant_id and co.source_deleted_at is null and not co.is_test and co.cancelled_at is null
      and co.source_created_at >= s.from_at and co.source_created_at < s.to_at
  )
  select p_tenant_id, (e.at at time zone s.zone)::date, e.market,
         (count(*) filter (where e.metric = 'form'))::integer,
         (count(*) filter (where e.metric = 'deal_created'))::integer,
         (count(*) filter (where e.metric = 'deal_closed'))::integer,
         (count(*) filter (where e.metric = 'ticket_created'))::integer,
         (count(*) filter (where e.metric = 'ticket_closed'))::integer,
         (count(*) filter (where e.metric = 'call_in'))::integer,
         (count(*) filter (where e.metric = 'call_out'))::integer,
         (count(*) filter (where e.metric = 'call_tagged'))::integer,
         (count(*) filter (where e.metric = 'customer'))::integer,
         (count(*) filter (where e.metric = 'order_first'))::integer,
         (count(*) filter (where e.metric = 'order_repeat'))::integer,
         (count(*) filter (where e.metric = 'order_renewal'))::integer
  from e cross join s
  group by 2, 3
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. The report's reads
-- ---------------------------------------------------------------------------------------------
-- The submissions of a tenant made in [p_from, p_to), every stored one (whatever the form's polled
-- and counted are now), one row each with the form's name and category, the submission's market and
-- the step that gave it (cma.form_submission_market_of), its zone (the market's, else the tenant's),
-- business date, ISO week and time of day there, the contact resolution and the kept answers. No
-- submission id, no contact id. Both bounds are required, so the read keeps to the index on the
-- tenant and the time (0008k: an unbounded read scans every row)
create or replace function cma.form_submissions_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  connection_id  uuid,
  form_id        text,
  form_name      text,
  category       text,
  is_counted     boolean,
  market         text,
  market_source  text,
  zone           text,
  submitted_at   timestamptz,
  business_date  date,
  week_start     date,
  local_time     time,
  resolution     text,
  kept_values    jsonb
)
language sql stable
as $$
  with s as (select t.timezone as tenant_zone from cma.tenant t where t.id = p_tenant_id)
  select fs.connection_id, fs.source_form_id, f.name, f.category, f.is_counted,
         sm.code, sm.source, z.zone, fs.submitted_at,
         (fs.submitted_at at time zone z.zone)::date,
         date_trunc('week', (fs.submitted_at at time zone z.zone)::date::timestamp)::date,
         (fs.submitted_at at time zone z.zone)::time,
         fs.contact_resolution, fs.kept_values
  from cma.form_submission fs
  join cma.connection_form f
    on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
  cross join s
  cross join lateral cma.form_submission_market_of(p_tenant_id, fs.connection_id, f.market, f.market_field, fs.kept_values,
                                                   fs.contact_source_id) sm
  cross join lateral (select coalesce((select m.time_zone from cma.market m where m.tenant_id = p_tenant_id and m.code = sm.code),
                                      s.tenant_zone) as zone) z
  where fs.tenant_id = p_tenant_id and fs.submitted_at >= p_from and fs.submitted_at < p_to
$$;

-- The submissions of the business dates [p_from, p_to] (each in its own zone) per day or ISO week
-- (its Monday), form and market, then the period's totals per form and market (group_key null), with
-- the contact resolution: resolved, not found, ambiguous, no email, pending. The filters narrow before
-- anything is counted: p_market a market code or 'unknown', p_category a category code or 'none' for
-- forms without one, p_form connection id ':' form id; null for all. With p_until (the previous span of
-- a period that reaches today) the submissions of p_to count only up to p_until's time of day in each
-- submission's own zone (as 0008j)
create or replace function cma.forms_figures_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_category text, p_form text,
                                                p_group text, p_until timestamptz default null)
returns table (
  group_key      text,
  connection_id  uuid,
  form_id        text,
  form_name      text,
  category       text,
  market         text,
  submissions    integer,
  resolved       integer,
  not_found      integer,
  ambiguous      integer,
  no_email       integer,
  pending        integer
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  x as (
    -- a day on each side, so a market in another zone than the tenant's keeps its whole dates
    select r.* from s
    cross join lateral cma.form_submissions_of(p_tenant_id, (p_from - 1)::timestamp at time zone s.zone,
                                               (p_to + 2)::timestamp at time zone s.zone) r
    where r.business_date between p_from and p_to
      and (p_until is null or r.business_date < p_to or r.local_time <= (p_until at time zone r.zone)::time)
      and (p_market is null or r.market = p_market)
      and (p_category is null or coalesce(r.category, 'none') = p_category)
      and (p_form is null or r.connection_id::text || ':' || r.form_id = p_form)
  )
  select case when grouping(g.k) = 0 then g.k end, x.connection_id, x.form_id, x.form_name, x.category, x.market,
         count(*)::integer,
         (count(*) filter (where x.resolution = 'resolved'))::integer,
         (count(*) filter (where x.resolution = 'not_found'))::integer,
         (count(*) filter (where x.resolution = 'ambiguous'))::integer,
         (count(*) filter (where x.resolution = 'no_email'))::integer,
         (count(*) filter (where x.resolution = 'pending'))::integer
  from x
  cross join lateral (select case p_group when 'week' then x.week_start::text else x.business_date::text end as k) g
  group by grouping sets ((g.k, x.connection_id, x.form_id, x.form_name, x.category, x.market),
                          (x.connection_id, x.form_id, x.form_name, x.category, x.market))
  order by grouping(g.k), g.k, x.form_name, x.form_id, x.market
$$;

-- The previous span of a period, like for like (0008j): as many dates before p_from as the period
-- holds; a period that ended compares with the whole previous equal period, one that reaches today
-- (p_now's date in the tenant's zone) with the same elapsed dates, the last of them up to p_now's time
-- of day (until); a period that starts after today has no elapsed date (prev_to before prev_from)
create or replace function cma.forms_previous_of(p_tenant_id uuid, p_from date, p_to date, p_now timestamptz,
                                                 out prev_from date, out prev_to date, out until timestamptz)
language sql stable
as $$
  select p_from - (p_to - p_from + 1), least(p_to, (p_now at time zone t.timezone)::date) - (p_to - p_from + 1),
         case when p_to >= (p_now at time zone t.timezone)::date then p_now end
  from cma.tenant t where t.id = p_tenant_id
$$;

-- The report: the period's rows ('current': per group, form and market, then the totals per form and
-- market) and the previous period's totals per form and market ('previous'), like for like.
-- p_now is now() for the application; a verifier gives a fixed instant
create or replace function cma.forms_report_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_market text, p_category text,
                                               p_form text, p_now timestamptz default now())
returns table (
  period         text,
  group_key      text,
  connection_id  uuid,
  form_id        text,
  form_name      text,
  category       text,
  market         text,
  submissions    integer,
  resolved       integer,
  not_found      integer,
  ambiguous      integer,
  no_email       integer,
  pending        integer
)
language sql stable
as $$
  select x.period, x.group_key, x.connection_id, x.form_id, x.form_name, x.category, x.market, x.submissions, x.resolved,
         x.not_found, x.ambiguous, x.no_email, x.pending
  from (
    select 'current'::text as period, 1 as part, f.*
    from cma.forms_figures_of(p_tenant_id, p_from, p_to, p_market, p_category, p_form, p_group) with ordinality f
    union all
    select 'previous', 2, f.*
    from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now) v
    cross join lateral cma.forms_figures_of(p_tenant_id, v.prev_from, v.prev_to, p_market, p_category, p_form, p_group, v.until)
      with ordinality f
    where f.group_key is null
  ) x
  order by x.part, x.ordinality
$$;

-- The answers: per form, market, kept field and value the submissions answering it, over the period
-- ('current') and the previous period like for like ('previous'); a multiple-checkboxes answer counts
-- under each of its values. Filters as the report's, plus p_field (a field name) and p_value (a value)
create or replace function cma.forms_answers_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_category text, p_form text,
                                                p_field text, p_value text, p_now timestamptz default now())
returns table (
  period         text,
  connection_id  uuid,
  form_id        text,
  form_name      text,
  category       text,
  market         text,
  field          text,
  value          text,
  submissions    integer
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  v as (select * from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now)),
  a as (
    select 'current'::text as period, 1 as part, r.*
    from s
    cross join lateral cma.form_submissions_of(p_tenant_id, (p_from - 1)::timestamp at time zone s.zone,
                                               (p_to + 2)::timestamp at time zone s.zone) r
    where r.business_date between p_from and p_to
    union all
    select 'previous', 2, r.*
    from s cross join v
    cross join lateral cma.form_submissions_of(p_tenant_id, (v.prev_from - 1)::timestamp at time zone s.zone,
                                               (v.prev_to + 2)::timestamp at time zone s.zone) r
    where r.business_date between v.prev_from and v.prev_to
      and (v.until is null or r.business_date < v.prev_to or r.local_time <= (v.until at time zone r.zone)::time)
  )
  select a.period, a.connection_id, a.form_id, a.form_name, a.category, a.market, e.key, ans.value, count(*)::integer
  from a
  cross join lateral jsonb_each(a.kept_values) e
  cross join lateral (select e.value #>> '{}' as value where jsonb_typeof(e.value) = 'string'
                      union all
                      select x from jsonb_array_elements_text(case when jsonb_typeof(e.value) = 'array' then e.value else '[]'::jsonb end) x) ans
  where (p_market is null or a.market = p_market)
    and (p_category is null or coalesce(a.category, 'none') = p_category)
    and (p_form is null or a.connection_id::text || ':' || a.form_id = p_form)
    and (p_field is null or e.key = p_field)
    and (p_value is null or ans.value = p_value)
  group by a.part, a.period, a.connection_id, a.form_id, a.form_name, a.category, a.market, e.key, ans.value
  order by a.part, a.form_name, a.form_id, a.market, e.key, count(*) desc, ans.value
$$;

-- The business date of the tenant's earliest stored submission (any form), or null without one (as
-- 0008k): tenant-wide, the filters do not narrow it. The earliest submission by time is found on the
-- index; the earliest business date is among the submissions up to two days after it (zones differ by
-- at most 26 hours)
create or replace function cma.forms_history_start_of(p_tenant_id uuid)
returns date
language plpgsql stable
as $$
declare
  v_first timestamptz;
  v_to    timestamptz;
begin
  select min(fs.submitted_at) into v_first from cma.form_submission fs where fs.tenant_id = p_tenant_id;
  if v_first is null then
    return null;
  end if;
  -- the bound a value of its own, so the read gets it as a constant and uses the index
  v_to := v_first + interval '2 days';
  return (select min(r.business_date) from cma.form_submissions_of(p_tenant_id, v_first, v_to) r);
end
$$;

-- The filters every read takes: a market is a two-letter code or 'unknown'; a category a category
-- code or 'none'; a form a connection id ':' form id; a field a field name; a value 1 to 200
-- characters. Anything else CMA04
create or replace function cma.forms_filters_check(p_market text, p_category text, p_form text, p_field text, p_value text)
returns void
language plpgsql immutable
as $$
begin
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'a market filter is a market code or unknown, not %', p_market using errcode = 'CMA04';
  end if;
  if p_category is not null and p_category !~ '^[a-z][a-z0-9_]{0,39}$' then
    raise exception 'a category filter is a category code or none, not %', p_category using errcode = 'CMA04';
  end if;
  if p_form is not null and p_form !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:.{1,100}$' then
    raise exception 'a form filter is a connection id and a form id, not %', p_form using errcode = 'CMA04';
  end if;
  if p_field is not null and p_field !~ '^[A-Za-z0-9_.-]{1,100}$' then
    raise exception 'a field filter is a field name, not %', p_field using errcode = 'CMA04';
  end if;
  if p_value is not null and length(p_value) not between 1 and 200 then
    raise exception 'a value filter has 1 to 200 characters' using errcode = 'CMA04';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 11. The application's reads (permission checked, filters checked, current tenant, row-level security)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.forms_report(p_from date, p_to date, p_group text, p_market text, p_category text, p_form text)
returns table (
  period         text,
  group_key      text,
  connection_id  uuid,
  form_id        text,
  form_name      text,
  category       text,
  market         text,
  submissions    integer,
  resolved       integer,
  not_found      integer,
  ambiguous      integer,
  no_email       integer,
  pending        integer
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'week') then
    raise exception 'group by day or week, not %', p_group using errcode = 'CMA04';
  end if;
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.forms_filters_check(p_market, p_category, p_form, null, null);
  return query select * from cma.forms_report_of(v_tenant, p_from, p_to, p_group, p_market, p_category, p_form);
end
$$;

create or replace function cma.forms_answers(p_from date, p_to date, p_market text, p_category text, p_form text, p_field text, p_value text)
returns table (
  period         text,
  connection_id  uuid,
  form_id        text,
  form_name      text,
  category       text,
  market         text,
  field          text,
  value          text,
  submissions    integer
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.forms_filters_check(p_market, p_category, p_form, p_field, p_value);
  return query select * from cma.forms_answers_of(v_tenant, p_from, p_to, p_market, p_category, p_form, p_field, p_value);
end
$$;

create or replace function cma.forms_history_start()
returns date
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  return cma.forms_history_start_of(v_tenant);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 12. Data quality: kept answers no option accounts for
-- ---------------------------------------------------------------------------------------------
-- The forms reporting's check, listed apart and shown after 0008o's, as 0008o lists its own: 0008m's
-- cma.data_quality_added_checks() and 0008o's cma.data_quality_follow_up_checks() stay as they are (69
-- and 73 pin them), and 0007d's fifteen as well (41, which has run in prod, pins them and their totals)
create or replace function cma.data_quality_forms_checks()
returns table (check_key text, sort_order integer, description text)
language sql immutable
as $$
  values
    ('form_answer_not_in_options', 200, 'Kept form answers that are no option of their field (none by construction; earlier values show here)')
$$;

-- 0008o's findings, plus form_answer_not_in_options: per submission and field of a described form, an
-- answer whose field is no choice field of the form or whose value is no option of it, current or
-- retired. 0008p's write keeps no such answer, so it finds only values kept under 0007's rule before
-- the source described the form
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
                    where not (a.v = any (ff.options || ff.retired_options))));

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

-- 0008o's totals per check, plus form_answer_not_in_options: listed once the tenant keeps answers of a
-- described form, or while it finds one (muted at zero on the Data page). A tenant with none of the
-- added checks' conditions keeps 0007d's fifteen rows exactly
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
    )
    select c.check_key, c.description,
           case when c.check_key = 'writeback_parked' and to_regclass('cma.outbox_action') is null then null
                else (select count(*) from q where q.check_key = c.check_key)::integer end
    from c
    order by c.sort_order;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 13. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.set_form(uuid,text,boolean,text,text,text[])',
    'cma.set_form_reporting(uuid,text,boolean,text,text)',
    'cma.set_form_market_field(uuid,text,text)',
    'cma.set_form_lead_condition(uuid,text,text,text[])',
    'cma.set_form_category(text,text,integer)',
    'cma.set_form_category_status(text,text)',
    'cma.form_categories()',
    'cma.connection_catalogs(uuid)',
    'cma.ingest_upsert_forms(uuid,jsonb)',
    'cma.ingest_upsert_form_submissions(uuid,jsonb)',
    'cma.ingest_sync_run_finish(uuid,text,jsonb,text)',
    'cma.ingest_contact_forget(uuid,text)',
    'cma.forms_report(date,date,text,text,text,text)',
    'cma.forms_answers(date,date,text,text,text,text,text)',
    'cma.forms_history_start()',
    'cma.data_quality_of(uuid)',
    'cma.data_quality()',
    'cma.data_quality_forms_checks()',
    -- the reads of an explicit tenant, which the functions above call in the caller's rights
    -- (row-level security keeps them to the current tenant whatever tenant they are given)
    'cma.intake_per_day_of(uuid,timestamptz,timestamptz)',
    'cma.form_submissions_of(uuid,timestamptz,timestamptz)',
    'cma.forms_figures_of(uuid,date,date,text,text,text,text,timestamptz)',
    'cma.forms_previous_of(uuid,date,date,timestamptz)',
    'cma.forms_report_of(uuid,date,date,text,text,text,text,timestamptz)',
    'cma.forms_answers_of(uuid,date,date,text,text,text,text,text,timestamptz)',
    'cma.forms_history_start_of(uuid)',
    'cma.forms_filters_check(text,text,text,text,text)',
    -- helpers the functions and the tables' checks call in the caller's rights
    'cma.form_choice_kind(text)',
    'cma.form_options_ok(text[])',
    'cma.form_kept_values_ok(jsonb)',
    'cma.form_lead_condition_ok(jsonb)',
    'cma.form_answer_of(text,text[],jsonb)',
    'cma.form_kept_values_of(uuid,uuid,text,jsonb)',
    'cma.form_is_lead(jsonb,jsonb)',
    'cma.form_submission_market_of(uuid,uuid,text,text,jsonb,text)',
    'cma.form_kept_fields_check(uuid,text,text[])'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 14. Reporting views
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.form_category as
  select id, tenant_id, code, name, sort_order, status, created_at, updated_at
  from cma.form_category
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.connection_form_field as
  select tenant_id, connection_id, source_form_id, name, kind, options, retired_options, sort_order, status, refreshed_at, updated_at
  from cma.connection_form_field
  where cma_read.reader_sees(tenant_id);

-- 0007's views with the new columns at the end (the earlier columns as they were)
create or replace view cma_read.connection_form as
  select tenant_id, connection_id, source_form_id, name, is_counted, lead_source, market, kept_fields, status, refreshed_at,
         is_polled, category, market_field, lead_condition, fields_refreshed_at
  from cma.connection_form
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.form_submission as
  select id, tenant_id, connection_id, source_id, source_form_id, submitted_at, page_host, page_path, utm,
         contact_source_id, contact_resolution, kept_values, synced_at, kept_cleared_at
  from cma.form_submission
  where cma_read.reader_sees(tenant_id);

-- The added data-quality check's view, as 0007d's dq_ views (ids and codes only)
create or replace view cma_read.dq_form_answer_not_in_options as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'form_answer_not_in_options';

-- ---------------------------------------------------------------------------------------------
-- 15. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008p', 'Forms reporting: forms polled apart from counted, form categories as configuration, the forms'' fields with their options, choice answers only (checked against the options, filled by the backfill, never after a privacy deletion), the lead rule on Intake''s form count, the market of a submission (form, market field, contact), submissions and answers per form and market per day or week with the previous period like for like, the history start, the data-quality check form_answer_not_in_options')
on conflict (version) do nothing;

commit;
reset role;
