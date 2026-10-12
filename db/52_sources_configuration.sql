-- =============================================================================================
-- 52_sources_configuration.sql: addition 0008e, the reads behind the Sources, Markets and Alert rules
-- configuration screens, the connection's kind, and linked accounts on People
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 50_legacy_time_import.sql (0008d). Rerunnable, forward-only, in one transaction. Run as your own
-- IAM login, dev first, then prod; then 53_verify_sources_configuration.sql (dev), then
-- 33_verify_intake_core.sql and 31_verify_ingest_crm_records.sql again (unchanged).
--
-- Every write of the screens goes through a function that exists since 0006 to 0008a
-- (set_connection_settings, set_connection_status, upsert_connection for the name,
-- set_connection_pipeline, set_pipeline_lead, set_form, set_call_outcome, set_telephony_number,
-- set_telephony_tag, upsert_commerce_store, upsert_market, set_market_status, set_market_alias,
-- remove_market_alias, set_business_hours, set_business_holiday, remove_business_holiday,
-- upsert_message_rule, upsert_assignment_rule, set_message_rule_enabled, set_user_external_id,
-- remove_user_external_id). This addition holds only what had no function (README Decision log,
-- 13 October 2026, night):
--
--   connection kind    integration_connection.kind: crm, telephony, commerce or automation, the kind
--                      of source a connection is in the data model's terms (the tables its data lands
--                      in), never a vendor. Null until set; existing connections take the one kind
--                      their rows imply. cma.set_connection_kind() sets it (tenant.configure) and
--                      refuses a kind that contradicts the rows the connection holds (CMA03). The
--                      screens decide which sections a connection has from it, and Linked accounts
--                      which id a person can hold: <adapter>_owner for a crm connection,
--                      <adapter>_user for a telephony connection, the vocabulary the reads of 0007d
--                      already match on. cma_read.integration_connection gains the column
--   sources            cma.sources(): every connection with its kind, the kinds its rows imply, its
--                      non-secret settings, secret names (names, never values), events and the size
--                      of its catalogs (tenant.configure)
--   catalogs           cma.connection_catalogs(connection): its forms, call outcomes, lines and tags
--                      with their configuration, and the newest record id per record type for the
--                      record link preview (ids only; tenant.configure)
--   markets            cma.markets_all() with their aliases, cma.business_hours_all(),
--                      cma.business_holidays_all() (tenant.configure)
--   alert rules        cma.message_rules(): every rule of both triggers with its alerts in the last
--                      30 days (tenant.configure; brief B14)
--   linked accounts    cma.linked_account_systems(): the ids a person can hold, from the tenant's crm
--                      and telephony connections and the ids already held; cma.linked_accounts(): the
--                      ids held by the people the caller may see on People (users.manage_agents or
--                      users.manage_all, the directory's scope)
--   people's ids       cma.set_user_external_id() and cma.remove_user_external_id() as in 0007, with
--                      the People rule instead of users.manage_all: a manager links agents, an admin
--                      anyone (cma.assert_may_manage of 0004). The order of the checks is unchanged,
--                      so 33 F1 and F2 hold as before; an id another person holds stays CMA03
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
  if not exists (select 1 from cma.schema_migration where version = '0008d') then
    raise exception 'addition 0008d (50_legacy_time_import.sql) must run before 0008e';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The connection's kind
-- ---------------------------------------------------------------------------------------------
alter table cma.integration_connection add column if not exists kind text;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'cma.integration_connection'::regclass
                 and conname = 'integration_connection_kind_check') then
    alter table cma.integration_connection add constraint integration_connection_kind_check
      check (kind in ('crm', 'telephony', 'commerce', 'automation'));
  end if;
end
$$;
comment on column cma.integration_connection.kind is
  'The kind of source in the data model''s terms (crm, telephony, commerce, automation), never a vendor; null until set (0008e)';

-- The kinds a connection's rows imply, for an explicit tenant: crm when it holds CRM records,
-- contacts, calls, pipelines, forms, call outcomes, field mappings or write-back fields; telephony
-- when it holds telephony calls, tags or lines; commerce when it holds a store, customers or orders.
-- An automation connection holds no rows of its own. Runs in the caller's rights.
create or replace function cma.connection_held_kinds_of(p_tenant_id uuid, p_connection_id uuid)
returns text[]
language sql stable
as $$
  select array_remove(array[
    case when exists (select 1 from cma.crm_record x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_contact x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_pipeline x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_form x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_call_outcome x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.writeback_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'crm' end,
    case when exists (select 1 from cma.telephony_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_tag x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_number x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'telephony' end,
    case when exists (select 1 from cma.commerce_store x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.commerce_customer x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.commerce_order x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'commerce' end], null)
$$;

-- Existing connections take the one kind their rows imply; a connection with rows of no kind (an
-- automation connection, a connection without events yet) or of two kinds stays unset
update cma.integration_connection c
set kind = (cma.connection_held_kinds_of(c.tenant_id, c.id))[1]
where c.kind is null and cardinality(cma.connection_held_kinds_of(c.tenant_id, c.id)) = 1;

create or replace function cma.set_connection_kind(p_connection_id uuid, p_kind text)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_held   text[];
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if coalesce(p_kind, '') not in ('crm', 'telephony', 'commerce', 'automation') then
    raise exception 'kind must be crm, telephony, commerce or automation' using errcode = 'CMA04';
  end if;
  v_held := cma.connection_held_kinds_of(v_tenant, p_connection_id);
  if cardinality(v_held) > 0 and not (p_kind = any (v_held)) then
    raise exception 'the connection holds % data; its kind cannot be %', array_to_string(v_held, ' and '), p_kind
      using errcode = 'CMA03';
  end if;
  update cma.integration_connection c set kind = p_kind
  where c.tenant_id = v_tenant and c.id = p_connection_id and c.kind is distinct from p_kind;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Sources: the connections with their kind, settings and catalogs (tenant.configure)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.sources()
returns table (
  connection_id        uuid,
  key                  text,
  adapter              text,
  name                 text,
  external_account_id  text,
  kind                 text,
  held_kinds           text[],
  status               text,
  signing_secret_name  text,
  token_secret_name    text,
  settings             jsonb,
  events_24h           integer,
  events_waiting       integer,
  events_needs_review  integer,
  last_event_at        timestamptz,
  pipelines            integer,
  forms                integer,
  call_outcomes        integer,
  fields               integer,
  lines                integer,
  tags                 integer,
  store_handle         text
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select c.id, c.key::text, c.adapter::text, c.name::text, c.external_account_id::text, c.kind::text,
           cma.connection_held_kinds_of(c.tenant_id, c.id), c.status::text,
           c.signing_secret_name::text, c.token_secret_name::text, c.settings,
           (select count(*)::integer from cma.ingest_event e where e.tenant_id = c.tenant_id and e.connection_id = c.id and e.recorded_at > now() - interval '24 hours'),
           (select count(*)::integer from cma.ingest_event e where e.tenant_id = c.tenant_id and e.connection_id = c.id and e.status in ('received', 'failed')),
           (select count(*)::integer from cma.ingest_event e where e.tenant_id = c.tenant_id and e.connection_id = c.id and e.status = 'needs_review'),
           (select max(e.recorded_at) from cma.ingest_event e where e.tenant_id = c.tenant_id and e.connection_id = c.id),
           (select count(*)::integer from cma.connection_pipeline x where x.tenant_id = c.tenant_id and x.connection_id = c.id),
           (select count(*)::integer from cma.connection_form x where x.tenant_id = c.tenant_id and x.connection_id = c.id),
           (select count(*)::integer from cma.connection_call_outcome x where x.tenant_id = c.tenant_id and x.connection_id = c.id),
           (select count(*)::integer from cma.connection_field x where x.tenant_id = c.tenant_id and x.connection_id = c.id),
           (select count(*)::integer from cma.telephony_number x where x.tenant_id = c.tenant_id and x.connection_id = c.id),
           (select count(*)::integer from cma.telephony_tag x where x.tenant_id = c.tenant_id and x.connection_id = c.id),
           (select s.handle::text from cma.commerce_store s where s.tenant_id = c.tenant_id and s.connection_id = c.id)
    from cma.integration_connection c
    where c.tenant_id = cma.current_tenant_id()
    order by c.name, c.id;
end
$$;

-- One connection's catalogs with their configuration, for the Sources screen. sampleIds holds the
-- newest record id per record type (ids only), so a record link template can be previewed.
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
                                                            'keptFields', to_jsonb(f.kept_fields), 'status', f.status)
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
-- 3. Markets with their aliases, office hours and holidays (tenant.configure)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.markets_all()
returns table (
  code                text,
  name                text,
  time_zone           text,
  language_code       text,
  language_skill_key  text,
  min_language_level  smallint,
  currency            text,
  status              text,
  sort_order          integer,
  aliases             text[]
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select m.code::text, m.name::text, m.time_zone::text, m.language_code::text, m.language_skill_key::text,
           m.min_language_level, m.currency::text, m.status::text, m.sort_order,
           coalesce((select array_agg(a.alias::text order by a.alias) from cma.market_alias a
                     where a.tenant_id = m.tenant_id and a.code = m.code), '{}'::text[])
    from cma.market m
    where m.tenant_id = cma.current_tenant_id()
    order by (m.status <> 'active'), m.sort_order, m.code;
end
$$;

-- Office hours per market ('*' is the default) and weekday as one text, the form set_business_hours takes
create or replace function cma.business_hours_all()
returns table (market text, weekday smallint, hours text)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select h.market::text, h.weekday,
           string_agg(to_char(h.opens_at, 'HH24:MI') || '-' || case when h.closes_at = '24:00'::time then '24:00'
                                                                     else to_char(h.closes_at, 'HH24:MI') end,
                      ',' order by h.opens_at)
    from cma.business_hours h
    where h.tenant_id = cma.current_tenant_id()
    group by h.market, h.weekday
    order by (h.market <> '*'), h.market, h.weekday;
end
$$;

create or replace function cma.business_holidays_all()
returns table (market text, day date, name text)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select b.market::text, b.day, b.name::text
    from cma.business_holiday b
    where b.tenant_id = cma.current_tenant_id()
    order by b.day, (b.market <> '*'), b.market;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Alert rules (tenant.configure)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.message_rules()
returns table (
  rule_id              uuid,
  name                 text,
  trigger              text,
  record_type          text,
  pipeline_ids         text[],
  audience_permission  text,
  match_language       boolean,
  only_clocked_in      boolean,
  fallback_permission  text,
  urgency              text,
  enabled              boolean,
  max_age_minutes      integer,
  alerts_30d           integer,
  last_alert_at        timestamptz
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select r.id, r.name::text, r.trigger::text, r.record_type::text, r.pipeline_ids, r.audience_permission::text,
           r.match_language, r.only_clocked_in, r.fallback_permission::text, r.urgency::text, r.enabled,
           r.max_age_minutes,
           (select count(*)::integer from cma.message m
            where m.tenant_id = r.tenant_id and m.rule_id = r.id and m.created_at > now() - interval '30 days'),
           (select max(m.created_at) from cma.message m where m.tenant_id = r.tenant_id and m.rule_id = r.id)
    from cma.message_rule r
    where r.tenant_id = cma.current_tenant_id()
    order by (not r.enabled), r.name;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Linked accounts on People (users.manage_agents or users.manage_all, the directory's scope)
-- ---------------------------------------------------------------------------------------------
-- The ids a person can hold: <adapter>_owner per crm connection, <adapter>_user per telephony
-- connection, plus every such system someone already holds an id for, so an id never disappears
-- from the screen when its connection is switched off or its kind changes
create or replace function cma.linked_account_systems()
returns table (system text, role text, connections text[], is_active boolean)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_any_permission(array['users.manage_agents', 'users.manage_all']);
  return query
    with conn as (
      select c.adapter || case c.kind when 'crm' then '_owner' else '_user' end as system, c.name, c.status
      from cma.integration_connection c
      where c.tenant_id = cma.current_tenant_id() and c.kind in ('crm', 'telephony')
    ), held as (
      select distinct x.system from cma.app_user_external_id x
      where x.tenant_id = cma.current_tenant_id() and x.system ~ '^[a-z0-9]+_(owner|user)$'
    ), systems as (
      select conn.system from conn union select held.system from held
    )
    select s.system::text,
           case when s.system like '%\_owner' then 'owner' else 'user' end,
           coalesce((select array_agg(conn.name::text order by conn.name) from conn where conn.system = s.system), '{}'::text[]),
           exists (select 1 from conn where conn.system = s.system and conn.status = 'active')
    from systems s
    where s.system ~ '^[a-z0-9]+_(owner|user)$'
    order by (s.system not like '%\_owner'), s.system;
end
$$;

-- The ids in other systems held by the people the caller may see on People: users.manage_all sees
-- everyone, users.manage_agents the non-managing people and themselves (as cma.directory()). Never a
-- sign-in id: only systems that read <system>_owner or <system>_user.
create or replace function cma.linked_accounts()
returns table (user_id uuid, system text, external_id text)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_user uuid := cma.assert_any_permission(array['users.manage_agents', 'users.manage_all']);
  v_all  boolean := cma.has_permission(cma.current_user_id(), 'users.manage_all');
begin
  return query
    select x.user_id, x.system::text, x.external_id::text
    from cma.app_user_external_id x
    join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id and u.kind = 'person'
    where x.tenant_id = cma.current_tenant_id()
      and x.system ~ '^[a-z0-9]+_(owner|user)$'
      and (v_all or u.id = v_user
           or not exists (select 1 from cma.user_role ur where ur.tenant_id = u.tenant_id and ur.user_id = u.id
                          and cma.role_is_managing(ur.role_id)))
    order by x.user_id, x.system;
end
$$;

-- As 0007 (32_intake_core.sql), with the People rule for who may change a person's ids: a manager
-- (users.manage_agents) the non-managing people, an admin (users.manage_all) anyone. The checks keep
-- their order: the permission, the system's form, the id's form, a person of the tenant (CMA02),
-- then whether the caller may manage that person (CMA06), then an id another person holds (CMA03).
create or replace function cma.set_user_external_id(p_user_id uuid, p_system text, p_external_id text)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_ext    text := btrim(coalesce(p_external_id, ''));
  v_owner  uuid;
begin
  perform cma.assert_any_permission(array['users.manage_agents', 'users.manage_all']);
  if coalesce(p_system, '') !~ '^[a-z0-9]+_(owner|user)$' then
    raise exception 'system % must read <system>_owner or <system>_user', p_system using errcode = 'CMA04';
  end if;
  if v_ext = '' or length(v_ext) > 100 or v_ext ~ '[[:space:]]' then
    raise exception 'the id must be 1 to 100 characters without spaces' using errcode = 'CMA04';
  end if;
  if not exists (select 1 from cma.app_user u where u.tenant_id = v_tenant and u.id = p_user_id and u.kind = 'person') then
    raise exception 'no person % in the current tenant', p_user_id using errcode = 'CMA02';
  end if;
  perform cma.assert_may_manage(p_user_id);
  select x.user_id into v_owner from cma.app_user_external_id x
  where x.tenant_id = v_tenant and x.system = p_system and x.external_id = v_ext;
  if v_owner is not null and v_owner <> p_user_id then
    raise exception 'this % id already belongs to another person in the current tenant', p_system using errcode = 'CMA03';
  end if;
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
  values (v_tenant, p_user_id, p_system, v_ext)
  on conflict (tenant_id, user_id, system) do update set external_id = excluded.external_id
  where cma.app_user_external_id.external_id is distinct from excluded.external_id;
end
$$;

create or replace function cma.remove_user_external_id(p_user_id uuid, p_system text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_any_permission(array['users.manage_agents', 'users.manage_all']);
  if coalesce(p_system, '') !~ '^[a-z0-9]+_(owner|user)$' then
    raise exception 'system % must read <system>_owner or <system>_user', p_system using errcode = 'CMA04';
  end if;
  if exists (select 1 from cma.app_user u where u.tenant_id = cma.current_tenant_id() and u.id = p_user_id and u.kind = 'person') then
    perform cma.assert_may_manage(p_user_id);
  end if;
  delete from cma.app_user_external_id x
  where x.tenant_id = cma.current_tenant_id() and x.user_id = p_user_id and x.system = p_system
    and exists (select 1 from cma.app_user u where u.tenant_id = x.tenant_id and u.id = x.user_id and u.kind = 'person');
  if not found then
    raise exception 'person % has no % id', p_user_id, p_system using errcode = 'CMA02';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Privileges: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.connection_held_kinds_of(uuid,uuid)',
    'cma.set_connection_kind(uuid,text)',
    'cma.sources()',
    'cma.connection_catalogs(uuid)',
    'cma.markets_all()',
    'cma.business_hours_all()',
    'cma.business_holidays_all()',
    'cma.message_rules()',
    'cma.linked_account_systems()',
    'cma.linked_accounts()',
    'cma.set_user_external_id(uuid,text,text)',
    'cma.remove_user_external_id(uuid,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Reporting view: the kind joins the connection (no key, no secret names, as before)
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.integration_connection as
  select id, tenant_id, adapter, name, external_account_id, status, created_at, updated_at, kind
  from cma.integration_connection
  where cma_read.reader_sees(tenant_id);

insert into cma.schema_migration (version, description)
values ('0008e', 'Sources, markets and alert rules configuration reads, the connection kind, linked accounts on People (set_user_external_id follows the People rule)')
on conflict (version) do nothing;

commit;
reset role;
