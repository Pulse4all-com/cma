-- =============================================================================================
-- 68_email_activity.sql: addition 0008m, email activity (metadata only)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 66_invitations.sql (0008l). Rerunnable, forward-only, in one transaction. Run as your own IAM
-- login, dev first, then prod; then 69_verify_email_activity.sql (dev), then 33_verify_intake_core.sql,
-- 35_verify_telephony.sql and 53_verify_sources_configuration.sql (dev) again (unchanged).
--
-- Brief B17a (README Decision log, 15 October 2026): the data model under the email and inbox
-- reports of B17c. Two email sources, kept apart: the CRM's email engagements (source_kind
-- crm_email: sent from the CRM, logged by BCC, replies to logged emails) and the inbox
-- conversations' messages (source_kind inbox_message: a connected shared inbox's threads). No
-- report adds them into one total. Nothing fills these tables yet: the email poll of brief B17b
-- does, every minute, through the functions below.
--
-- Metadata only. Never stored: subject, body, text, attachments, email addresses, names, headers,
-- recipients, senders. A sender's domain and a subject exist only in the ingest service's memory,
-- for the classification by the connection's rules, and only the category code is written. A
-- source's actor ids carry personal data for anyone who is not an agent (a visitor, an email
-- address), so only the actor's kind is stored, and for an agent the CRM owner id the ingest
-- service resolved; never a raw actor id. The kinds: agent, customer (a visitor or an email
-- address), system, bot, ai (an AI agent; HubSpot's conversations spec types it LLM), integration,
-- unknown. Second line here: every ref column refuses an @ and white space, the raw payload keeps
-- flat non-personal keys only and drops any string with an @, and an owner ref needs the actor kind
-- agent.
--
-- What it adds
--   settings            email.start_date (empty: intake.start_date), email.reply_target_minutes (240,
--                       business minutes), email.no_response_days (5), email.market_order
--                       ('record,inbox,contact'); cma.check_tenant_setting() checks the four
--   catalogs            cma.connection_inbox (an inbox of a connection: name from the source; counted,
--                       market, work type and channel as configuration) and
--                       cma.connection_inbox_channel (a source channel: name and canonical kind from the
--                       adapter; the tenant's channel and counted as configuration, so chat or WhatsApp
--                       become channels of their own without code), refreshed like forms and lines
--   rules               cma.connection_email_rule: per connection, in order, the words a sender domain
--                       or a subject contains and does not contain (case-insensitive, the mechanism of
--                       0008e's rules by name pattern) and the category code they give; never deleted
--   activity            cma.email_message (both sources: direction, status, time, actor kind, the
--                       agent's owner id, category, contact id), cma.email_thread (an inbox
--                       conversation: inbox, channel, status, opened and closed, the current agent,
--                       contact and ticket ids, spam, archived), cma.email_thread_event (assigned,
--                       closed, reopened, moved to another inbox; idempotent on the source message id)
--   ingest writes       cma.ingest_upsert_inboxes(), _inbox_channels(), _emails(), _threads(),
--                       _thread_events() and cma.ingest_thread_marks() (where each thread's stored
--                       messages stand), ingest.write, at most 500 per call; email engagements'
--                       associations through cma.ingest_upsert_associations(), which now takes the
--                       object type crm_email in the one stored direction calls use; sync_run's job
--                       email_poll
--   configuration       cma.set_inbox(), cma.set_inbox_channel(), cma.set_email_rule(),
--                       cma.set_email_rule_status() (tenant.configure); cma.connection_config() gains
--                       inboxes, inboxChannels and emailRules; email rows make a connection's kind crm
--   privacy             cma.ingest_contact_forget() also clears the contact on emails and threads;
--                       cma.ingest_thread_forget() for a conversation's privacy deletion
--   reads               cma.email_start_date_of(), cma.email_market_of() (the market by
--                       email.market_order, read at query time), cma.email_category_of() (the rules'
--                       definition; the owner's only, never called with a real subject)
--   reporting views     cma_read.connection_inbox, connection_inbox_channel, connection_email_rule,
--                       email_thread, email_message, email_thread_event: every column but raw
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted. No message carries a subject, an address or a raw actor id.
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
  if not exists (select 1 from cma.schema_migration where version = '0008l') then
    raise exception 'addition 0008l (66_invitations.sql) must run before 0008m';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('email.start_date',           'text',    null, '',
     'First date of email reporting and of the email backfill, as YYYY-MM-DD; empty means intake.start_date'),
  ('email.reply_target_minutes', 'integer', null, '240',
     'First reply target for an inbox conversation, in business minutes of its market (1 to 10080)'),
  ('email.no_response_days',     'integer', null, '5',
     'Days after an outgoing email without an incoming email, inbox message or connected call before an open lead deal counts as not responding (1 to 90)'),
  ('email.market_order',         'text',    null, 'record,inbox,contact',
     'Where an email''s market comes from, in this order: record (its ticket''s, then its deal''s market), inbox (the inbox''s market), contact (the contact''s country); comma-separated, each at most once')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- email.market_order: one to three of record, inbox and contact, comma-separated, each once
create or replace function cma.is_email_market_order(p_value text)
returns boolean
language sql immutable
as $$
  select p_value ~ '^(record|inbox|contact)(,(record|inbox|contact)){0,2}$'
     and (select count(*) = count(distinct x) from unnest(string_to_array(p_value, ',')) x)
$$;

-- As 0008l, plus the four email settings: a start date that is empty or a date, whole minutes from 1
-- to 10080, whole days from 1 to 90, and the market order written in lower case without spaces
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
  if new.key in ('auth.invitation_email_domains', 'email.market_order') then
    new.value := lower(regexp_replace(new.value, '[[:space:]]+', '', 'g'));
  end if;
  if new.key = 'email.start_date' then
    new.value := btrim(new.value);
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
    raise exception 'Setting % takes record, inbox and contact in the order wanted, each at most once, such as record,inbox,contact', new.key
      using errcode = 'CMA04';
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;
revoke execute on function cma.check_tenant_setting() from public;

-- ---------------------------------------------------------------------------------------------
-- 2. Rule words: 0008e's rules by name pattern, as stored values
-- ---------------------------------------------------------------------------------------------
-- Words as the rules keep them: lower case, trimmed, each once, in the order given, empty ones left
-- out (src/lib/sources.ts parseWords does the same to typed text)
create or replace function cma.email_words(p_words text[])
returns text[]
language sql immutable
as $$
  select coalesce(array_agg(w order by first_at), '{}')
  from (select lower(btrim(x)) as w, min(ord) as first_at
        from unnest(coalesce(p_words, '{}')) with ordinality as u(x, ord)
        where nullif(btrim(x), '') is not null
        group by lower(btrim(x))) t
$$;

-- Stored words are already in that form, 1 to 100 characters each, without a list separator
create or replace function cma.email_words_ok(p_words text[])
returns boolean
language sql immutable
as $$
  select p_words is not null
     and p_words = cma.email_words(p_words)
     and not exists (select 1 from unnest(p_words) w where length(w) > 100 or w ~ '[,;\r\n]')
$$;

-- A value matches when it contains any of the words and none of the exclude words, case-insensitive
-- (src/lib/sources.ts nameMatches); a value that is null or empty matches nothing
create or replace function cma.email_words_match(p_value text, p_words text[], p_exclude text[])
returns boolean
language sql immutable
as $$
  select nullif(p_value, '') is not null
     and exists (select 1 from unnest(p_words) w where strpos(lower(p_value), w) > 0)
     and not exists (select 1 from unnest(coalesce(p_exclude, '{}')) w where strpos(lower(p_value), w) > 0)
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Tables
-- ---------------------------------------------------------------------------------------------
-- An inbox of a connection (a shared mailbox or a team inbox in the CRM's conversations). Name and
-- status come from the source; counted, market, work type and channel are configuration and survive
-- every refresh. An inbox that does not count stays stored and is left out of the reports (B17c).
create table if not exists cma.connection_inbox (
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id       uuid not null,
  source_inbox_id     text not null check (source_inbox_id ~ '^[^@[:space:]]{1,100}$'),
  name                text not null check (length(btrim(name)) between 1 and 200),
  is_counted          boolean not null default true,
  market              text,
  work_type_skill_id  uuid,
  channel_id          uuid,
  status              text not null default 'active' check (status in ('active', 'archived')),
  refreshed_at        timestamptz,
  updated_at          timestamptz not null default now(),
  primary key (tenant_id, connection_id, source_inbox_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id),
  foreign key (tenant_id, market) references cma.market (tenant_id, code),
  foreign key (tenant_id, work_type_skill_id) references cma.skill (tenant_id, id),
  foreign key (tenant_id, channel_id) references cma.channel (tenant_id, id)
);
comment on table cma.connection_inbox is 'Inboxes of a connection''s conversations: name from the source; counted, market, work type and channel as configuration';
create or replace trigger set_updated_at before update on cma.connection_inbox
  for each row execute function cma.set_updated_at();

-- A channel of the source (email, chat, a messenger ...). kind is the adapter's canonical kind;
-- channel_id the tenant's channel its threads count under and is_counted whether they count. A new
-- channel takes the tenant's channel whose key equals its kind, and counts only when its kind is
-- email; both are configuration from then on.
create table if not exists cma.connection_inbox_channel (
  tenant_id          uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id      uuid not null,
  source_channel_id  text not null check (source_channel_id ~ '^[^@[:space:]]{1,100}$'),
  name               text not null check (length(btrim(name)) between 1 and 200),
  kind               text not null default 'other' check (kind ~ '^[a-z][a-z0-9_]{0,39}$'),
  channel_id         uuid,
  is_counted         boolean not null default false,
  status             text not null default 'active' check (status in ('active', 'archived')),
  refreshed_at       timestamptz,
  updated_at         timestamptz not null default now(),
  primary key (tenant_id, connection_id, source_channel_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id),
  foreign key (tenant_id, channel_id) references cma.channel (tenant_id, id)
);
comment on table cma.connection_inbox_channel is 'Channels of a connection''s conversations: name and canonical kind from the source; the tenant''s channel and counted as configuration';
create or replace trigger set_updated_at before update on cma.connection_inbox_channel
  for each row execute function cma.set_updated_at();

-- Classification rules per connection, in order: the first active rule whose words the value of its
-- kind contains (and none of its exclude words) gives the category. The words are configuration;
-- the value matched (a sender's domain, a subject) is never stored. Never deleted: switched off.
create table if not exists cma.connection_email_rule (
  id             uuid primary key default uuidv7(),
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id  uuid not null,
  applies_to     text not null check (applies_to in ('sender_domain', 'subject')),
  words          text[] not null check (cardinality(words) between 1 and 20 and cma.email_words_ok(words)),
  exclude_words  text[] not null default '{}' check (cardinality(exclude_words) <= 20 and cma.email_words_ok(exclude_words)),
  category       text not null check (category ~ '^[a-z][a-z0-9_]{0,59}$'),
  sort_order     integer not null default 100,
  status         text not null default 'active' check (status in ('active', 'inactive')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.connection_email_rule is 'Email classification rules per connection, in order: words a sender domain or subject contains and does not contain, and the category they give. The matched value is never stored';
create index if not exists connection_email_rule_order_idx on cma.connection_email_rule (tenant_id, connection_id, sort_order);
create or replace trigger set_updated_at before update on cma.connection_email_rule
  for each row execute function cma.set_updated_at();

-- An inbox conversation, metadata only. The current agent is the CRM owner id the ingest service
-- resolved from the assignee (null for anyone who is not an agent); the ticket is the thread's
-- associated ticket. source_updated_at is the adapter's version of the thread (the read's time): the
-- stale guard. A thread forgotten by a privacy deletion keeps ids, times and status for the counts
-- and takes no contact, ticket or raw payload again.
create table if not exists cma.email_thread (
  id                  uuid primary key default uuidv7(),
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id       uuid not null,
  source_system       text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_id           text not null check (source_id ~ '^[^@[:space:]]{1,100}$'),
  inbox_source_id     text check (inbox_source_id ~ '^[^@[:space:]]{1,100}$'),
  channel_source_id   text check (channel_source_id ~ '^[^@[:space:]]{1,100}$'),
  status              text not null check (status in ('open', 'closed')),
  source_created_at   timestamptz not null,
  closed_at           timestamptz,
  owner_ref           text check (owner_ref ~ '^[^@[:space:]]{1,100}$'),
  contact_source_id   text check (contact_source_id ~ '^[^@[:space:]]{1,100}$'),
  ticket_source_id    text check (ticket_source_id ~ '^[^@[:space:]]{1,100}$'),
  is_spam             boolean not null default false,
  is_archived         boolean not null default false,
  category            text check (category ~ '^[a-z][a-z0-9_]{0,59}$'),
  latest_received_at  timestamptz,
  latest_sent_at      timestamptz,
  source_updated_at   timestamptz,
  forgotten_at        timestamptz,
  synced_at           timestamptz not null default now(),
  raw                 jsonb not null default '{}'::jsonb check (jsonb_typeof(raw) = 'object'),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  check ((status = 'closed') = (closed_at is not null)),
  check (forgotten_at is null or (contact_source_id is null and ticket_source_id is null and raw = '{}'::jsonb)),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.email_thread is 'Inbox conversations, metadata only: inbox, channel, status, opened and closed, the current agent''s owner id, contact and ticket ids, spam, archived. Owned by the CRM';
create index if not exists email_thread_created_idx on cma.email_thread (tenant_id, source_created_at);
create index if not exists email_thread_open_idx on cma.email_thread (tenant_id, connection_id, inbox_source_id) where status = 'open';
create index if not exists email_thread_contact_idx on cma.email_thread (tenant_id, connection_id, contact_source_id) where contact_source_id is not null;

-- One email of either source, metadata only. owner_ref is the sending or acting agent's CRM owner id
-- and exists only for the actor kind agent. thread_source_id is the conversation thread for an
-- inbox message, and the CRM's own thread id (when the adapter maps one) for an email engagement.
create table if not exists cma.email_message (
  id                  uuid primary key default uuidv7(),
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id       uuid not null,
  source_system       text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_kind         text not null check (source_kind in ('crm_email', 'inbox_message')),
  source_id           text not null check (source_id ~ '^[^@[:space:]]{1,100}$'),
  thread_source_id    text check (thread_source_id ~ '^[^@[:space:]]{1,100}$'),
  inbox_source_id     text check (inbox_source_id ~ '^[^@[:space:]]{1,100}$'),
  channel_source_id   text check (channel_source_id ~ '^[^@[:space:]]{1,100}$'),
  direction           text not null check (direction in ('out', 'in', 'forwarded')),
  status              text not null default 'other' check (status in ('sent', 'bounced', 'failed', 'scheduled', 'other')),
  occurred_at         timestamptz not null,
  actor_kind          text not null default 'unknown'
                        check (actor_kind in ('agent', 'customer', 'system', 'bot', 'ai', 'integration', 'unknown')),
  owner_ref           text check (owner_ref ~ '^[^@[:space:]]{1,100}$'),
  category            text check (category ~ '^[a-z][a-z0-9_]{0,59}$'),
  contact_source_id   text check (contact_source_id ~ '^[^@[:space:]]{1,100}$'),
  source_created_at   timestamptz,
  source_updated_at   timestamptz,
  source_deleted_at   timestamptz,
  synced_at           timestamptz not null default now(),
  raw                 jsonb not null default '{}'::jsonb check (jsonb_typeof(raw) = 'object'),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_kind, source_id),
  check (owner_ref is null or actor_kind = 'agent'),
  check (source_kind <> 'inbox_message' or thread_source_id is not null),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.email_message is 'Emails of two sources kept apart (crm_email, inbox_message), metadata only: direction, status, time, actor kind, the agent''s owner id, category, contact id. Owned by the CRM';
create index if not exists email_message_occurred_idx on cma.email_message (tenant_id, occurred_at);
create index if not exists email_message_thread_idx on cma.email_message (tenant_id, connection_id, thread_source_id, occurred_at)
  where thread_source_id is not null;
create index if not exists email_message_contact_idx on cma.email_message (tenant_id, connection_id, contact_source_id)
  where contact_source_id is not null;

-- What happened to a conversation besides its messages: assigned (to_actor_kind null: unassigned;
-- to_owner_ref only for an agent), closed, reopened, moved to another inbox. One row per source
-- message, insert-only.
create table if not exists cma.email_thread_event (
  id                    uuid primary key default uuidv7(),
  tenant_id             uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id         uuid not null,
  source_id             text not null check (source_id ~ '^[^@[:space:]]{1,100}$'),
  thread_source_id      text not null check (thread_source_id ~ '^[^@[:space:]]{1,100}$'),
  kind                  text not null check (kind in ('assigned', 'closed', 'reopened', 'moved_inbox')),
  occurred_at           timestamptz not null,
  actor_kind            text not null default 'unknown'
                          check (actor_kind in ('agent', 'customer', 'system', 'bot', 'ai', 'integration', 'unknown')),
  owner_ref             text check (owner_ref ~ '^[^@[:space:]]{1,100}$'),
  to_actor_kind         text check (to_actor_kind in ('agent', 'customer', 'system', 'bot', 'ai', 'integration', 'unknown')),
  to_owner_ref          text check (to_owner_ref ~ '^[^@[:space:]]{1,100}$'),
  from_inbox_source_id  text check (from_inbox_source_id ~ '^[^@[:space:]]{1,100}$'),
  to_inbox_source_id    text check (to_inbox_source_id ~ '^[^@[:space:]]{1,100}$'),
  synced_at             timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  check (owner_ref is null or actor_kind = 'agent'),
  check (to_owner_ref is null or to_actor_kind = 'agent'),
  check (kind = 'assigned' or (to_actor_kind is null and to_owner_ref is null)),
  check (kind = 'moved_inbox' or (from_inbox_source_id is null and to_inbox_source_id is null)),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.email_thread_event is 'Assignments, closes, reopens and inbox moves of inbox conversations: actor kind and the agents'' owner ids only. Insert-only, one row per source message';
create index if not exists email_thread_event_thread_idx on cma.email_thread_event (tenant_id, connection_id, thread_source_id, occurred_at);
create index if not exists email_thread_event_occurred_idx on cma.email_thread_event (tenant_id, occurred_at);

select cma.setup_tenant_table('cma.connection_inbox');
select cma.setup_tenant_table('cma.connection_inbox_channel');
select cma.setup_tenant_table('cma.connection_email_rule');
select cma.setup_tenant_table('cma.email_thread');
select cma.setup_tenant_table('cma.email_message');
select cma.setup_tenant_table('cma.email_thread_event');

-- The application writes these through the functions below only and never deletes; a thread event
-- is never changed once written
revoke delete on cma.connection_inbox, cma.connection_inbox_channel, cma.connection_email_rule,
                 cma.email_thread, cma.email_message, cma.email_thread_event from cma_app;
revoke update on cma.email_thread_event from cma_app;

-- 0007's associations take the object type crm_email as they take crm_call: an activity points to a
-- contact or to a record, one stored direction
alter table cma.crm_association drop constraint if exists crm_association_check;
alter table cma.crm_association add constraint crm_association_check
  check (from_type <> 'contact' and to_type not in ('crm_call', 'crm_email') and from_type <> to_type
         and (to_type = 'contact' or from_type in ('crm_call', 'crm_email')));

-- The email poll's runs (B17b)
alter table cma.sync_run drop constraint if exists sync_run_job_check;
alter table cma.sync_run add constraint sync_run_job_check
  check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls', 'email_poll'));

-- ---------------------------------------------------------------------------------------------
-- 4. Helpers
-- ---------------------------------------------------------------------------------------------
-- The raw payload as stored: a flat object of at most 50 keys whose values are numbers, booleans or
-- strings of at most 200 characters. Dropped: nested objects and arrays, keys that name content,
-- people or addresses (subject, body, text, html, header, attachment, preview, snippet, signature,
-- content, name, mail address fields, from, to, cc, bcc, sender, recipient, reply, phone, number,
-- note, comment, url, link, file), any string holding an @ and strings that look like a phone
-- number. The ingest service sends an allowlist; this is the second line.
create or replace function cma.email_raw(p_raw jsonb)
returns jsonb
language sql immutable
as $$
  select coalesce((
    select jsonb_object_agg(e.key, e.value)
    from (select e.key, e.value
          from jsonb_each(case when jsonb_typeof(p_raw) = 'object' then p_raw else '{}'::jsonb end) e
          where e.key ~ '^[A-Za-z0-9_.-]{1,60}$'
            and e.key !~* '(subject|body|text|html|header|attach|preview|snippet|signature|content|name|address|_email$|^email$|email_address|(^|_)from(_|$)|(^|_)to(_|$)|(^|_)cc(_|$)|(^|_)bcc(_|$)|sender|recipient|reply|phone|number|digit|note|comment|url|link|file)'
            and (jsonb_typeof(e.value) in ('number', 'boolean')
                 or (jsonb_typeof(e.value) = 'string'
                     and length(e.value #>> '{}') <= 200
                     and strpos(e.value #>> '{}', '@') = 0
                     and not ((e.value #>> '{}') ~ '^\+?[0-9 ().-]{7,20}$' and (e.value #>> '{}') !~ '^\d{4}-\d{2}-\d{2}')))
          order by e.key
          limit 50) e), '{}'::jsonb)
$$;

-- A connection of the current tenant that may hold email activity: its kind is crm, or unset while it
-- holds no rows of another kind. Active only when p_active (the ingest side); configuration may touch
-- an inactive one. Returns the adapter. CMA02 for an unknown or inactive connection, CMA04 for
-- another kind.
create or replace function cma.assert_email_connection(p_connection_id uuid, p_active boolean)
returns text
language plpgsql stable
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_adapter text;
  v_kind    text;
begin
  select c.adapter, c.kind into v_adapter, v_kind
  from cma.integration_connection c
  where c.tenant_id = v_tenant and c.id = p_connection_id and (c.status = 'active' or not p_active);
  if v_adapter is null then
    raise exception 'no %connection % in the current tenant', case when p_active then 'active ' else '' end, p_connection_id
      using errcode = 'CMA02';
  end if;
  if (v_kind is not null and v_kind <> 'crm')
     or (v_kind is null and exists (select 1 from unnest(cma.connection_held_kinds_of(v_tenant, p_connection_id)) k where k <> 'crm')) then
    raise exception 'connection % is not a CRM connection; email activity belongs to the CRM', p_connection_id using errcode = 'CMA04';
  end if;
  return v_adapter;
end
$$;

-- 0008e's kinds a connection's rows imply, plus the email tables (crm)
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
           or exists (select 1 from cma.connection_inbox x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox_channel x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_email_rule x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.email_message x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.email_thread x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
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

-- An optional boolean of an item: absent or null is false; anything but a JSON boolean is CMA04
create or replace function cma.json_flag(p_value jsonb, p_what text)
returns boolean
language plpgsql immutable
as $$
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return false;
  end if;
  if jsonb_typeof(p_value) <> 'boolean' then
    raise exception '% must be true or false', p_what using errcode = 'CMA04';
  end if;
  return (p_value #>> '{}')::boolean;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The ingest write path (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- Refreshes the inbox catalog: [{inboxId, name}], at most 500. Counted, market, work type and channel
-- stay; a new inbox counts and takes the tenant's active channel with the key email, when there is
-- one; an inbox missing from the list is archived. Answers the number of active inboxes.
create or replace function cma.ingest_upsert_inboxes(p_connection_id uuid, p_items jsonb)
returns integer
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  i        jsonb;
  v_n      integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.assert_email_connection(p_connection_id, true);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'inboxes must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for i in select value from jsonb_array_elements(p_items) loop
    if coalesce(i ->> 'inboxId', '') = '' then
      raise exception 'every inbox needs an inboxId' using errcode = 'CMA04';
    end if;
    insert into cma.connection_inbox (tenant_id, connection_id, source_inbox_id, name, channel_id, status, refreshed_at)
    values (v_tenant, p_connection_id, i ->> 'inboxId', left(coalesce(nullif(btrim(i ->> 'name'), ''), i ->> 'inboxId'), 200),
            (select ch.id from cma.channel ch where ch.tenant_id = v_tenant and ch.key = 'email' and ch.status = 'active'),
            'active', now())
    on conflict (tenant_id, connection_id, source_inbox_id)
      do update set name = excluded.name, status = 'active', refreshed_at = now();
  end loop;
  update cma.connection_inbox b set status = 'archived'
  where b.tenant_id = v_tenant and b.connection_id = p_connection_id and b.status = 'active'
    and not exists (select 1 from jsonb_array_elements(p_items) x where x ->> 'inboxId' = b.source_inbox_id);
  select count(*)::integer into v_n from cma.connection_inbox b
  where b.tenant_id = v_tenant and b.connection_id = p_connection_id and b.status = 'active';
  return v_n;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid inbox: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Refreshes the channel catalog: [{channelId, name, kind}], at most 500; kind is the adapter's
-- canonical kind (email, chat, ...), other when absent. The tenant's channel and counted stay; a new
-- channel takes the tenant's active channel whose key equals its kind (none otherwise) and counts
-- only when its kind is email; a channel missing from the list is archived. Answers the number of
-- active channels.
create or replace function cma.ingest_upsert_inbox_channels(p_connection_id uuid, p_items jsonb)
returns integer
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  i        jsonb;
  v_kind   text;
  v_n      integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.assert_email_connection(p_connection_id, true);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'channels must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for i in select value from jsonb_array_elements(p_items) loop
    if coalesce(i ->> 'channelId', '') = '' then
      raise exception 'every channel needs a channelId' using errcode = 'CMA04';
    end if;
    v_kind := coalesce(nullif(lower(btrim(i ->> 'kind')), ''), 'other');
    insert into cma.connection_inbox_channel (tenant_id, connection_id, source_channel_id, name, kind, channel_id, is_counted,
                                              status, refreshed_at)
    values (v_tenant, p_connection_id, i ->> 'channelId', left(coalesce(nullif(btrim(i ->> 'name'), ''), i ->> 'channelId'), 200),
            v_kind, (select ch.id from cma.channel ch where ch.tenant_id = v_tenant and ch.key = v_kind and ch.status = 'active'),
            v_kind = 'email', 'active', now())
    on conflict (tenant_id, connection_id, source_channel_id)
      do update set name = excluded.name, kind = excluded.kind, status = 'active', refreshed_at = now();
  end loop;
  update cma.connection_inbox_channel b set status = 'archived'
  where b.tenant_id = v_tenant and b.connection_id = p_connection_id and b.status = 'active'
    and not exists (select 1 from jsonb_array_elements(p_items) x where x ->> 'channelId' = b.source_channel_id);
  select count(*)::integer into v_n from cma.connection_inbox_channel b
  where b.tenant_id = v_tenant and b.connection_id = p_connection_id and b.status = 'active';
  return v_n;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid channel: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Upserts inbox conversations as the source answered them, at most 500:
--   [{sourceId, inboxId, channelId, status (open | closed), createdAt, closedAt, ownerRef, contactId,
--     ticketId, isSpam, isArchived, category, latestReceivedAt, latestSentAt, updatedAt, raw?}]
-- Every read is the thread's current state: status, agent, contact, ticket, spam and archived as given
-- (null clears); a read without inbox, channel, category or latest times keeps the stored ones.
-- updatedAt (the adapter's version, the read's time) is the stale guard: an older read changes
-- nothing. closed_at is the source's close time, else the one stored while the thread stays closed,
-- else now; a reopened thread has none. A forgotten thread (cma.ingest_thread_forget) changes no more.
-- Outcomes: inserted, updated, stale, forgotten.
create or replace function cma.ingest_upsert_threads(p_connection_id uuid, p_items jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  t          jsonb;
  v_src      text;
  v_status   text;
  v_updated  timestamptz;
  v_created  timestamptz;
  v_closed   timestamptz;
  v_old      cma.email_thread;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.assert_email_connection(p_connection_id, true);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'threads must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for t in select value from jsonb_array_elements(p_items) loop
    v_src := t ->> 'sourceId';
    v_status := t ->> 'status';
    if coalesce(v_src, '') = '' or coalesce(v_status, '') not in ('open', 'closed') then
      raise exception 'every thread needs a sourceId and a status open or closed' using errcode = 'CMA04';
    end if;
    v_updated := cma.json_time(t -> 'updatedAt', 'updatedAt');
    v_created := cma.json_time(t -> 'createdAt', 'createdAt');
    v_closed := cma.json_time(t -> 'closedAt', 'closedAt');
    select * into v_old from cma.email_thread et
    where et.tenant_id = v_tenant and et.connection_id = p_connection_id and et.source_id = v_src
    for update;

    if v_old.id is not null and v_old.forgotten_at is not null then
      return query select v_src, 'forgotten'::text;
      continue;
    end if;
    if v_old.id is not null and v_old.source_updated_at is not null
       and (v_updated is null or v_updated < v_old.source_updated_at) then
      return query select v_src, 'stale'::text;
      continue;
    end if;

    if v_old.id is null then
      if v_created is null then
        raise exception 'a new thread needs createdAt' using errcode = 'CMA04';
      end if;
      insert into cma.email_thread (tenant_id, connection_id, source_system, source_id, inbox_source_id, channel_source_id, status,
                                    source_created_at, closed_at, owner_ref, contact_source_id, ticket_source_id, is_spam, is_archived,
                                    category, latest_received_at, latest_sent_at, source_updated_at, raw)
      values (v_tenant, p_connection_id, v_system, v_src, nullif(t ->> 'inboxId', ''), nullif(t ->> 'channelId', ''), v_status,
              v_created, case when v_status = 'closed' then coalesce(v_closed, now()) end,
              nullif(t ->> 'ownerRef', ''), nullif(t ->> 'contactId', ''), nullif(t ->> 'ticketId', ''),
              cma.json_flag(t -> 'isSpam', 'isSpam'), cma.json_flag(t -> 'isArchived', 'isArchived'),
              nullif(t ->> 'category', ''), cma.json_time(t -> 'latestReceivedAt', 'latestReceivedAt'),
              cma.json_time(t -> 'latestSentAt', 'latestSentAt'), v_updated, cma.email_raw(t -> 'raw'));
      return query select v_src, 'inserted'::text;
    else
      update cma.email_thread et
         set inbox_source_id = coalesce(nullif(t ->> 'inboxId', ''), et.inbox_source_id),
             channel_source_id = coalesce(nullif(t ->> 'channelId', ''), et.channel_source_id),
             status = v_status,
             source_created_at = coalesce(v_created, et.source_created_at),
             closed_at = case when v_status = 'closed'
                              then coalesce(v_closed, case when et.status = 'closed' then et.closed_at end, now()) end,
             owner_ref = nullif(t ->> 'ownerRef', ''),
             contact_source_id = nullif(t ->> 'contactId', ''),
             ticket_source_id = nullif(t ->> 'ticketId', ''),
             is_spam = cma.json_flag(t -> 'isSpam', 'isSpam'),
             is_archived = cma.json_flag(t -> 'isArchived', 'isArchived'),
             category = coalesce(nullif(t ->> 'category', ''), et.category),
             latest_received_at = coalesce(cma.json_time(t -> 'latestReceivedAt', 'latestReceivedAt'), et.latest_received_at),
             latest_sent_at = coalesce(cma.json_time(t -> 'latestSentAt', 'latestSentAt'), et.latest_sent_at),
             source_updated_at = v_updated,
             synced_at = now(),
             raw = cma.email_raw(t -> 'raw')
       where et.tenant_id = v_tenant and et.id = v_old.id;
      return query select v_src, 'updated'::text;
    end if;
  end loop;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid thread: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Upserts emails of either source, at most 500:
--   [{sourceKind (crm_email | inbox_message), sourceId, threadId, inboxId, channelId, direction
--     (out | in | forwarded), status (sent | bounced | failed | scheduled | other), occurredAt,
--     actorKind (agent | customer | system | bot | ai | integration | unknown), ownerRef (an agent's CRM
--     owner id only), category, contactId, createdAt, updatedAt, deletedAt?, raw?}]
-- updatedAt is the stale guard (0006): an older read changes nothing. A read without thread, inbox,
-- channel, category or contact keeps the stored one (as 0006 keeps a record's contact). A deletion
-- keeps ids, times and the metadata for the counts and clears the raw payload; a newer read brings the
-- email back. An inbox message of a forgotten thread is stored without contact and raw payload.
-- Outcomes: inserted, updated, stale, deleted, unknown (a deletion of an email never stored).
create or replace function cma.ingest_upsert_emails(p_connection_id uuid, p_items jsonb)
returns table (source_kind text, source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant     uuid := cma.current_tenant_id();
  v_system     text;
  e            jsonb;
  v_kind       text;
  v_src        text;
  v_updated    timestamptz;
  v_deleted    timestamptz;
  v_forgotten  boolean;
  v_old        cma.email_message;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.assert_email_connection(p_connection_id, true);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'emails must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for e in select value from jsonb_array_elements(p_items) loop
    v_kind := e ->> 'sourceKind';
    v_src := e ->> 'sourceId';
    if coalesce(v_kind, '') not in ('crm_email', 'inbox_message') or coalesce(v_src, '') = '' then
      raise exception 'every email needs a sourceKind crm_email or inbox_message and a sourceId' using errcode = 'CMA04';
    end if;
    v_updated := cma.json_time(e -> 'updatedAt', 'updatedAt');
    v_deleted := cma.json_time(e -> 'deletedAt', 'deletedAt');
    select * into v_old from cma.email_message em
    where em.tenant_id = v_tenant and em.connection_id = p_connection_id and em.source_kind = v_kind and em.source_id = v_src
    for update;

    if v_deleted is not null then
      if v_old.id is null then
        return query select v_kind, v_src, 'unknown'::text;
      else
        update cma.email_message em set source_deleted_at = v_deleted, raw = '{}'::jsonb, synced_at = now()
        where em.tenant_id = v_tenant and em.id = v_old.id and em.source_deleted_at is distinct from v_deleted;
        return query select v_kind, v_src, 'deleted'::text;
      end if;
      continue;
    end if;

    if v_old.id is not null and v_old.source_updated_at is not null
       and (v_updated is null or v_updated < v_old.source_updated_at) then
      return query select v_kind, v_src, 'stale'::text;
      continue;
    end if;

    v_forgotten := v_kind = 'inbox_message' and exists (
      select 1 from cma.email_thread et
      where et.tenant_id = v_tenant and et.connection_id = p_connection_id and et.source_id = e ->> 'threadId'
        and et.forgotten_at is not null);

    if v_old.id is null then
      insert into cma.email_message (tenant_id, connection_id, source_system, source_kind, source_id, thread_source_id, inbox_source_id,
                                     channel_source_id, direction, status, occurred_at, actor_kind, owner_ref, category,
                                     contact_source_id, source_created_at, source_updated_at, raw)
      values (v_tenant, p_connection_id, v_system, v_kind, v_src, nullif(e ->> 'threadId', ''), nullif(e ->> 'inboxId', ''),
              nullif(e ->> 'channelId', ''), e ->> 'direction', coalesce(nullif(e ->> 'status', ''), 'other'),
              cma.json_time(e -> 'occurredAt', 'occurredAt'), coalesce(nullif(e ->> 'actorKind', ''), 'unknown'),
              nullif(e ->> 'ownerRef', ''), nullif(e ->> 'category', ''),
              case when not v_forgotten then nullif(e ->> 'contactId', '') end,
              cma.json_time(e -> 'createdAt', 'createdAt'), v_updated,
              case when v_forgotten then '{}'::jsonb else cma.email_raw(e -> 'raw') end);
      return query select v_kind, v_src, 'inserted'::text;
    else
      update cma.email_message em
         set thread_source_id = coalesce(nullif(e ->> 'threadId', ''), em.thread_source_id),
             inbox_source_id = coalesce(nullif(e ->> 'inboxId', ''), em.inbox_source_id),
             channel_source_id = coalesce(nullif(e ->> 'channelId', ''), em.channel_source_id),
             direction = e ->> 'direction',
             status = coalesce(nullif(e ->> 'status', ''), 'other'),
             occurred_at = cma.json_time(e -> 'occurredAt', 'occurredAt'),
             actor_kind = coalesce(nullif(e ->> 'actorKind', ''), 'unknown'),
             owner_ref = nullif(e ->> 'ownerRef', ''),
             category = coalesce(nullif(e ->> 'category', ''), em.category),
             contact_source_id = case when not v_forgotten then coalesce(nullif(e ->> 'contactId', ''), em.contact_source_id) end,
             source_created_at = coalesce(cma.json_time(e -> 'createdAt', 'createdAt'), em.source_created_at),
             source_updated_at = v_updated,
             source_deleted_at = null,
             synced_at = now(),
             raw = case when v_forgotten then '{}'::jsonb else cma.email_raw(e -> 'raw') end
       where em.tenant_id = v_tenant and em.id = v_old.id;
      return query select v_kind, v_src, 'updated'::text;
    end if;
  end loop;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid email: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Records what happened to conversations, at most 500, insert-only and idempotent on the source
-- message id:
--   [{sourceId, threadId, kind (assigned | closed | reopened | moved_inbox), occurredAt, actorKind,
--     ownerRef, toActorKind, toOwnerRef, fromInboxId, toInboxId}]
-- A known source id is not written again. Outcomes: inserted, known.
create or replace function cma.ingest_upsert_thread_events(p_connection_id uuid, p_items jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v        jsonb;
  v_src    text;
  v_id     uuid;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.assert_email_connection(p_connection_id, true);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'thread events must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for v in select value from jsonb_array_elements(p_items) loop
    v_src := v ->> 'sourceId';
    if coalesce(v_src, '') = '' or coalesce(v ->> 'threadId', '') = '' or v -> 'occurredAt' is null then
      raise exception 'every thread event needs a sourceId, a threadId and occurredAt' using errcode = 'CMA04';
    end if;
    v_id := null;
    insert into cma.email_thread_event (tenant_id, connection_id, source_id, thread_source_id, kind, occurred_at, actor_kind, owner_ref,
                                        to_actor_kind, to_owner_ref, from_inbox_source_id, to_inbox_source_id)
    values (v_tenant, p_connection_id, v_src, v ->> 'threadId', v ->> 'kind', cma.json_time(v -> 'occurredAt', 'occurredAt'),
            coalesce(nullif(v ->> 'actorKind', ''), 'unknown'), nullif(v ->> 'ownerRef', ''), nullif(v ->> 'toActorKind', ''),
            nullif(v ->> 'toOwnerRef', ''), nullif(v ->> 'fromInboxId', ''), nullif(v ->> 'toInboxId', ''))
    on conflict (tenant_id, connection_id, source_id) do nothing
    returning id into v_id;
    return query select v_src, case when v_id is null then 'known' else 'inserted' end;
  end loop;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid thread event: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Where the stored messages of each given thread stand, for the poll that reads a changed thread's
-- messages after its last stored one: per thread the CMA holds, the time of its latest stored inbox
-- message or event, the counts of both, the thread's stored version and whether it was forgotten. At
-- most 500 thread ids; a thread the CMA does not hold gives no row.
create or replace function cma.ingest_thread_marks(p_connection_id uuid, p_thread_ids text[])
returns table (thread_source_id text, last_at timestamptz, messages integer, events integer,
               source_updated_at timestamptz, is_forgotten boolean)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('ingest.write');
  perform cma.assert_email_connection(p_connection_id, true);
  if p_thread_ids is null or cardinality(p_thread_ids) > 500 then
    raise exception 'thread ids must be a list of at most 500' using errcode = 'CMA04';
  end if;
  return query
  select et.source_id,
         greatest(m.last_at, v.last_at),
         coalesce(m.n, 0)::integer,
         coalesce(v.n, 0)::integer,
         et.source_updated_at,
         et.forgotten_at is not null
  from cma.email_thread et
  left join lateral (select max(em.occurred_at) as last_at, count(*) as n
                     from cma.email_message em
                     where em.tenant_id = et.tenant_id and em.connection_id = et.connection_id
                       and em.thread_source_id = et.source_id and em.source_kind = 'inbox_message') m on true
  left join lateral (select max(ev.occurred_at) as last_at, count(*) as n
                     from cma.email_thread_event ev
                     where ev.tenant_id = et.tenant_id and ev.connection_id = et.connection_id
                       and ev.thread_source_id = et.source_id) v on true
  where et.tenant_id = v_tenant and et.connection_id = p_connection_id and et.source_id = any (p_thread_ids)
  order by et.source_id;
end
$$;

-- 0007's associations, and the email engagement (crm_email) stored as the activity side like a call:
-- an association from a contact or a record to an email is turned around
create or replace function cma.ingest_upsert_associations(p_connection_id uuid, p_items jsonb)
returns table (from_type text, from_id text, to_type text, to_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  i          jsonb;
  v_ft       text;
  v_fi       text;
  v_tt       text;
  v_ti       text;
  v_tmp      text;
  v_removed  boolean;
  v_changed  timestamptz;
  v_old      cma.crm_association;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'associations must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for i in select value from jsonb_array_elements(p_items) loop
    v_ft := i ->> 'fromType'; v_fi := i ->> 'fromId'; v_tt := i ->> 'toType'; v_ti := i ->> 'toId';
    if coalesce(v_ft, '') = '' or coalesce(v_fi, '') = '' or coalesce(v_tt, '') = '' or coalesce(v_ti, '') = ''
       or jsonb_typeof(i -> 'removed') is distinct from 'boolean' then
      raise exception 'every association needs fromType, fromId, toType, toId and removed' using errcode = 'CMA04';
    end if;
    v_removed := (i ->> 'removed')::boolean;
    v_changed := cma.json_time(i -> 'changedAt', 'changedAt');
    if v_changed is null then
      raise exception 'every association needs changedAt' using errcode = 'CMA04';
    end if;
    if v_ft = 'contact' or v_tt in ('crm_call', 'crm_email') then
      v_tmp := v_ft; v_ft := v_tt; v_tt := v_tmp;
      v_tmp := v_fi; v_fi := v_ti; v_ti := v_tmp;
    end if;
    select * into v_old from cma.crm_association a
    where a.tenant_id = v_tenant and a.connection_id = p_connection_id
      and a.from_type = v_ft and a.from_id = v_fi and a.to_type = v_tt and a.to_id = v_ti
    for update;
    if v_old.tenant_id is null then
      insert into cma.crm_association (tenant_id, connection_id, from_type, from_id, to_type, to_id, removed_at, source_changed_at)
      values (v_tenant, p_connection_id, v_ft, v_fi, v_tt, v_ti, case when v_removed then v_changed end, v_changed);
      return query select v_ft, v_fi, v_tt, v_ti, case when v_removed then 'removed' else 'added' end;
    elsif v_changed < v_old.source_changed_at then
      return query select v_ft, v_fi, v_tt, v_ti, 'stale'::text;
    else
      update cma.crm_association a
         set removed_at = case when v_removed then coalesce(a.removed_at, v_changed) end,
             source_changed_at = v_changed
       where a.tenant_id = v_tenant and a.connection_id = p_connection_id
         and a.from_type = v_ft and a.from_id = v_fi and a.to_type = v_tt and a.to_id = v_ti;
      return query select v_ft, v_fi, v_tt, v_ti,
        case when v_removed and v_old.removed_at is null then 'removed'
             when not v_removed and v_old.removed_at is not null then 'readded'
             else 'unchanged' end;
    end if;
  end loop;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid association: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Configuration (tenant.configure)
-- ---------------------------------------------------------------------------------------------
-- One inbox's configuration: counted, market (a catalog market or null), work type (an active work
-- type skill's key or null) and channel (an active channel's key or null). An inbox the catalog has
-- not brought yet is added with its id as name.
create or replace function cma.set_inbox(p_connection_id uuid, p_inbox_id text, p_is_counted boolean, p_market text,
                                         p_work_type_key text, p_channel_key text)
returns void
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_skill   uuid;
  v_channel uuid;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_email_connection(p_connection_id, false);
  if coalesce(p_inbox_id, '') = '' or p_is_counted is null then
    raise exception 'an inbox id is needed, and counted must be true or false' using errcode = 'CMA04';
  end if;
  if p_market is not null then
    perform cma.assert_market(p_market, false);
  end if;
  if coalesce(p_work_type_key, '') <> '' then
    select s.id into v_skill from cma.skill s
    where s.tenant_id = v_tenant and s.dimension = 'work_type' and s.key = p_work_type_key and s.status = 'active';
    if v_skill is null then
      raise exception 'no active work type %', p_work_type_key using errcode = 'CMA02';
    end if;
  end if;
  if coalesce(p_channel_key, '') <> '' then
    select ch.id into v_channel from cma.channel ch where ch.tenant_id = v_tenant and ch.key = p_channel_key and ch.status = 'active';
    if v_channel is null then
      raise exception 'no active channel %', p_channel_key using errcode = 'CMA02';
    end if;
  end if;
  insert into cma.connection_inbox (tenant_id, connection_id, source_inbox_id, name, is_counted, market, work_type_skill_id, channel_id)
  values (v_tenant, p_connection_id, p_inbox_id, left(p_inbox_id, 200), p_is_counted, p_market, v_skill, v_channel)
  on conflict (tenant_id, connection_id, source_inbox_id) do update
    set is_counted = excluded.is_counted, market = excluded.market, work_type_skill_id = excluded.work_type_skill_id,
        channel_id = excluded.channel_id;
exception when check_violation or not_null_violation then
  raise exception 'invalid inbox: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- One source channel's configuration: the tenant's channel it counts under (an active channel's key or
-- null) and whether it counts. A channel the catalog has not brought yet is added with its id as name.
create or replace function cma.set_inbox_channel(p_connection_id uuid, p_channel_id text, p_channel_key text, p_is_counted boolean)
returns void
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_channel uuid;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_email_connection(p_connection_id, false);
  if coalesce(p_channel_id, '') = '' or p_is_counted is null then
    raise exception 'a channel id is needed, and counted must be true or false' using errcode = 'CMA04';
  end if;
  if coalesce(p_channel_key, '') <> '' then
    select ch.id into v_channel from cma.channel ch where ch.tenant_id = v_tenant and ch.key = p_channel_key and ch.status = 'active';
    if v_channel is null then
      raise exception 'no active channel %', p_channel_key using errcode = 'CMA02';
    end if;
  end if;
  insert into cma.connection_inbox_channel (tenant_id, connection_id, source_channel_id, name, channel_id, is_counted)
  values (v_tenant, p_connection_id, p_channel_id, left(p_channel_id, 200), v_channel, p_is_counted)
  on conflict (tenant_id, connection_id, source_channel_id) do update
    set channel_id = excluded.channel_id, is_counted = excluded.is_counted;
exception when check_violation or not_null_violation then
  raise exception 'invalid channel: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Creates (p_rule_id null) or changes one classification rule of a connection: what it applies to
-- (sender_domain or subject), its words and exclude words (lower-cased, trimmed, each once; at least
-- one word, at most 20 of each, no comma, semicolon or line break in a word), the category code and
-- its place in the order (null: 100 for a new rule, unchanged otherwise). Answers the rule's id. A
-- rule keeps its status here; cma.set_email_rule_status switches it.
create or replace function cma.set_email_rule(p_connection_id uuid, p_rule_id uuid, p_applies_to text, p_words text[],
                                              p_exclude_words text[], p_category text, p_sort_order integer)
returns uuid
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_words   text[] := cma.email_words(p_words);
  v_exclude text[] := cma.email_words(p_exclude_words);
  v_id      uuid;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_email_connection(p_connection_id, false);
  if coalesce(p_applies_to, '') not in ('sender_domain', 'subject') then
    raise exception 'a rule applies to sender_domain or subject' using errcode = 'CMA04';
  end if;
  if cardinality(v_words) = 0 or cardinality(v_words) > 20 or cardinality(v_exclude) > 20
     or not cma.email_words_ok(v_words) or not cma.email_words_ok(v_exclude) then
    raise exception 'a rule needs 1 to 20 words and at most 20 exclude words, each at most 100 characters without a comma, semicolon or line break'
      using errcode = 'CMA04';
  end if;
  if coalesce(p_category, '') !~ '^[a-z][a-z0-9_]{0,59}$' then
    raise exception 'a category is a code of lower-case letters, digits and _, starting with a letter' using errcode = 'CMA04';
  end if;
  if p_rule_id is null then
    insert into cma.connection_email_rule (tenant_id, connection_id, applies_to, words, exclude_words, category, sort_order)
    values (v_tenant, p_connection_id, p_applies_to, v_words, v_exclude, p_category, coalesce(p_sort_order, 100))
    returning id into v_id;
  else
    update cma.connection_email_rule r
       set applies_to = p_applies_to, words = v_words, exclude_words = v_exclude, category = p_category,
           sort_order = coalesce(p_sort_order, r.sort_order)
     where r.tenant_id = v_tenant and r.connection_id = p_connection_id and r.id = p_rule_id
    returning r.id into v_id;
    if v_id is null then
      raise exception 'no rule % on connection %', p_rule_id, p_connection_id using errcode = 'CMA02';
    end if;
  end if;
  return v_id;
exception when check_violation or not_null_violation then
  raise exception 'invalid rule: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Switches a rule on (active) or off (inactive); a rule is never deleted
create or replace function cma.set_email_rule_status(p_rule_id uuid, p_status text)
returns void
language plpgsql
as $$
declare
  v_found boolean;
begin
  perform cma.assert_permission('tenant.configure');
  if coalesce(p_status, '') not in ('active', 'inactive') then
    raise exception 'a rule''s status is active or inactive' using errcode = 'CMA04';
  end if;
  select true into v_found from cma.connection_email_rule r where r.tenant_id = cma.current_tenant_id() and r.id = p_rule_id;
  if v_found is null then
    raise exception 'no rule % in the current tenant', p_rule_id using errcode = 'CMA02';
  end if;
  update cma.connection_email_rule r set status = p_status
  where r.tenant_id = cma.current_tenant_id() and r.id = p_rule_id and r.status <> p_status;
end
$$;

-- 0007c's connection_config, plus the inboxes, the source channels and the classification rules in
-- their order: {..., inboxes: [{inboxId, name, isCounted, market, workType, channel, status}],
-- inboxChannels: [{channelId, name, kind, channel, isCounted, status}], emailRules: [{id, appliesTo,
-- words, excludeWords, category, order, status}]}
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
                                                             'property', f.source_property)
                                         order by f.entity, f.field, f.ref_system, f.slot)
                        from cma.connection_field f where f.tenant_id = v_tenant and f.connection_id = p_connection_id), '[]'::jsonb),
    'pipelines', coalesce((select jsonb_agg(jsonb_build_object('recordType', p.record_type, 'pipelineId', p.source_pipeline_id,
                                                                'label', p.label, 'isCounted', p.is_counted, 'isRouted', p.is_routed,
                                                                'isLead', p.is_lead, 'workType', s.key, 'status', p.status)
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
    'emailRules', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'appliesTo', r.applies_to, 'words', to_jsonb(r.words),
                                                                 'excludeWords', to_jsonb(r.exclude_words), 'category', r.category,
                                                                 'order', r.sort_order, 'status', r.status)
                                             order by r.sort_order, r.created_at, r.id)
                            from cma.connection_email_rule r
                            where r.tenant_id = v_tenant and r.connection_id = p_connection_id), '[]'::jsonb));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Privacy deletions
-- ---------------------------------------------------------------------------------------------
-- As 0007a, and the contact is also cleared on the connection's emails and threads (ids, times and
-- the metadata stay for the counts). Answers {contacts, refs, calls, submissions}, plus
-- telephony_calls, emails and threads when one was cleared (the earlier answer shape stays as it
-- was otherwise).
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
  v_res     jsonb;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if coalesce(p_contact_source_id, '') = '' then
    raise exception 'a contact id is needed' using errcode = 'CMA04';
  end if;
  update cma.crm_contact cc
     set country = null, language = null, currency = null, store = null, raw = '{}'::jsonb,
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
  update cma.form_submission s set kept_values = '{}'::jsonb, synced_at = now()
  where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.contact_source_id = p_contact_source_id
    and s.kept_values <> '{}'::jsonb;
  get diagnostics v_s = row_count;
  update cma.email_message em set contact_source_id = null, synced_at = now()
  where em.tenant_id = v_tenant and em.connection_id = p_connection_id and em.contact_source_id = p_contact_source_id;
  get diagnostics v_e = row_count;
  update cma.email_thread et set contact_source_id = null, synced_at = now()
  where et.tenant_id = v_tenant and et.connection_id = p_connection_id and et.contact_source_id = p_contact_source_id;
  get diagnostics v_h = row_count;
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
  return v_res;
end
$$;

-- A conversation's privacy deletion at the source: the thread and its inbox messages lose contact,
-- ticket and raw payload and keep ids, times, status, direction and actor kinds for the counts; the
-- thread is marked forgotten, so a later read cannot bring them back. Its events hold nothing to
-- clear. Answers {threads, messages}.
create or replace function cma.ingest_thread_forget(p_connection_id uuid, p_thread_source_id text)
returns jsonb
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_t      integer := 0;
  v_m      integer := 0;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.assert_email_connection(p_connection_id, true);
  if coalesce(p_thread_source_id, '') = '' then
    raise exception 'a thread id is needed' using errcode = 'CMA04';
  end if;
  update cma.email_thread et
     set contact_source_id = null, ticket_source_id = null, raw = '{}'::jsonb,
         forgotten_at = coalesce(et.forgotten_at, now()), synced_at = now()
   where et.tenant_id = v_tenant and et.connection_id = p_connection_id and et.source_id = p_thread_source_id;
  get diagnostics v_t = row_count;
  update cma.email_message em set contact_source_id = null, raw = '{}'::jsonb, synced_at = now()
  where em.tenant_id = v_tenant and em.connection_id = p_connection_id and em.source_kind = 'inbox_message'
    and em.thread_source_id = p_thread_source_id
    and (em.contact_source_id is not null or em.raw <> '{}'::jsonb);
  get diagnostics v_m = row_count;
  return jsonb_build_object('threads', v_t, 'messages', v_m);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Reads of an explicit tenant (in the caller's rights, as 0007d)
-- ---------------------------------------------------------------------------------------------
-- The first date of email reporting and of the email backfill: email.start_date, else intake.start_date
create or replace function cma.email_start_date_of(p_tenant_id uuid)
returns date
language sql stable
as $$
  select coalesce(nullif(cma.setting_of(p_tenant_id, 'email.start_date'), ''), cma.setting_of(p_tenant_id, 'intake.start_date'))::date
$$;

-- The category the connection's rules give a sender domain and a subject: the first active rule, by
-- its order (then its creation), whose words the value of its kind contains and none of its exclude
-- words; null when none matches. The definition the ingest service applies in memory (B17b) to the
-- rules connection_config gives it; the owner's only, so it is never called with a real subject.
create or replace function cma.email_category_of(p_tenant_id uuid, p_connection_id uuid, p_sender_domain text, p_subject text)
returns text
language sql stable
as $$
  select r.category
  from cma.connection_email_rule r
  where r.tenant_id = p_tenant_id and r.connection_id = p_connection_id and r.status = 'active'
    and cma.email_words_match(case r.applies_to when 'sender_domain' then p_sender_domain else p_subject end,
                              r.words, r.exclude_words)
  order by r.sort_order, r.created_at, r.id
  limit 1
$$;

-- The market of an email (p_source_kind crm_email or inbox_message) or of an inbox conversation
-- (inbox_thread) by email.market_order, read at query time so a later alias or configuration applies
-- to older emails (as 0007d):
--   record   the associated ticket's market, else the associated deal's (an email engagement: its
--            current associations, the newest record first; an inbox message or thread: the thread's
--            ticket); deleted records are left out
--   inbox    the inbox's market (a message's inbox, else its thread's)
--   contact  the contact's country (a message's contact, else for an engagement its earliest current
--            contact association, for an inbox message its thread's contact), held as 0006 holds
--            contacts
-- each through the tenant's market aliases and only when it names a catalog market; 'unknown' when no
-- step finds one (and for an email the tenant does not hold). source says which step gave it.
create or replace function cma.email_market_of(p_tenant_id uuid, p_connection_id uuid, p_source_kind text, p_source_id text,
                                               out code text, out source text)
language plpgsql stable
as $$
declare
  v_order   text[] := string_to_array(cma.setting_of(p_tenant_id, 'email.market_order'), ',');
  v_msg     cma.email_message;
  v_thread  cma.email_thread;
  v_step    text;
  v_value   text;
  v_contact text;
begin
  code := 'unknown';
  source := null;
  if p_source_kind = 'inbox_thread' then
    select * into v_thread from cma.email_thread et
    where et.tenant_id = p_tenant_id and et.connection_id = p_connection_id and et.source_id = p_source_id;
    if v_thread.id is null then
      return;
    end if;
  elsif p_source_kind in ('crm_email', 'inbox_message') then
    select * into v_msg from cma.email_message em
    where em.tenant_id = p_tenant_id and em.connection_id = p_connection_id and em.source_kind = p_source_kind
      and em.source_id = p_source_id;
    if v_msg.id is null then
      return;
    end if;
    if p_source_kind = 'inbox_message' then
      select * into v_thread from cma.email_thread et
      where et.tenant_id = p_tenant_id and et.connection_id = p_connection_id and et.source_id = v_msg.thread_source_id;
    end if;
  else
    raise exception 'the source kind is crm_email, inbox_message or inbox_thread' using errcode = 'CMA04';
  end if;

  foreach v_step in array coalesce(v_order, '{}') loop
    v_value := null;
    if v_step = 'record' then
      if p_source_kind = 'crm_email' then
        select cma.market_code_of(p_tenant_id, cr.market) into v_value
        from cma.crm_association a
        join cma.crm_record cr
          on cr.tenant_id = a.tenant_id and cr.connection_id = a.connection_id and cr.record_type = a.to_type and cr.source_id = a.to_id
        where a.tenant_id = p_tenant_id and a.connection_id = p_connection_id
          and a.from_type = 'crm_email' and a.from_id = p_source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null
          and cr.source_deleted_at is null and cma.market_code_of(p_tenant_id, cr.market) is not null
        order by (a.to_type = 'ticket') desc, cr.source_created_at desc, cr.source_id
        limit 1;
      elsif v_thread.ticket_source_id is not null then
        select cma.market_code_of(p_tenant_id, cr.market) into v_value
        from cma.crm_record cr
        where cr.tenant_id = p_tenant_id and cr.connection_id = p_connection_id and cr.record_type = 'ticket'
          and cr.source_id = v_thread.ticket_source_id and cr.source_deleted_at is null;
      end if;
    elsif v_step = 'inbox' then
      select cma.market_code_of(p_tenant_id, b.market) into v_value
      from cma.connection_inbox b
      where b.tenant_id = p_tenant_id and b.connection_id = p_connection_id
        and b.source_inbox_id = coalesce(v_msg.inbox_source_id, v_thread.inbox_source_id);
    elsif v_step = 'contact' then
      v_contact := coalesce(v_msg.contact_source_id, v_thread.contact_source_id);
      if v_contact is null and p_source_kind = 'crm_email' then
        select a.to_id into v_contact
        from cma.crm_association a
        where a.tenant_id = p_tenant_id and a.connection_id = p_connection_id
          and a.from_type = 'crm_email' and a.from_id = p_source_id and a.to_type = 'contact' and a.removed_at is null
        order by a.first_seen_at, a.to_id
        limit 1;
      end if;
      if v_contact is not null then
        select cma.market_code_of(p_tenant_id, cc.country) into v_value
        from cma.crm_contact cc
        where cc.tenant_id = p_tenant_id and cc.connection_id = p_connection_id and cc.source_id = v_contact;
      end if;
    end if;
    if v_value is not null then
      code := v_value;
      source := v_step;
      return;
    end if;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Grants: the application only (email_category_of the owner's only)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.ingest_upsert_inboxes(uuid,jsonb)',
    'cma.ingest_upsert_inbox_channels(uuid,jsonb)',
    'cma.ingest_upsert_threads(uuid,jsonb)',
    'cma.ingest_upsert_emails(uuid,jsonb)',
    'cma.ingest_upsert_thread_events(uuid,jsonb)',
    'cma.ingest_thread_marks(uuid,text[])',
    'cma.ingest_upsert_associations(uuid,jsonb)',
    'cma.set_inbox(uuid,text,boolean,text,text,text)',
    'cma.set_inbox_channel(uuid,text,text,boolean)',
    'cma.set_email_rule(uuid,uuid,text,text[],text[],text,integer)',
    'cma.set_email_rule_status(uuid,text)',
    'cma.connection_config(uuid)',
    'cma.ingest_contact_forget(uuid,text)',
    'cma.ingest_thread_forget(uuid,text)',
    'cma.email_start_date_of(uuid)',
    'cma.email_market_of(uuid,uuid,text,text)',
    'cma.connection_held_kinds_of(uuid,uuid)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- helpers the functions and the tables' checks call in the caller's rights
  foreach f in array array[
    'cma.is_email_market_order(text)', 'cma.email_words(text[])', 'cma.email_words_ok(text[])',
    'cma.email_words_match(text,text[],text[])', 'cma.email_raw(jsonb)', 'cma.assert_email_connection(uuid,boolean)',
    'cma.json_flag(jsonb,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  execute 'revoke execute on function cma.email_category_of(uuid,uuid,text,text) from public';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. Reporting views: every column but the raw payload
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.connection_inbox as
  select tenant_id, connection_id, source_inbox_id, name, is_counted, market, work_type_skill_id, channel_id, status,
         refreshed_at, updated_at
  from cma.connection_inbox
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.connection_inbox_channel as
  select tenant_id, connection_id, source_channel_id, name, kind, channel_id, is_counted, status, refreshed_at, updated_at
  from cma.connection_inbox_channel
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.connection_email_rule as
  select id, tenant_id, connection_id, applies_to, words, exclude_words, category, sort_order, status, created_at, updated_at
  from cma.connection_email_rule
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.email_thread as
  select id, tenant_id, connection_id, source_system, source_id, inbox_source_id, channel_source_id, status, source_created_at,
         closed_at, owner_ref, contact_source_id, ticket_source_id, is_spam, is_archived, category, latest_received_at,
         latest_sent_at, source_updated_at, forgotten_at, synced_at
  from cma.email_thread
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.email_message as
  select id, tenant_id, connection_id, source_system, source_kind, source_id, thread_source_id, inbox_source_id, channel_source_id,
         direction, status, occurred_at, actor_kind, owner_ref, category, contact_source_id, source_created_at, source_updated_at,
         source_deleted_at, synced_at
  from cma.email_message
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.email_thread_event as
  select id, tenant_id, connection_id, source_id, thread_source_id, kind, occurred_at, actor_kind, owner_ref, to_actor_kind,
         to_owner_ref, from_inbox_source_id, to_inbox_source_id, synced_at
  from cma.email_thread_event
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 11. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008m', 'Email activity, metadata only: inboxes and source channels with counted, market, work type and channel, classification rules, emails of two sources kept apart, inbox conversations and their events, the four email settings, the ingest writes, the market by email.market_order, the privacy deletions, the reporting views')
on conflict (version) do nothing;

commit;
reset role;
