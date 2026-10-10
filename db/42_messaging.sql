-- =============================================================================================
-- 42_messaging.sql: migration 0008, messaging core and record alerts (intake track I6)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 32_intake_core.sql (0007; it needs the markets and the alerts.max_age_minutes setting).
-- Rerunnable, forward-only. Run as your own IAM login, dev first, then prod; then
-- 43_verify_messaging.sql, then 31_verify_ingest_crm_records.sql and 33_verify_intake_core.sql
-- again (unchanged).
--
-- Specification: docs/night-2026-10-10/DESIGN.md §4.5 and §8 (README Features 7 Messaging; Decision
-- log 10 October 2026, D15).
--
-- What it adds
--   messages           cma.message: an alert or an announcement with urgency, a title and a body of
--                      references only, the record it points to (system, type, id, link), the rule
--                      that raised it, the sender, the target as asked, an optional expiry. A fact:
--                      never updated, never deleted
--   deliveries         cma.message_delivery: one row per recipient, resolved when the message is
--                      written, with delivered_at (first returned by the recipient's poll), read_at
--                      and acknowledged_at; each moves once from null to a time and never back
--   rules              cma.message_rule: which created records raise an alert for whom (audience
--                      permission, the market's language at its minimum level, clocked in only, a
--                      fallback permission when nobody matches), with urgency and an age limit
--   record alerts      cma.ingest_record_alerts(): the ingest service's call after a read-back of a
--                      created record; one message per rule and record, so a retry writes nothing
--   manual messages    cma.send_message() for messages.send: everyone, teams, a language with a
--                      minimum level or named people, optionally only those clocked in
--   the caller's side  cma.my_messages(), my_unread_count(), mark_messages_read(),
--                      acknowledge_message(): a signed-in person's own deliveries only
--   stats              cma.message_stats(): recipients, delivered, read, acknowledged and the median
--                      seconds to read per message
--
-- Clocked in means an open workday that has started (cma.is_clocked_in); a day forgotten past its
-- end is closed by the scheduler (0005a), so an open day is a day being worked, pauses included.
--
-- Nothing personal is stored: an alert's title and body are built here from configuration (the
-- record type, the market code, the pipeline label, the creation time); the link comes from the
-- connection's settings (record_url_<record type>, a template with {app_host}, {account} and {id}),
-- so no vendor's address pattern lives in the database.
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0007') then
    raise exception 'migration 0007 (32_intake_core.sql) must run before 0008';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Rules, messages and deliveries
-- ---------------------------------------------------------------------------------------------
-- Which created records raise an alert for whom. Identified by name within a tenant; disabled, not
-- deleted. pipeline_ids empty means every counted pipeline of the record type.
create table if not exists cma.message_rule (
  id                   uuid primary key default uuidv7(),
  tenant_id            uuid not null default cma.current_tenant_id() references cma.tenant (id),
  name                 text not null check (length(btrim(name)) between 1 and 80),
  trigger              text not null default 'record_created' check (trigger in ('record_created')),
  record_type          text not null check (record_type ~ '^[a-z][a-z0-9_]*$' and record_type <> 'contact'),
  pipeline_ids         text[] not null default '{}'
                         check (cardinality(pipeline_ids) <= 50 and array_position(pipeline_ids, null) is null),
  audience_permission  text not null default 'leads.accept' references cma.permission (key),
  match_language       boolean not null default true,
  only_clocked_in      boolean not null default true,
  fallback_permission  text default 'leads.manage' references cma.permission (key),
  urgency              text not null default 'normal' check (urgency in ('normal', 'urgent')),
  enabled              boolean not null default true,
  max_age_minutes      integer check (max_age_minutes between 1 and 10080),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, name)
);
comment on table cma.message_rule is 'Alert rules: a created record of a type (and pipelines) raises one message for the holders of a permission, matched on the market''s language and clocked in, else the fallback permission. Tenant configuration';
comment on column cma.message_rule.max_age_minutes is 'A record older than this when it reaches the rule raises nothing; null: the setting alerts.max_age_minutes';
create or replace trigger set_updated_at before update on cma.message_rule
  for each row execute function cma.set_updated_at();

-- A message is a fact. Title and body hold references only (README Messaging): an alert's are
-- built from configuration, a manual message's are what a manager typed.
create table if not exists cma.message (
  id              uuid primary key default uuidv7(),
  tenant_id       uuid not null default cma.current_tenant_id() references cma.tenant (id),
  kind            text not null check (kind in ('alert', 'announcement')),
  urgency         text not null default 'normal' check (urgency in ('normal', 'urgent')),
  title           text not null check (length(btrim(title)) between 1 and 120),
  body            text not null default '' check (length(body) <= 500),
  ref_system      text check (ref_system ~ '^[a-z0-9_]+$'),
  ref_type        text check (ref_type ~ '^[a-z][a-z0-9_]*$'),
  ref_id          text check (length(ref_id) between 1 and 100),
  ref_url         text check (ref_url ~ '^https://[^[:space:]]+$' and length(ref_url) <= 500),
  rule_id         uuid,
  target          jsonb not null default '{}'::jsonb check (jsonb_typeof(target) = 'object' and length(target::text) <= 4096),
  sender_user_id  uuid,
  created_at      timestamptz not null default now(),
  expires_at      timestamptz,
  unique (tenant_id, id),
  check (expires_at is null or expires_at > created_at),
  check ((ref_system is null) = (ref_type is null) and (ref_type is null) = (ref_id is null)),
  check (rule_id is null or (kind = 'alert' and ref_id is not null)),
  foreign key (tenant_id, rule_id) references cma.message_rule (tenant_id, id),
  foreign key (tenant_id, sender_user_id) references cma.app_user (tenant_id, id)
);
comment on table cma.message is 'Messages to CMA users: alerts raised by a rule and announcements sent by a person. References only, never customer data. Append-only';
comment on column cma.message.target is 'The target as asked ({everyone}, {teams}, {language}, {users}, onlyClockedIn; for an alert the rule''s terms); who received it is in message_delivery';
-- One alert per rule and record: a retry of the same read-back writes nothing
create unique index if not exists message_rule_ref_idx on cma.message (tenant_id, rule_id, ref_system, ref_type, ref_id)
  where rule_id is not null;
create index if not exists message_created_idx on cma.message (tenant_id, created_at);

create table if not exists cma.message_delivery (
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  message_id       uuid not null,
  user_id          uuid not null,
  created_at       timestamptz not null default now(),
  delivered_at     timestamptz,
  read_at          timestamptz,
  acknowledged_at  timestamptz,
  primary key (tenant_id, message_id, user_id),
  check (read_at is null or delivered_at is not null),
  check (acknowledged_at is null or read_at is not null),
  foreign key (tenant_id, message_id) references cma.message (tenant_id, id),
  foreign key (tenant_id, user_id) references cma.app_user (tenant_id, id)
);
comment on table cma.message_delivery is 'One row per recipient, resolved when the message was written (history stays exact when teams or skills change): delivered, read and acknowledged times, each set once';
create index if not exists message_delivery_user_idx on cma.message_delivery (tenant_id, user_id, read_at);

-- A delivery's times move from null to a value once and never change again; the recipient and the
-- message never change
create or replace function cma.check_message_delivery()
returns trigger
language plpgsql
as $$
begin
  if (new.tenant_id, new.message_id, new.user_id, new.created_at)
     is distinct from (old.tenant_id, old.message_id, old.user_id, old.created_at) then
    raise exception 'only the times of a delivery change' using errcode = 'CMA04';
  end if;
  if (old.delivered_at is not null and new.delivered_at is distinct from old.delivered_at)
     or (old.read_at is not null and new.read_at is distinct from old.read_at)
     or (old.acknowledged_at is not null and new.acknowledged_at is distinct from old.acknowledged_at) then
    raise exception 'a delivery time is set once and never moves' using errcode = 'CMA04';
  end if;
  return new;
end
$$;
revoke execute on function cma.check_message_delivery() from public;
create or replace trigger check_times_once before update on cma.message_delivery
  for each row execute function cma.check_message_delivery();

-- ---------------------------------------------------------------------------------------------
-- 2. Row-level security, audit and privileges
-- ---------------------------------------------------------------------------------------------
select cma.setup_tenant_table('cma.message_rule');
select cma.setup_tenant_table('cma.message');
select cma.setup_tenant_table('cma.message_delivery');

-- The application never deletes; a message never changes; a delivery changes only in its times; a
-- rule is disabled, not deleted.
revoke delete on cma.message_rule, cma.message, cma.message_delivery from cma_app;
revoke update on cma.message from cma_app;
revoke update on cma.message_delivery from cma_app;
grant update (delivered_at, read_at, acknowledged_at) on cma.message_delivery to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 3. Internal helpers
-- ---------------------------------------------------------------------------------------------
-- The acting user when it is an active person of the current tenant; CMA01 otherwise
create or replace function cma.assert_acting_person()
returns uuid
language plpgsql stable
as $$
declare
  v_user uuid := cma.current_user_id();
begin
  if v_user is null then
    raise exception 'this needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if not exists (select 1 from cma.app_user u
                 where u.tenant_id = cma.current_tenant_id() and u.id = v_user and u.status = 'active' and u.kind = 'person') then
    raise exception 'user % is not an active person of the current tenant', v_user using errcode = 'CMA01';
  end if;
  return v_user;
end
$$;

-- Clocked in: an open workday that has started. Pauses count as clocked in; a day forgotten past
-- its end is closed by the scheduler.
create or replace function cma.is_clocked_in(p_user_id uuid)
returns boolean
language sql stable
as $$
  select exists (select 1 from cma.workday w
                 where w.tenant_id = cma.current_tenant_id() and w.user_id = p_user_id
                   and w.status = 'open' and w.started_at <= now())
$$;

-- Holds a current skill (valid now) of a dimension and key at a minimum level (null: any level)
create or replace function cma.has_skill(p_user_id uuid, p_dimension text, p_skill_key text, p_min_level smallint)
returns boolean
language sql stable
as $$
  select exists (select 1 from cma.user_skill us
                 join cma.skill s on s.tenant_id = us.tenant_id and s.id = us.skill_id
                 where us.tenant_id = cma.current_tenant_id() and us.user_id = p_user_id
                   and s.dimension = p_dimension and s.key = p_skill_key and s.status = 'active'
                   and us.valid_from <= now() and (us.valid_to is null or us.valid_to > now())
                   and (p_min_level is null or us.level >= p_min_level))
$$;

-- The link to a record from the connection's settings: record_url_<record type> is a template with
-- {app_host} (the setting app_host), {account} (the connection's account id) and {id}. Null when
-- there is no template, a placeholder stays unfilled, or the result is not a plain https address.
create or replace function cma.record_url(p_connection_id uuid, p_record_type text, p_source_id text)
returns text
language plpgsql stable
as $$
declare
  v_settings jsonb;
  v_account  text;
  v_url      text;
begin
  select c.settings, c.external_account_id into v_settings, v_account
  from cma.integration_connection c
  where c.tenant_id = cma.current_tenant_id() and c.id = p_connection_id;
  v_url := v_settings ->> ('record_url_' || p_record_type);
  if v_url is null or coalesce(p_source_id, '') !~ '^[A-Za-z0-9_.-]{1,100}$' or v_account !~ '^[A-Za-z0-9_.-]{1,100}$' then
    return null;
  end if;
  if v_url like '%{app\_host}%' then
    if coalesce(v_settings ->> 'app_host', '') !~ '^[a-z0-9.-]{1,255}$' then
      return null;
    end if;
    v_url := replace(v_url, '{app_host}', v_settings ->> 'app_host');
  end if;
  v_url := replace(replace(v_url, '{account}', v_account), '{id}', p_source_id);
  if v_url !~ '^https://[^[:space:]{}]+$' or length(v_url) > 500 then
    return null;
  end if;
  return v_url;
end
$$;

-- Writes the deliveries of a message for the given people; answers how many
create or replace function cma.deliver_message(p_message_id uuid, p_users uuid[])
returns integer
language plpgsql
as $$
declare
  v_n integer;
begin
  insert into cma.message_delivery (tenant_id, message_id, user_id)
  select cma.current_tenant_id(), p_message_id, u
  from (select distinct unnest(p_users) as u) x
  where u is not null
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Rules (tenant.configure)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.upsert_message_rule(p_name text, p_record_type text, p_pipeline_ids text[],
                                                   p_audience_permission text, p_match_language boolean,
                                                   p_only_clocked_in boolean, p_fallback_permission text,
                                                   p_urgency text, p_max_age_minutes integer default null)
returns uuid
language plpgsql
as $$
declare
  v_tenant    uuid := cma.current_tenant_id();
  v_pipelines text[];
  v_id        uuid;
begin
  perform cma.assert_permission('tenant.configure');
  if coalesce(length(btrim(p_name)), 0) not between 1 and 80 then
    raise exception 'a rule needs a name of 1 to 80 characters' using errcode = 'CMA04';
  end if;
  if coalesce(p_record_type, '') !~ '^[a-z][a-z0-9_]*$' or p_record_type = 'contact' then
    raise exception 'record type % cannot raise alerts', p_record_type using errcode = 'CMA04';
  end if;
  if p_match_language is null or p_only_clocked_in is null then
    raise exception 'match_language and only_clocked_in must be true or false' using errcode = 'CMA04';
  end if;
  if coalesce(p_urgency, '') not in ('normal', 'urgent') then
    raise exception 'urgency must be normal or urgent' using errcode = 'CMA04';
  end if;
  if not exists (select 1 from cma.permission p where p.key = p_audience_permission) then
    raise exception 'no permission %', p_audience_permission using errcode = 'CMA02';
  end if;
  if p_fallback_permission is not null and not exists (select 1 from cma.permission p where p.key = p_fallback_permission) then
    raise exception 'no permission %', p_fallback_permission using errcode = 'CMA02';
  end if;
  select coalesce(array_agg(distinct btrim(x) order by btrim(x)), '{}') into v_pipelines
  from unnest(coalesce(p_pipeline_ids, '{}')) x
  where nullif(btrim(x), '') is not null;
  insert into cma.message_rule (tenant_id, name, record_type, pipeline_ids, audience_permission, match_language,
                                only_clocked_in, fallback_permission, urgency, max_age_minutes)
  values (v_tenant, btrim(p_name), p_record_type, v_pipelines, p_audience_permission, p_match_language,
          p_only_clocked_in, p_fallback_permission, p_urgency, p_max_age_minutes)
  on conflict (tenant_id, name) do update
    set record_type = excluded.record_type, pipeline_ids = excluded.pipeline_ids,
        audience_permission = excluded.audience_permission, match_language = excluded.match_language,
        only_clocked_in = excluded.only_clocked_in, fallback_permission = excluded.fallback_permission,
        urgency = excluded.urgency, max_age_minutes = excluded.max_age_minutes
  returning id into v_id;
  return v_id;
exception when check_violation or not_null_violation then
  raise exception 'invalid message rule: %', sqlerrm using errcode = 'CMA04';
end
$$;

create or replace function cma.set_message_rule_enabled(p_rule_id uuid, p_enabled boolean)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  if p_enabled is null then
    raise exception 'enabled must be true or false' using errcode = 'CMA04';
  end if;
  update cma.message_rule r set enabled = p_enabled
  where r.tenant_id = cma.current_tenant_id() and r.id = p_rule_id;
  if not found then
    raise exception 'no message rule % in the current tenant', p_rule_id using errcode = 'CMA02';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Record alerts (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- Called by the ingest service after a read-back upserted records that arrived by a created event.
-- For each record (of the connection and type, not deleted, created less than the rule's age limit
-- ago) and each enabled rule of its type whose pipelines it is in: recipients are resolved now
-- (active people holding the audience permission, clocked in if the rule asks, holding the
-- market's language skill at the market's minimum level if the rule asks; nobody: the holders of
-- the fallback permission), and the message and its deliveries are written in this transaction.
-- The market is the record's, else its contact's country; a market outside the catalog matches
-- nobody on language, a market without a language skill matches everyone. A message is written
-- even when nobody receives it, so the stats show it. Answers the number of messages written; a
-- second call for the same records writes nothing.
create or replace function cma.ingest_record_alerts(p_connection_id uuid, p_record_type text, p_source_ids text[])
returns integer
language plpgsql
as $$
declare
  v_tenant     uuid := cma.current_tenant_id();
  v_system     text;
  v_default    integer;
  v_zone       text;
  r            record;
  m            cma.market;
  v_market     text;
  v_users      uuid[];
  v_fallback   boolean;
  v_msg        uuid;
  v_written    integer := 0;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if coalesce(p_record_type, '') !~ '^[a-z][a-z0-9_]*$' then
    raise exception 'a record type is needed' using errcode = 'CMA04';
  end if;
  if p_source_ids is null or cardinality(p_source_ids) > 500 then
    raise exception 'source ids must be an array of at most 500' using errcode = 'CMA04';
  end if;
  v_default := coalesce((select s.value::integer from cma.tenant_settings() s where s.key = 'alerts.max_age_minutes'), 60);
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;

  for r in
    select cr.source_id, cr.market, cr.pipeline_id, cr.source_created_at, cc.country,
           coalesce(p.label, cr.pipeline_id) as pipeline_label,
           coalesce(p.is_counted, true) as pipeline_counted,
           ru.id as rule_id, ru.name as rule_name, ru.pipeline_ids, ru.audience_permission, ru.match_language,
           ru.only_clocked_in, ru.fallback_permission, ru.urgency, coalesce(ru.max_age_minutes, v_default) as max_age
    from cma.crm_record cr
    join cma.message_rule ru
      on ru.tenant_id = cr.tenant_id and ru.enabled and ru.trigger = 'record_created' and ru.record_type = cr.record_type
    left join cma.connection_pipeline p
      on p.tenant_id = cr.tenant_id and p.connection_id = cr.connection_id and p.record_type = cr.record_type
     and p.source_pipeline_id = cr.pipeline_id
    left join cma.crm_contact cc
      on cc.tenant_id = cr.tenant_id and cc.connection_id = cr.connection_id and cc.source_id = cr.contact_source_id
     and cc.source_deleted_at is null
    where cr.tenant_id = v_tenant and cr.connection_id = p_connection_id and cr.record_type = p_record_type
      and cr.source_id = any (p_source_ids)
      and cr.source_deleted_at is null
    order by cr.source_created_at, cr.source_id, ru.name
  loop
    if r.source_created_at < now() - make_interval(mins => r.max_age) then
      continue;
    end if;
    if cardinality(r.pipeline_ids) = 0 then
      if not r.pipeline_counted then
        continue;
      end if;
    elsif r.pipeline_id is null or not (r.pipeline_id = any (r.pipeline_ids)) then
      continue;
    end if;
    if exists (select 1 from cma.message x
               where x.tenant_id = v_tenant and x.rule_id = r.rule_id and x.ref_system = v_system
                 and x.ref_type = p_record_type and x.ref_id = r.source_id) then
      continue;
    end if;

    v_market := coalesce(r.market, r.country);
    m := null;
    select * into m from cma.market mk where mk.tenant_id = v_tenant and mk.code = v_market;

    select coalesce(array_agg(u.id order by u.id), '{}') into v_users
    from cma.app_user u
    where u.tenant_id = v_tenant and u.status = 'active' and u.kind = 'person'
      and cma.has_permission(u.id, r.audience_permission)
      and (not r.only_clocked_in or cma.is_clocked_in(u.id))
      and (not r.match_language
           or (m.id is not null
               and (m.language_skill_key is null
                    or cma.has_skill(u.id, 'language', m.language_skill_key, m.min_language_level))));
    v_fallback := cardinality(v_users) = 0 and r.fallback_permission is not null;
    if v_fallback then
      select coalesce(array_agg(u.id order by u.id), '{}') into v_users
      from cma.app_user u
      where u.tenant_id = v_tenant and u.status = 'active' and u.kind = 'person'
        and cma.has_permission(u.id, r.fallback_permission);
    end if;

    v_msg := null;
    insert into cma.message (tenant_id, kind, urgency, title, body, ref_system, ref_type, ref_id, ref_url, rule_id,
                             target, sender_user_id)
    values (v_tenant, 'alert', r.urgency,
            'New ' || replace(p_record_type, '_', ' '),
            left(coalesce(m.code, v_market, 'unknown') || ' · ' || coalesce(r.pipeline_label, '-') || ' · created '
                 || to_char(r.source_created_at at time zone coalesce(m.time_zone, v_zone), 'HH24:MI'), 500),
            v_system, p_record_type, r.source_id, cma.record_url(p_connection_id, p_record_type, r.source_id), r.rule_id,
            jsonb_build_object('rule', r.rule_name, 'permission', r.audience_permission, 'market', v_market,
                               'matchLanguage', r.match_language, 'onlyClockedIn', r.only_clocked_in,
                               'fallback', v_fallback),
            cma.current_user_id())
    on conflict (tenant_id, rule_id, ref_system, ref_type, ref_id) where rule_id is not null do nothing
    returning id into v_msg;
    if v_msg is not null then
      perform cma.deliver_message(v_msg, v_users);
      v_written := v_written + 1;
    end if;
  end loop;
  return v_written;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Manual messages (messages.send)
-- ---------------------------------------------------------------------------------------------
-- A manager's message to active people of the tenant. The target names exactly one group:
--   {"everyone": true} | {"teams": ["<team key>", ...]} | {"language": {"skill": "<key>", "minLevel": n}}
--   | {"users": ["<uuid>", ...]}
-- plus "onlyClockedIn": true to keep only those clocked in now. Recipients are resolved now; a
-- target that reaches nobody is refused. Answers the message id.
create or replace function cma.send_message(p_title text, p_body text, p_urgency text, p_target jsonb)
returns uuid
language plpgsql
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_sender   uuid;
  v_groups   int;
  v_clocked  boolean;
  v_keys     text[];
  v_ids      uuid[];
  v_skill    text;
  v_level    smallint;
  v_users    uuid[];
  v_msg      uuid;
begin
  v_sender := cma.assert_permission('messages.send');
  if coalesce(length(btrim(p_title)), 0) not between 1 and 120 or length(coalesce(p_body, '')) > 500 then
    raise exception 'a message needs a title of 1 to 120 characters and a body of at most 500' using errcode = 'CMA04';
  end if;
  if coalesce(p_urgency, '') not in ('normal', 'urgent') then
    raise exception 'urgency must be normal or urgent' using errcode = 'CMA04';
  end if;
  if p_target is null or jsonb_typeof(p_target) <> 'object'
     or exists (select 1 from jsonb_object_keys(p_target) k where k not in ('everyone', 'teams', 'language', 'users', 'onlyClockedIn')) then
    raise exception 'the target is an object with one of everyone, teams, language or users, and onlyClockedIn' using errcode = 'CMA04';
  end if;
  v_groups := (case when p_target ? 'everyone' then 1 else 0 end) + (case when p_target ? 'teams' then 1 else 0 end)
            + (case when p_target ? 'language' then 1 else 0 end) + (case when p_target ? 'users' then 1 else 0 end);
  if v_groups <> 1 then
    raise exception 'the target names exactly one of everyone, teams, language or users' using errcode = 'CMA04';
  end if;
  if p_target ? 'onlyClockedIn' and jsonb_typeof(p_target -> 'onlyClockedIn') <> 'boolean' then
    raise exception 'onlyClockedIn must be true or false' using errcode = 'CMA04';
  end if;
  v_clocked := coalesce((p_target ->> 'onlyClockedIn')::boolean, false);

  if p_target ? 'everyone' then
    if p_target -> 'everyone' <> 'true'::jsonb then
      raise exception 'everyone must be true' using errcode = 'CMA04';
    end if;
  elsif p_target ? 'teams' then
    if jsonb_typeof(p_target -> 'teams') <> 'array' or jsonb_array_length(p_target -> 'teams') not between 1 and 50
       or exists (select 1 from jsonb_array_elements(p_target -> 'teams') e where jsonb_typeof(e) <> 'string') then
      raise exception 'teams is a list of 1 to 50 team keys' using errcode = 'CMA04';
    end if;
    select array_agg(distinct e) into v_keys from jsonb_array_elements_text(p_target -> 'teams') e;
    if exists (select 1 from unnest(v_keys) k
               where not exists (select 1 from cma.team t where t.tenant_id = v_tenant and t.key = k
                                   and t.valid_from <= now() and (t.valid_to is null or t.valid_to > now()))) then
      raise exception 'a team of % is not a current team of the tenant', p_target -> 'teams' using errcode = 'CMA02';
    end if;
  elsif p_target ? 'language' then
    if jsonb_typeof(p_target -> 'language') <> 'object'
       or coalesce(p_target #>> '{language,skill}', '') = ''
       or (p_target #> '{language,minLevel}' is not null and jsonb_typeof(p_target #> '{language,minLevel}') <> 'null'
           and (p_target #>> '{language,minLevel}') !~ '^[1-9]$') then
      raise exception 'language is {skill, minLevel 1 to 9 or null}' using errcode = 'CMA04';
    end if;
    v_skill := p_target #>> '{language,skill}';
    v_level := (p_target #>> '{language,minLevel}')::smallint;
    if not exists (select 1 from cma.skill s where s.tenant_id = v_tenant and s.dimension = 'language'
                     and s.key = v_skill and s.status = 'active') then
      raise exception 'no active language skill %', v_skill using errcode = 'CMA02';
    end if;
  else
    if jsonb_typeof(p_target -> 'users') <> 'array' or jsonb_array_length(p_target -> 'users') not between 1 and 500
       or exists (select 1 from jsonb_array_elements(p_target -> 'users') e
                  where jsonb_typeof(e) <> 'string'
                     or (e #>> '{}') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
      raise exception 'users is a list of 1 to 500 user ids' using errcode = 'CMA04';
    end if;
    select array_agg(distinct (e)::uuid) into v_ids from jsonb_array_elements_text(p_target -> 'users') e;
    if exists (select 1 from unnest(v_ids) x
               where not exists (select 1 from cma.app_user u where u.tenant_id = v_tenant and u.id = x
                                   and u.status = 'active' and u.kind = 'person')) then
      raise exception 'a user of the target is not an active person of the tenant' using errcode = 'CMA02';
    end if;
  end if;

  select coalesce(array_agg(u.id order by u.id), '{}') into v_users
  from cma.app_user u
  where u.tenant_id = v_tenant and u.status = 'active' and u.kind = 'person'
    and (not v_clocked or cma.is_clocked_in(u.id))
    and case
          when p_target ? 'teams' then
            exists (select 1 from cma.team_member tm
                    join cma.team t on t.tenant_id = tm.tenant_id and t.id = tm.team_id
                    where tm.tenant_id = v_tenant and tm.user_id = u.id and t.key = any (v_keys)
                      and tm.valid_from <= now() and (tm.valid_to is null or tm.valid_to > now()))
          when p_target ? 'language' then cma.has_skill(u.id, 'language', v_skill, v_level)
          when p_target ? 'users' then u.id = any (v_ids)
          else true
        end;
  if cardinality(v_users) = 0 then
    raise exception 'the target reaches nobody now' using errcode = 'CMA04';
  end if;

  insert into cma.message (tenant_id, kind, urgency, title, body, target, sender_user_id)
  values (v_tenant, 'announcement', p_urgency, btrim(p_title), coalesce(p_body, ''), p_target, v_sender)
  returning id into v_msg;
  perform cma.deliver_message(v_msg, v_users);
  return v_msg;
exception when check_violation or not_null_violation then
  raise exception 'invalid message: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. The caller's own messages (any signed-in person, own deliveries only)
-- ---------------------------------------------------------------------------------------------
-- The caller's messages, newest first, created after p_since when given, at most p_limit (1 to
-- 200), expired ones left out. The first return sets delivered_at; a later poll leaves it.
create or replace function cma.my_messages(p_since timestamptz default null, p_limit integer default 50)
returns table (
  message_id       uuid,
  kind             text,
  urgency          text,
  title            text,
  body             text,
  ref_system       text,
  ref_type         text,
  ref_id           text,
  ref_url          text,
  created_at       timestamptz,
  expires_at       timestamptz,
  delivered_at     timestamptz,
  read_at          timestamptz,
  acknowledged_at  timestamptz
)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid;
  v_ids    uuid[];
begin
  v_user := cma.assert_acting_person();
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'limit is 1 to 200' using errcode = 'CMA04';
  end if;
  select coalesce(array_agg(x.id), '{}') into v_ids
  from (select m.id from cma.message_delivery d
        join cma.message m on m.tenant_id = d.tenant_id and m.id = d.message_id
        where d.tenant_id = v_tenant and d.user_id = v_user
          and (p_since is null or m.created_at > p_since)
          and (m.expires_at is null or m.expires_at > now())
        order by m.created_at desc, m.id desc
        limit p_limit) x;
  update cma.message_delivery d set delivered_at = now()
  where d.tenant_id = v_tenant and d.user_id = v_user and d.message_id = any (v_ids) and d.delivered_at is null;
  return query
    select m.id, m.kind, m.urgency, m.title, m.body, m.ref_system, m.ref_type, m.ref_id, m.ref_url, m.created_at, m.expires_at,
           d.delivered_at, d.read_at, d.acknowledged_at
    from cma.message_delivery d
    join cma.message m on m.tenant_id = d.tenant_id and m.id = d.message_id
    where d.tenant_id = v_tenant and d.user_id = v_user and d.message_id = any (v_ids)
    order by m.created_at desc, m.id desc;
end
$$;

create or replace function cma.my_unread_count()
returns integer
language plpgsql stable
as $$
declare
  v_user uuid;
begin
  v_user := cma.assert_acting_person();
  return (select count(*) from cma.message_delivery d
          join cma.message m on m.tenant_id = d.tenant_id and m.id = d.message_id
          where d.tenant_id = cma.current_tenant_id() and d.user_id = v_user and d.read_at is null
            and (m.expires_at is null or m.expires_at > now()))::integer;
end
$$;

-- Marks the caller's own deliveries read (and delivered, if the poll had not returned them yet);
-- ids of other people's deliveries and rows already read are left alone. Answers how many changed.
create or replace function cma.mark_messages_read(p_message_ids uuid[])
returns integer
language plpgsql
as $$
declare
  v_user uuid;
  v_n    integer;
begin
  v_user := cma.assert_acting_person();
  if p_message_ids is null or cardinality(p_message_ids) > 500 then
    raise exception 'message ids must be an array of at most 500' using errcode = 'CMA04';
  end if;
  update cma.message_delivery d
     set delivered_at = coalesce(d.delivered_at, now()), read_at = now()
   where d.tenant_id = cma.current_tenant_id() and d.user_id = v_user and d.message_id = any (p_message_ids)
     and d.read_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

-- Acknowledges one of the caller's own messages; acknowledging also reads it. A second
-- acknowledgement changes nothing. CMA02 when the caller has no delivery of that message.
create or replace function cma.acknowledge_message(p_message_id uuid)
returns void
language plpgsql
as $$
declare
  v_user uuid;
begin
  v_user := cma.assert_acting_person();
  if not exists (select 1 from cma.message_delivery d
                 where d.tenant_id = cma.current_tenant_id() and d.user_id = v_user and d.message_id = p_message_id) then
    raise exception 'no message % for you', p_message_id using errcode = 'CMA02';
  end if;
  update cma.message_delivery d
     set delivered_at = coalesce(d.delivered_at, now()), read_at = coalesce(d.read_at, now()), acknowledged_at = now()
   where d.tenant_id = cma.current_tenant_id() and d.user_id = v_user and d.message_id = p_message_id
     and d.acknowledged_at is null;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Stats (messages.send or performance.team)
-- ---------------------------------------------------------------------------------------------
-- Per message created in the business-date range (tenant zone), at most 92 days: recipients,
-- delivered, read, acknowledged and the median seconds from creation to reading
create or replace function cma.message_stats(p_from date, p_to date)
returns table (
  message_id              uuid,
  kind                    text,
  urgency                 text,
  title                   text,
  ref_system              text,
  ref_type                text,
  ref_id                  text,
  rule_id                 uuid,
  sender_user_id          uuid,
  created_at              timestamptz,
  recipients              integer,
  delivered               integer,
  read                    integer,
  acknowledged            integer,
  median_seconds_to_read  integer
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_zone   text;
begin
  perform cma.assert_any_permission(array['messages.send', 'performance.team']);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'a range of 1 to 92 days is needed' using errcode = 'CMA04';
  end if;
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;
  return query
    select m.id, m.kind, m.urgency, m.title, m.ref_system, m.ref_type, m.ref_id, m.rule_id, m.sender_user_id, m.created_at,
           count(d.user_id)::integer,
           count(d.delivered_at)::integer,
           count(d.read_at)::integer,
           count(d.acknowledged_at)::integer,
           round(percentile_cont(0.5) within group (order by extract(epoch from d.read_at - m.created_at)))::integer
    from cma.message m
    left join cma.message_delivery d on d.tenant_id = m.tenant_id and d.message_id = m.id
    where m.tenant_id = v_tenant
      and m.created_at >= (p_from::timestamp at time zone v_zone)
      and m.created_at < ((p_to + 1)::timestamp at time zone v_zone)
    group by m.id
    order by m.created_at, m.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.upsert_message_rule(text,text,text[],text,boolean,boolean,text,text,integer)',
    'cma.set_message_rule_enabled(uuid,boolean)',
    'cma.ingest_record_alerts(uuid,text,text[])',
    'cma.send_message(text,text,text,jsonb)',
    'cma.my_messages(timestamptz,integer)',
    'cma.my_unread_count()',
    'cma.mark_messages_read(uuid[])',
    'cma.acknowledge_message(uuid)',
    'cma.message_stats(date,date)',
    -- helpers the functions above call in the caller's rights
    'cma.assert_acting_person()',
    'cma.is_clocked_in(uuid)',
    'cma.has_skill(uuid,text,text,smallint)',
    'cma.record_url(uuid,text,text)',
    'cma.deliver_message(uuid,uuid[])'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. Reporting views (title and body hold references only, so both are included)
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.message as
  select id, tenant_id, kind, urgency, title, body, ref_system, ref_type, ref_id, ref_url, rule_id, target,
         sender_user_id, created_at, expires_at
  from cma.message
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.message_delivery as
  select tenant_id, message_id, user_id, created_at, delivered_at, read_at, acknowledged_at
  from cma.message_delivery
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.message_rule as
  select id, tenant_id, name, trigger, record_type, pipeline_ids, audience_permission, match_language, only_clocked_in,
         fallback_permission, urgency, enabled, max_age_minutes, created_at, updated_at
  from cma.message_rule
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 11. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008', 'Messaging core and record alerts: messages, deliveries with delivered, read and acknowledged times, alert rules, record alerts for the ingest service, manual messages, the caller''s reads and writes, stats')
on conflict (version) do nothing;

reset role;
