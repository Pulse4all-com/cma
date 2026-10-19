-- =============================================================================================
-- 82_email_reports.sql: addition 0008t, email reports (B17c)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 80_follow_up_snapshot.sql (0008s). Rerunnable, forward-only, in one transaction. Run as your own IAM
-- login, dev first, then prod; then rerun 02_seed_<customer>.sql (the per-person setting), then
-- 83_verify_email_reports.sql (dev), then 69_verify_email_activity.sql, 73_verify_follow_up.sql,
-- 75_verify_forms_reporting.sql and 81_verify_follow_up_snapshot.sql (dev) again (unchanged).
--
-- Brief N19-A, part 1 (README Decision log, 18 October 2026; backlog CMA-008, CMA-051): managers and
-- analytics read emails received per mailbox and sent per agent in HubSpot today. Addition 0008m holds
-- the data, filled by the email poll of brief B17b since 16 October 2026; this addition adds the
-- mailboxes (a source's channel accounts), the origin of an email engagement, the per-person setting
-- and the reports' reads. Metadata only: ids, counts, times and codes; never a subject, a body, an
-- address, a name, a phone number or a header (README, Data model: email activity).
--
-- What it adds
--   setting            reports.per_person (text, default empty): the per-person report pages switched
--                      on, comma-separated keys from the fixed list email, orders, each once, lower case,
--                      no spaces. Calls per agent is not under it. cma.per_person_on(tenant, key)
--   mailboxes          cma.connection_inbox_account: per connection the inboxes' channel accounts (a
--                      shared address connected to an inbox): the source's id, the name as the source
--                      gives it (refreshed; never an address: one that holds an @ gives way to the id),
--                      a label a person sets (survives every refresh), the inbox and source channel refs,
--                      counted (default true), market (catalog), status. cma.set_inbox_account()
--                      (tenant.configure), cma.ingest_upsert_inbox_accounts() (ingest.write, at most 500)
--   account refs       email_message.account_ref and email_thread.account_ref (the channel account a
--                      message went through, the account a thread started on); refs as every 0008m ref
--                      (no @, no white space); a later read without one keeps the stored one
--   origin             email_message.origin: the value of the connection's setting
--                      email_origin_property for an engagement (^[A-Za-z0-9_.:-]{1,60}$), filled for the
--                      engagements already stored from their raw payload. The connection setting
--                      email_inbox_copy_origins (comma-separated) names the origins whose engagement is a
--                      copy of an inbox message: left out of every report. email_automated_origins (B17b)
--                      names the automations' origins: counted as automated, apart from agent sends
--   market             cma.email_market_of(): the inbox step reads the message's (or the thread's)
--                      account's market first, then the inbox's; everything else as 0008m
--   definitions        cma.email_of(tenant, from, to): every email of a period that the reports count,
--                      one row each with its flags, market, zone, business date and hour;
--                      cma.email_openings_of(tenant, from, to): every opening of an inbox conversation
--                      with its first incoming message, first agent reply and close;
--                      cma.email_closes_of(tenant, from, to): every close of a counted conversation
--   reads              cma.email_overview(), cma.email_by_dimension(), cma.email_received_series(),
--                      cma.email_report() (the report page's one read: every section of the period at once),
--                      cma.email_per_person() (performance.team and reports.per_person holding email),
--                      cma.email_waiting(), cma.email_not_responding(), cma.email_history_start();
--                      each over a read of an explicit tenant (cma.*_of), as 0007d and 0008o
--   shared             cma.crm_call_connected_of(): whether a CRM call is a conversation as 0008j defines
--                      one, through the call link (part 2 of N19-A uses it too)
--   reporting views    cma_read.connection_inbox_account; email_message and email_thread with the new
--                      columns at the end; cma_read.email_waiting and email_not_responding (ids and ages)
--
-- Definitions (one place each; README, Data model: email reports)
--   counted email      not deleted. An inbox message: its inbox, account and channel count (one the
--                      catalog has not brought yet counts, as a line does in 0008j) and its thread is not
--                      spam. An engagement: its origin is none of the connection's inbox-copy origins
--   received           an inbox message in or forwarded. An engagement in or forwarded is a logged reply,
--                      a column of its own, never added to the inbox total (B17 R8)
--   sent               direction out, status sent; automated when an engagement's origin is one of the
--                      connection's automated origins or an inbox message's actor is a bot, an AI, the
--                      system or an integration; an agent send otherwise. Bounced and failed apart
--   opening            a counted, non-spam conversation's creation, or a reopen whose latest status
--                      event before it is a close (a reopen with no close before it is no opening: README
--                      Open decisions, reopens at a thread's creation)
--   first reply        per opening, the first incoming message after the close it follows (any for a
--                      creation) up to the opening's close, then the first outgoing message by an agent,
--                      not failed, after it, up to that close: elapsed seconds, and business seconds in
--                      the thread's market (cma.business_seconds_of; none for an unknown market), within
--                      email.reply_target_minutes or not
--   time to close      opening to the first close at or after it
--   credited person    the replying agent (a reply), the closing agent (a close), the sending agent (a
--                      send), through the linked accounts '<adapter>_owner' (0008e); an agent's action
--                      without a person, or a send without an owner, counts as not linked, never by id;
--                      a close by anyone who is not an agent is in the team figures only
--   date, week, hour   in the email's (the opening's, the close's) market zone, else the tenant's
--   waiting now        an open, counted, non-spam conversation whose latest incoming message is later
--                      than its latest agent message: waiting since the first incoming message after
--                      that agent message (or the first ever), in business and elapsed seconds
--   not responding     an open lead deal (0007d's population) whose contacts' latest agent email out is
--                      at least email.no_response_days old, with no incoming email, inbox message or
--                      connected call (0008j) on the deal or its contacts since
--
-- Everything is SECURITY INVOKER and executable by the application only; the cma_read functions of the
-- two reader views are SECURITY DEFINER, owned by cma_owner, executable by readers only (as 0008o). The
-- reads return ids, codes, counts and times: no subject, address, name or phone number exists to return.
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
  if not exists (select 1 from cma.schema_migration where version = '0008s') then
    raise exception 'addition 0008s (80_follow_up_snapshot.sql) must run before 0008t';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The per-person setting
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('reports.per_person', 'text', null, '',
     'Per-person report pages switched on: comma-separated keys from email and orders, each once, lower case, no spaces; empty for none. Calls per agent is not under this setting')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- reports.per_person: empty, or one or two of email and orders, each once, comma-separated without spaces
create or replace function cma.is_per_person_list(p_value text)
returns boolean
language sql immutable
as $$
  select coalesce(p_value = ''
                  or (p_value ~ '^(email|orders)(,(email|orders))?$'
                      and (select count(*) = count(distinct x) from unnest(string_to_array(p_value, ',')) x)), false)
$$;

-- As 0008s, plus reports.per_person
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
  -- the per-person report pages (0008t): from the fixed list email, orders
  elsif new.key = 'reports.per_person' and not cma.is_per_person_list(new.value) then
    raise exception 'Setting % takes email and orders, each at most once, lower case, comma-separated without spaces, or nothing', new.key
      using errcode = 'CMA04';
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- Whether the tenant switched a per-person report page on (reports.per_person holds the key)
create or replace function cma.per_person_on(p_tenant_id uuid, p_key text)
returns boolean
language sql stable
as $$
  select coalesce(p_key = any (string_to_array(nullif(cma.setting_of(p_tenant_id, 'reports.per_person'), ''), ',')), false)
$$;

-- A per-person read: performance.team, and the tenant's reports.per_person holding the key; else CMA06
create or replace function cma.assert_per_person(p_key text)
returns void
language plpgsql stable
as $$
begin
  perform cma.assert_permission('performance.team');
  if not cma.per_person_on(cma.current_tenant_id(), p_key) then
    raise exception 'per-person figures for % are switched off for this tenant (reports.per_person)', p_key using errcode = 'CMA06';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Mailboxes: the inboxes' channel accounts
-- ---------------------------------------------------------------------------------------------
-- A channel account of a connection's conversations (a shared address connected to an inbox). The
-- name is the source's, refreshed, and never an address (the second line: no @); the label is a
-- person's and survives every refresh; counted and market are configuration. Never deleted: an
-- account the source drops is archived.
create table if not exists cma.connection_inbox_account (
  tenant_id          uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id      uuid not null,
  source_account_id  text not null check (source_account_id ~ '^[^@[:space:]]{1,100}$'),
  name               text not null check (length(btrim(name)) between 1 and 200 and strpos(name, '@') = 0),
  label              text check (length(btrim(label)) between 1 and 80 and strpos(label, '@') = 0),
  inbox_source_id    text check (inbox_source_id ~ '^[^@[:space:]]{1,100}$'),
  channel_source_id  text check (channel_source_id ~ '^[^@[:space:]]{1,100}$'),
  is_counted         boolean not null default true,
  market             text,
  status             text not null default 'active' check (status in ('active', 'archived')),
  refreshed_at       timestamptz,
  updated_at         timestamptz not null default now(),
  primary key (tenant_id, connection_id, source_account_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id),
  foreign key (tenant_id, market) references cma.market (tenant_id, code)
);
comment on table cma.connection_inbox_account is 'Mailboxes: the channel accounts of a connection''s inboxes. Name from the source (never an address), a person''s label, counted and market as configuration';
create or replace trigger set_updated_at before update on cma.connection_inbox_account
  for each row execute function cma.set_updated_at();
select cma.setup_tenant_table('cma.connection_inbox_account');
revoke delete on cma.connection_inbox_account from cma_app;

-- The channel account a message went through and the account a conversation started on
alter table cma.email_message add column if not exists account_ref text;
alter table cma.email_message drop constraint if exists email_message_account_ref_check;
alter table cma.email_message add constraint email_message_account_ref_check check (account_ref ~ '^[^@[:space:]]{1,100}$');
alter table cma.email_thread add column if not exists account_ref text;
alter table cma.email_thread drop constraint if exists email_thread_account_ref_check;
alter table cma.email_thread add constraint email_thread_account_ref_check check (account_ref ~ '^[^@[:space:]]{1,100}$');
comment on column cma.email_message.account_ref is 'The source''s channel account (mailbox) the message went through (0008t)';
comment on column cma.email_thread.account_ref is 'The source''s channel account (mailbox) the conversation started on (0008t)';

-- An engagement's origin: the value of the connection's email_origin_property, a code
alter table cma.email_message add column if not exists origin text;
alter table cma.email_message drop constraint if exists email_message_origin_check;
alter table cma.email_message add constraint email_message_origin_check check (origin ~ '^[A-Za-z0-9_.:-]{1,60}$');
comment on column cma.email_message.origin is
  'The source''s origin code of an email engagement (the connection''s email_origin_property; 0008t): inbox copies and automations are told apart by it, as configuration';
-- The engagements stored before 0008t kept the origin in their raw payload (B17b); one update each
update cma.email_message em set origin = em.raw ->> 'origin'
where em.origin is null and em.source_kind = 'crm_email' and (em.raw ->> 'origin') ~ '^[A-Za-z0-9_.:-]{1,60}$';

create index if not exists email_message_account_idx on cma.email_message (tenant_id, connection_id, account_ref)
  where account_ref is not null;

-- ---------------------------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------------------------
-- A connection setting's comma-separated codes, trimmed and in lower case, each once; empty: none
create or replace function cma.setting_codes(p_settings jsonb, p_key text)
returns text[]
language sql immutable
as $$
  select coalesce(array_agg(distinct lower(btrim(x)) order by lower(btrim(x))) filter (where btrim(x) <> ''), '{}'::text[])
  from unnest(string_to_array(coalesce(p_settings ->> p_key, ''), ',')) x
$$;

-- Whether a CRM call is a conversation as 0008j defines one, through the call link: the linked
-- telephony call (while the link is current) is an answered inbound call, or an outbound call with at
-- least telephony.connected_min_seconds of talk time; a CRM call without a current link is one when its
-- outcome is connected (0007's catalog). With the call's effective time: the linked telephony call's
-- start, else the CRM call's time (0007d)
create or replace function cma.crm_call_connected_of(p_tenant_id uuid, p_crm_call_id uuid,
                                                     out effective_at timestamptz, out is_connected boolean)
language sql stable
as $$
  select coalesce(tc.started_at, cc.occurred_at),
         case when tc.id is not null
              then (tc.direction = 'inbound' and tc.answered_at is not null)
                   or (tc.direction = 'outbound'
                       and coalesce(tc.talk_seconds >= greatest(0, cma.setting_of(p_tenant_id, 'telephony.connected_min_seconds')::integer), false))
              else coalesce(o.is_connected, false) end
  from cma.crm_call cc
  left join cma.call_link l on l.tenant_id = cc.tenant_id and l.crm_call_id = cc.id and l.unlinked_at is null
  left join cma.telephony_call tc on tc.tenant_id = l.tenant_id and tc.id = l.telephony_call_id and tc.source_deleted_at is null
  left join cma.connection_call_outcome o
    on o.tenant_id = cc.tenant_id and o.connection_id = cc.connection_id and o.outcome_ref = cc.outcome_ref
  where cc.tenant_id = p_tenant_id and cc.id = p_crm_call_id
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The ingest writes (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- Refreshes the mailbox catalog: [{accountId, name, inboxId, channelId}], at most 500. The name is the
-- source's (one holding an @ gives way to the id: a mailbox's address is never stored); the label,
-- counted and market stay; an account missing from the list is archived. Answers the active count.
create or replace function cma.ingest_upsert_inbox_accounts(p_connection_id uuid, p_items jsonb)
returns integer
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  i        jsonb;
  v_name   text;
  v_n      integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.assert_email_connection(p_connection_id, true);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'mailboxes must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for i in select value from jsonb_array_elements(p_items) loop
    if coalesce(i ->> 'accountId', '') = '' then
      raise exception 'every mailbox needs an accountId' using errcode = 'CMA04';
    end if;
    v_name := nullif(btrim(i ->> 'name'), '');
    if v_name is null or strpos(v_name, '@') > 0 then
      v_name := i ->> 'accountId';
    end if;
    insert into cma.connection_inbox_account as a (tenant_id, connection_id, source_account_id, name, inbox_source_id, channel_source_id,
                                                   status, refreshed_at)
    values (v_tenant, p_connection_id, i ->> 'accountId', left(v_name, 200), nullif(i ->> 'inboxId', ''), nullif(i ->> 'channelId', ''),
            'active', now())
    on conflict (tenant_id, connection_id, source_account_id)
      do update set name = excluded.name,
                    inbox_source_id = coalesce(excluded.inbox_source_id, a.inbox_source_id),
                    channel_source_id = coalesce(excluded.channel_source_id, a.channel_source_id),
                    status = 'active', refreshed_at = now();
  end loop;
  update cma.connection_inbox_account b set status = 'archived'
  where b.tenant_id = v_tenant and b.connection_id = p_connection_id and b.status = 'active'
    and not exists (select 1 from jsonb_array_elements(p_items) x where x ->> 'accountId' = b.source_account_id);
  select count(*)::integer into v_n from cma.connection_inbox_account b
  where b.tenant_id = v_tenant and b.connection_id = p_connection_id and b.status = 'active';
  return v_n;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid mailbox: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- As 0008m, and a thread item takes accountId (the account it started on); a read without one keeps
-- the stored one, as for the inbox and the channel
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
      insert into cma.email_thread (tenant_id, connection_id, source_system, source_id, inbox_source_id, channel_source_id, account_ref,
                                    status, source_created_at, closed_at, owner_ref, contact_source_id, ticket_source_id, is_spam,
                                    is_archived, category, latest_received_at, latest_sent_at, source_updated_at, raw)
      values (v_tenant, p_connection_id, v_system, v_src, nullif(t ->> 'inboxId', ''), nullif(t ->> 'channelId', ''),
              nullif(t ->> 'accountId', ''), v_status,
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
             account_ref = coalesce(nullif(t ->> 'accountId', ''), et.account_ref),
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

-- As 0008m, and an email item takes accountId (the channel account an inbox message went through) and
-- origin (an engagement's origin code); a read without either keeps the stored one
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
                                     channel_source_id, account_ref, direction, status, occurred_at, actor_kind, owner_ref, category,
                                     origin, contact_source_id, source_created_at, source_updated_at, raw)
      values (v_tenant, p_connection_id, v_system, v_kind, v_src, nullif(e ->> 'threadId', ''), nullif(e ->> 'inboxId', ''),
              nullif(e ->> 'channelId', ''), nullif(e ->> 'accountId', ''), e ->> 'direction', coalesce(nullif(e ->> 'status', ''), 'other'),
              cma.json_time(e -> 'occurredAt', 'occurredAt'), coalesce(nullif(e ->> 'actorKind', ''), 'unknown'),
              nullif(e ->> 'ownerRef', ''), nullif(e ->> 'category', ''), nullif(e ->> 'origin', ''),
              case when not v_forgotten then nullif(e ->> 'contactId', '') end,
              cma.json_time(e -> 'createdAt', 'createdAt'), v_updated,
              case when v_forgotten then '{}'::jsonb else cma.email_raw(e -> 'raw') end);
      return query select v_kind, v_src, 'inserted'::text;
    else
      update cma.email_message em
         set thread_source_id = coalesce(nullif(e ->> 'threadId', ''), em.thread_source_id),
             inbox_source_id = coalesce(nullif(e ->> 'inboxId', ''), em.inbox_source_id),
             channel_source_id = coalesce(nullif(e ->> 'channelId', ''), em.channel_source_id),
             account_ref = coalesce(nullif(e ->> 'accountId', ''), em.account_ref),
             direction = e ->> 'direction',
             status = coalesce(nullif(e ->> 'status', ''), 'other'),
             occurred_at = cma.json_time(e -> 'occurredAt', 'occurredAt'),
             actor_kind = coalesce(nullif(e ->> 'actorKind', ''), 'unknown'),
             owner_ref = nullif(e ->> 'ownerRef', ''),
             category = coalesce(nullif(e ->> 'category', ''), em.category),
             origin = coalesce(nullif(e ->> 'origin', ''), em.origin),
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

-- ---------------------------------------------------------------------------------------------
-- 5. Configuration (tenant.configure)
-- ---------------------------------------------------------------------------------------------
-- One mailbox's configuration: its label (1 to 80 characters without an @, or null for the source's
-- name), counted and market (a catalog market or null). An account the catalog has not brought yet is
-- added with its id as name, as cma.set_inbox does.
create or replace function cma.set_inbox_account(p_connection_id uuid, p_account_id text, p_label text, p_is_counted boolean,
                                                 p_market text)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_label  text := nullif(btrim(p_label), '');
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_email_connection(p_connection_id, false);
  if coalesce(p_account_id, '') = '' or p_is_counted is null then
    raise exception 'a mailbox id is needed, and counted must be true or false' using errcode = 'CMA04';
  end if;
  if v_label is not null and (length(v_label) > 80 or strpos(v_label, '@') > 0) then
    raise exception 'a mailbox label has 1 to 80 characters and no @: the CMA keeps no address' using errcode = 'CMA04';
  end if;
  if p_market is not null then
    perform cma.assert_market(p_market, false);
  end if;
  insert into cma.connection_inbox_account (tenant_id, connection_id, source_account_id, name, label, is_counted, market)
  values (v_tenant, p_connection_id, p_account_id, left(p_account_id, 200), v_label, p_is_counted, p_market)
  on conflict (tenant_id, connection_id, source_account_id) do update
    set label = excluded.label, is_counted = excluded.is_counted, market = excluded.market;
exception when check_violation or not_null_violation then
  raise exception 'invalid mailbox: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- As 0008m, plus inboxAccounts (the mailboxes, in their order), for the adapter and the Sources screen
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
-- 6. The market of an email: the account's market in the inbox step
-- ---------------------------------------------------------------------------------------------
-- As 0008m, and the inbox step reads the message's account (else its thread's) first, then the
-- message's inbox (else its thread's): a mailbox of one market in a shared inbox gives its market
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
  v_at      timestamptz;
begin
  code := 'unknown';
  source := null;
  if p_source_kind = 'inbox_thread' then
    select * into v_thread from cma.email_thread et
    where et.tenant_id = p_tenant_id and et.connection_id = p_connection_id and et.source_id = p_source_id;
    if v_thread.id is null then
      return;
    end if;
    v_at := v_thread.source_created_at;
  elsif p_source_kind in ('crm_email', 'inbox_message') then
    select * into v_msg from cma.email_message em
    where em.tenant_id = p_tenant_id and em.connection_id = p_connection_id and em.source_kind = p_source_kind
      and em.source_id = p_source_id;
    if v_msg.id is null then
      return;
    end if;
    v_at := v_msg.occurred_at;
    if p_source_kind = 'inbox_message' then
      select * into v_thread from cma.email_thread et
      where et.tenant_id = p_tenant_id and et.connection_id = p_connection_id and et.source_id = v_msg.thread_source_id;
    end if;
  else
    raise exception 'the source kind is crm_email, inbox_message or inbox_thread' using errcode = 'CMA04';
  end if;

  -- the contact of the email or conversation, for the contact and form steps
  v_contact := coalesce(v_msg.contact_source_id, v_thread.contact_source_id);
  if v_contact is null and p_source_kind = 'crm_email' then
    select a.to_id into v_contact
    from cma.crm_association a
    where a.tenant_id = p_tenant_id and a.connection_id = p_connection_id
      and a.from_type = 'crm_email' and a.from_id = p_source_id and a.to_type = 'contact' and a.removed_at is null
    order by a.first_seen_at, a.to_id
    limit 1;
  end if;

  foreach v_step in array coalesce(v_order, '{}') loop
    v_value := null;
    if v_step = 'contact' then
      if v_contact is not null then
        select cma.market_code_of(p_tenant_id, cc.country) into v_value
        from cma.crm_contact cc
        where cc.tenant_id = p_tenant_id and cc.connection_id = p_connection_id and cc.source_id = v_contact;
      end if;
    elsif v_step = 'form' then
      if v_contact is not null then
        select cma.market_code_of(p_tenant_id, f.market) into v_value
        from cma.form_submission fs
        join cma.connection_form f
          on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
        where fs.tenant_id = p_tenant_id and fs.connection_id = p_connection_id
          and fs.contact_source_id = v_contact and fs.contact_resolution = 'resolved' and fs.submitted_at <= v_at
          and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
        order by fs.submitted_at desc, fs.source_id desc
        limit 1;
      end if;
    elsif v_step = 'record' then
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
      select cma.market_code_of(p_tenant_id, a.market) into v_value
      from cma.connection_inbox_account a
      where a.tenant_id = p_tenant_id and a.connection_id = p_connection_id
        and a.source_account_id = coalesce(v_msg.account_ref, v_thread.account_ref);
      if v_value is null then
        select cma.market_code_of(p_tenant_id, b.market) into v_value
        from cma.connection_inbox b
        where b.tenant_id = p_tenant_id and b.connection_id = p_connection_id
          and b.source_inbox_id = coalesce(v_msg.inbox_source_id, v_thread.inbox_source_id);
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
-- 7. The definitions (reads of an explicit tenant, in the caller's rights)
-- ---------------------------------------------------------------------------------------------
-- The counted emails of [p_from, p_to), one row each (both bounds required, so the read keeps to the
-- index on the tenant and the time; 0008k): the inbox, the mailbox and the category with their labels,
-- the direction, status, actor kind and the agent's owner id, the market as cma.email_market_of gives it (computed inline) with
-- its zone, business date, ISO week and hour of day there, and the flags the reports count:
--   received        an inbox message in or forwarded
--   logged_reply    an engagement in or forwarded (never added to received)
--   agent_send      out and sent, not automated
--   automated       out and sent, an engagement of an automated origin or an inbox message of a bot,
--                   an AI, the system or an integration
--   bounced_failed  out, bounced or failed
-- Left out: deleted emails, an engagement whose origin is an inbox-copy origin of its connection, and
-- an inbox message on an inbox, mailbox or channel that does not count, or of a spam conversation. An
-- inbox message without a mailbox of its own counts under its conversation's. No source id of a message
-- is returned
create or replace function cma.email_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  connection_id     uuid,
  source_system     text,
  source_kind       text,
  thread_source_id  text,
  inbox_key         text,
  inbox_name        text,
  account_key       text,
  account_name      text,
  category          text,
  direction         text,
  status            text,
  occurred_at       timestamptz,
  actor_kind        text,
  owner_ref         text,
  market            text,
  zone              text,
  business_date     date,
  week_start        date,
  local_time        time,
  local_hour        integer,
  is_received       boolean,
  is_logged_reply   boolean,
  is_agent_send     boolean,
  is_automated      boolean,
  is_bounced_failed boolean
)
language sql stable
-- the planner adds up the cost of every step of the market chain although at most one runs per row:
-- without this, that estimate starts a JIT compilation that costs more than the read
set jit = off
as $$
  with s as (
    select t.timezone as tenant_zone, string_to_array(cma.setting_of(t.id, 'email.market_order'), ',') as ord
    from cma.tenant t where t.id = p_tenant_id
  ),
  e as (
    select em.connection_id, em.source_system, em.source_kind, em.source_id, em.thread_source_id, em.inbox_source_id,
           em.account_ref, em.category, em.direction, em.status, em.occurred_at, em.actor_kind, em.owner_ref,
           ib.name as ib_name, coalesce(ac.label, ac.name) as ac_name,
           lower(coalesce(em.origin, '')) = any (cma.setting_codes(c.settings, 'email_automated_origins')) as automated_origin,
           coalesce(em.contact_source_id, th.contact_source_id) as contact, th.ticket_source_id as ticket,
           coalesce(em.account_ref, th.account_ref) as m_account, coalesce(em.inbox_source_id, th.inbox_source_id) as m_inbox
    from cma.email_message em
    join cma.integration_connection c on c.tenant_id = em.tenant_id and c.id = em.connection_id
    left join cma.email_thread th
      on em.source_kind = 'inbox_message' and th.tenant_id = em.tenant_id and th.connection_id = em.connection_id
     and th.source_id = em.thread_source_id
    left join cma.connection_inbox ib
      on ib.tenant_id = em.tenant_id and ib.connection_id = em.connection_id and ib.source_inbox_id = em.inbox_source_id
    -- a message without a mailbox of its own counts under its conversation's (one stored before 0008t has none)
    left join cma.connection_inbox_account ac
      on ac.tenant_id = em.tenant_id and ac.connection_id = em.connection_id
     and ac.source_account_id = coalesce(em.account_ref, th.account_ref)
    left join cma.connection_inbox_channel ch
      on ch.tenant_id = em.tenant_id and ch.connection_id = em.connection_id and ch.source_channel_id = em.channel_source_id
    where em.tenant_id = p_tenant_id
      and em.occurred_at >= p_from and em.occurred_at < p_to
      and em.source_deleted_at is null
      and case when em.source_kind = 'inbox_message'
               then coalesce(ib.is_counted, true) and coalesce(ac.is_counted, true) and coalesce(ch.is_counted, true)
                    and not coalesce(th.is_spam, false)
               else not (lower(coalesce(em.origin, '')) = any (cma.setting_codes(c.settings, 'email_inbox_copy_origins'))) end
  )
  select e.connection_id, e.source_system, e.source_kind, e.thread_source_id,
         case when e.inbox_source_id is not null then e.connection_id::text || ':' || e.inbox_source_id end,
         coalesce(e.ib_name, e.inbox_source_id),
         case when e.m_account is not null then e.connection_id::text || ':' || e.m_account end,
         coalesce(e.ac_name, e.m_account),
         e.category, e.direction, e.status, e.occurred_at, e.actor_kind, e.owner_ref,
         mk.code, z.zone,
         (e.occurred_at at time zone z.zone)::date,
         date_trunc('week', (e.occurred_at at time zone z.zone)::date::timestamp)::date,
         (e.occurred_at at time zone z.zone)::time,
         extract(hour from (e.occurred_at at time zone z.zone))::integer,
         e.source_kind = 'inbox_message' and e.direction in ('in', 'forwarded'),
         e.source_kind = 'crm_email' and e.direction in ('in', 'forwarded'),
         e.direction = 'out' and e.status = 'sent' and not k.automated,
         e.direction = 'out' and e.status = 'sent' and k.automated,
         e.direction = 'out' and e.status in ('bounced', 'failed')
  from e
  cross join s
  cross join lateral (
    select case when e.source_kind = 'crm_email' then e.automated_origin
                else e.actor_kind in ('bot', 'ai', 'system', 'integration') end as automated) k
  cross join lateral (
    select coalesce(e.contact,
                    case when e.source_kind = 'crm_email'
                         then (select a.to_id from cma.crm_association a
                               where a.tenant_id = p_tenant_id and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                 and a.from_id = e.source_id and a.to_type = 'contact' and a.removed_at is null
                               order by a.first_seen_at, a.to_id
                               limit 1) end) as contact) ct
  -- the market chain of cma.email_market_of, inline: each step evaluated only when the steps before it
  -- found nothing (offset 0 keeps the chain from being copied into the zone's lookup); 83 checks it
  -- gives what cma.email_market_of gives on every row of its data
  cross join lateral (
    select
      coalesce(
      case s.ord[1]
        when 'contact' then (select cma.market_code_of(p_tenant_id, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = p_tenant_id and cc.connection_id = e.connection_id and cc.source_id = ct.contact)
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = e.connection_id and fs.contact_source_id = ct.contact
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= e.occurred_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then case when e.source_kind = 'crm_email'
                                then (select cma.market_code_of(p_tenant_id, cr.market)
                                      from cma.crm_association a
                                      join cma.crm_record cr
                                        on cr.tenant_id = a.tenant_id and cr.connection_id = a.connection_id and cr.record_type = a.to_type
                                       and cr.source_id = a.to_id
                                      where a.tenant_id = p_tenant_id and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                        and a.from_id = e.source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null
                                        and cr.source_deleted_at is null and cma.market_code_of(p_tenant_id, cr.market) is not null
                                      order by (a.to_type = 'ticket') desc, cr.source_created_at desc, cr.source_id
                                      limit 1)
                                else (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                                      where cr.tenant_id = p_tenant_id and cr.connection_id = e.connection_id and cr.record_type = 'ticket'
                                        and cr.source_id = e.ticket and cr.source_deleted_at is null) end
        when 'inbox' then coalesce((select cma.market_code_of(p_tenant_id, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = p_tenant_id and a.connection_id = e.connection_id and a.source_account_id = e.m_account),
                                   (select cma.market_code_of(p_tenant_id, b.market) from cma.connection_inbox b
                                    where b.tenant_id = p_tenant_id and b.connection_id = e.connection_id and b.source_inbox_id = e.m_inbox))
      end,
      case s.ord[2]
        when 'contact' then (select cma.market_code_of(p_tenant_id, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = p_tenant_id and cc.connection_id = e.connection_id and cc.source_id = ct.contact)
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = e.connection_id and fs.contact_source_id = ct.contact
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= e.occurred_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then case when e.source_kind = 'crm_email'
                                then (select cma.market_code_of(p_tenant_id, cr.market)
                                      from cma.crm_association a
                                      join cma.crm_record cr
                                        on cr.tenant_id = a.tenant_id and cr.connection_id = a.connection_id and cr.record_type = a.to_type
                                       and cr.source_id = a.to_id
                                      where a.tenant_id = p_tenant_id and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                        and a.from_id = e.source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null
                                        and cr.source_deleted_at is null and cma.market_code_of(p_tenant_id, cr.market) is not null
                                      order by (a.to_type = 'ticket') desc, cr.source_created_at desc, cr.source_id
                                      limit 1)
                                else (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                                      where cr.tenant_id = p_tenant_id and cr.connection_id = e.connection_id and cr.record_type = 'ticket'
                                        and cr.source_id = e.ticket and cr.source_deleted_at is null) end
        when 'inbox' then coalesce((select cma.market_code_of(p_tenant_id, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = p_tenant_id and a.connection_id = e.connection_id and a.source_account_id = e.m_account),
                                   (select cma.market_code_of(p_tenant_id, b.market) from cma.connection_inbox b
                                    where b.tenant_id = p_tenant_id and b.connection_id = e.connection_id and b.source_inbox_id = e.m_inbox))
      end,
      case s.ord[3]
        when 'contact' then (select cma.market_code_of(p_tenant_id, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = p_tenant_id and cc.connection_id = e.connection_id and cc.source_id = ct.contact)
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = e.connection_id and fs.contact_source_id = ct.contact
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= e.occurred_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then case when e.source_kind = 'crm_email'
                                then (select cma.market_code_of(p_tenant_id, cr.market)
                                      from cma.crm_association a
                                      join cma.crm_record cr
                                        on cr.tenant_id = a.tenant_id and cr.connection_id = a.connection_id and cr.record_type = a.to_type
                                       and cr.source_id = a.to_id
                                      where a.tenant_id = p_tenant_id and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                        and a.from_id = e.source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null
                                        and cr.source_deleted_at is null and cma.market_code_of(p_tenant_id, cr.market) is not null
                                      order by (a.to_type = 'ticket') desc, cr.source_created_at desc, cr.source_id
                                      limit 1)
                                else (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                                      where cr.tenant_id = p_tenant_id and cr.connection_id = e.connection_id and cr.record_type = 'ticket'
                                        and cr.source_id = e.ticket and cr.source_deleted_at is null) end
        when 'inbox' then coalesce((select cma.market_code_of(p_tenant_id, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = p_tenant_id and a.connection_id = e.connection_id and a.source_account_id = e.m_account),
                                   (select cma.market_code_of(p_tenant_id, b.market) from cma.connection_inbox b
                                    where b.tenant_id = p_tenant_id and b.connection_id = e.connection_id and b.source_inbox_id = e.m_inbox))
      end,
      case s.ord[4]
        when 'contact' then (select cma.market_code_of(p_tenant_id, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = p_tenant_id and cc.connection_id = e.connection_id and cc.source_id = ct.contact)
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = e.connection_id and fs.contact_source_id = ct.contact
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= e.occurred_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then case when e.source_kind = 'crm_email'
                                then (select cma.market_code_of(p_tenant_id, cr.market)
                                      from cma.crm_association a
                                      join cma.crm_record cr
                                        on cr.tenant_id = a.tenant_id and cr.connection_id = a.connection_id and cr.record_type = a.to_type
                                       and cr.source_id = a.to_id
                                      where a.tenant_id = p_tenant_id and a.connection_id = e.connection_id and a.from_type = 'crm_email'
                                        and a.from_id = e.source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null
                                        and cr.source_deleted_at is null and cma.market_code_of(p_tenant_id, cr.market) is not null
                                      order by (a.to_type = 'ticket') desc, cr.source_created_at desc, cr.source_id
                                      limit 1)
                                else (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                                      where cr.tenant_id = p_tenant_id and cr.connection_id = e.connection_id and cr.record_type = 'ticket'
                                        and cr.source_id = e.ticket and cr.source_deleted_at is null) end
        when 'inbox' then coalesce((select cma.market_code_of(p_tenant_id, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = p_tenant_id and a.connection_id = e.connection_id and a.source_account_id = e.m_account),
                                   (select cma.market_code_of(p_tenant_id, b.market) from cma.connection_inbox b
                                    where b.tenant_id = p_tenant_id and b.connection_id = e.connection_id and b.source_inbox_id = e.m_inbox))
      end,
      'unknown') as code
    offset 0) mk
  cross join lateral (select coalesce((select m.time_zone from cma.market m where m.tenant_id = p_tenant_id and m.code = mk.code),
                                      s.tenant_zone) as zone) z
$$;

-- The counted conversations of a tenant: counted inbox, mailbox and channel (one the catalog has not
-- brought yet counts), not spam; with the labels and the market (as cma.email_market_of gives it) and its zone
create or replace function cma.email_threads_counted_of(p_tenant_id uuid, p_thread_ids uuid[])
returns table (
  id                uuid,
  connection_id     uuid,
  source_system     text,
  source_id         text,
  inbox_key         text,
  inbox_name        text,
  account_key       text,
  account_name      text,
  category          text,
  status            text,
  market            text,
  zone              text
)
language sql stable
-- the planner adds up the cost of every step of the market chain although at most one runs per row:
-- without this, that estimate starts a JIT compilation that costs more than the read
set jit = off
as $$
  with s as (
    select t.timezone as tenant_zone, string_to_array(cma.setting_of(t.id, 'email.market_order'), ',') as ord
    from cma.tenant t where t.id = p_tenant_id
  )
  select th.id, th.connection_id, th.source_system, th.source_id,
         case when th.inbox_source_id is not null then th.connection_id::text || ':' || th.inbox_source_id end,
         coalesce(ib.name, th.inbox_source_id),
         case when th.account_ref is not null then th.connection_id::text || ':' || th.account_ref end,
         coalesce(ac.label, ac.name, th.account_ref),
         th.category, th.status, mk.code,
         coalesce((select m.time_zone from cma.market m where m.tenant_id = p_tenant_id and m.code = mk.code), s.tenant_zone)
  from cma.email_thread th
  cross join s
  left join cma.connection_inbox ib
    on ib.tenant_id = th.tenant_id and ib.connection_id = th.connection_id and ib.source_inbox_id = th.inbox_source_id
  left join cma.connection_inbox_account ac
    on ac.tenant_id = th.tenant_id and ac.connection_id = th.connection_id and ac.source_account_id = th.account_ref
  left join cma.connection_inbox_channel ch
    on ch.tenant_id = th.tenant_id and ch.connection_id = th.connection_id and ch.source_channel_id = th.channel_source_id
  -- the market chain of cma.email_market_of for a conversation, inline (as in cma.email_of)
  cross join lateral (
    select
      coalesce(
      case s.ord[1]
        when 'contact' then (select cma.market_code_of(p_tenant_id, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = p_tenant_id and cc.connection_id = th.connection_id and cc.source_id = th.contact_source_id)
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = th.connection_id and fs.contact_source_id = th.contact_source_id
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= th.source_created_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                            where cr.tenant_id = p_tenant_id and cr.connection_id = th.connection_id and cr.record_type = 'ticket'
                              and cr.source_id = th.ticket_source_id and cr.source_deleted_at is null)
        when 'inbox' then coalesce((select cma.market_code_of(p_tenant_id, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = p_tenant_id and a.connection_id = th.connection_id and a.source_account_id = th.account_ref),
                                   (select cma.market_code_of(p_tenant_id, b.market) from cma.connection_inbox b
                                    where b.tenant_id = p_tenant_id and b.connection_id = th.connection_id and b.source_inbox_id = th.inbox_source_id))
      end,
      case s.ord[2]
        when 'contact' then (select cma.market_code_of(p_tenant_id, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = p_tenant_id and cc.connection_id = th.connection_id and cc.source_id = th.contact_source_id)
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = th.connection_id and fs.contact_source_id = th.contact_source_id
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= th.source_created_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                            where cr.tenant_id = p_tenant_id and cr.connection_id = th.connection_id and cr.record_type = 'ticket'
                              and cr.source_id = th.ticket_source_id and cr.source_deleted_at is null)
        when 'inbox' then coalesce((select cma.market_code_of(p_tenant_id, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = p_tenant_id and a.connection_id = th.connection_id and a.source_account_id = th.account_ref),
                                   (select cma.market_code_of(p_tenant_id, b.market) from cma.connection_inbox b
                                    where b.tenant_id = p_tenant_id and b.connection_id = th.connection_id and b.source_inbox_id = th.inbox_source_id))
      end,
      case s.ord[3]
        when 'contact' then (select cma.market_code_of(p_tenant_id, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = p_tenant_id and cc.connection_id = th.connection_id and cc.source_id = th.contact_source_id)
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = th.connection_id and fs.contact_source_id = th.contact_source_id
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= th.source_created_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                            where cr.tenant_id = p_tenant_id and cr.connection_id = th.connection_id and cr.record_type = 'ticket'
                              and cr.source_id = th.ticket_source_id and cr.source_deleted_at is null)
        when 'inbox' then coalesce((select cma.market_code_of(p_tenant_id, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = p_tenant_id and a.connection_id = th.connection_id and a.source_account_id = th.account_ref),
                                   (select cma.market_code_of(p_tenant_id, b.market) from cma.connection_inbox b
                                    where b.tenant_id = p_tenant_id and b.connection_id = th.connection_id and b.source_inbox_id = th.inbox_source_id))
      end,
      case s.ord[4]
        when 'contact' then (select cma.market_code_of(p_tenant_id, cc.country) from cma.crm_contact cc
                             where cc.tenant_id = p_tenant_id and cc.connection_id = th.connection_id and cc.source_id = th.contact_source_id)
        when 'form' then (select cma.market_code_of(p_tenant_id, f.market)
                          from cma.form_submission fs
                          join cma.connection_form f
                            on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
                          where fs.tenant_id = p_tenant_id and fs.connection_id = th.connection_id and fs.contact_source_id = th.contact_source_id
                            and fs.contact_resolution = 'resolved' and fs.submitted_at <= th.source_created_at
                            and f.is_counted and cma.market_code_of(p_tenant_id, f.market) is not null
                          order by fs.submitted_at desc, fs.source_id desc
                          limit 1)
        when 'record' then (select cma.market_code_of(p_tenant_id, cr.market) from cma.crm_record cr
                            where cr.tenant_id = p_tenant_id and cr.connection_id = th.connection_id and cr.record_type = 'ticket'
                              and cr.source_id = th.ticket_source_id and cr.source_deleted_at is null)
        when 'inbox' then coalesce((select cma.market_code_of(p_tenant_id, a.market) from cma.connection_inbox_account a
                                    where a.tenant_id = p_tenant_id and a.connection_id = th.connection_id and a.source_account_id = th.account_ref),
                                   (select cma.market_code_of(p_tenant_id, b.market) from cma.connection_inbox b
                                    where b.tenant_id = p_tenant_id and b.connection_id = th.connection_id and b.source_inbox_id = th.inbox_source_id))
      end,
      'unknown') as code
    offset 0) mk
  where th.tenant_id = p_tenant_id and th.id = any (p_thread_ids)
    and not th.is_spam
    and coalesce(ib.is_counted, true) and coalesce(ac.is_counted, true) and coalesce(ch.is_counted, true)
$$;

-- The openings of counted conversations in [p_from, p_to): a creation, or a reopen whose latest status
-- event before it is a close. Per opening: the close it follows (span_from; none for a creation), its
-- own close (the first close at or after it), the first incoming message after span_from up to that
-- close, the first agent message out (not failed) after that incoming message up to that close with the
-- agent's owner id, elapsed and business seconds (business: in the thread's market; null for an
-- unknown market), within email.reply_target_minutes, and the time to close
create or replace function cma.email_openings_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  connection_id           uuid,
  source_system           text,
  thread_source_id        text,
  inbox_key               text,
  inbox_name              text,
  account_key             text,
  account_name            text,
  category                text,
  opening_kind            text,
  opened_at               timestamptz,
  market                  text,
  zone                    text,
  business_date           date,
  week_start              date,
  local_hour              integer,
  first_in_at             timestamptz,
  first_reply_at          timestamptz,
  reply_owner_ref         text,
  reply_seconds           integer,
  reply_business_seconds  integer,
  reply_within_target     boolean,
  closed_at               timestamptz,
  close_actor_kind        text,
  close_owner_ref         text,
  close_seconds           integer,
  close_business_seconds  integer
)
language sql stable
as $$
  with s as (
    select greatest(1, cma.setting_of(t.id, 'email.reply_target_minutes')::integer) * 60 as target
    from cma.tenant t where t.id = p_tenant_id
  ),
  o as (
    select th.id as thread_id, 'created'::text as kind, th.source_created_at as open_at, '-infinity'::timestamptz as span_from
    from cma.email_thread th
    where th.tenant_id = p_tenant_id and th.source_created_at >= p_from and th.source_created_at < p_to
    union all
    select th.id, 'reopened', ev.occurred_at, pc.at
    from cma.email_thread_event ev
    join cma.email_thread th
      on th.tenant_id = ev.tenant_id and th.connection_id = ev.connection_id and th.source_id = ev.thread_source_id
    cross join lateral (
      select max(c.occurred_at) filter (where c.kind = 'closed') as at,
             max(c.occurred_at) filter (where c.kind = 'reopened') as reopened_at
      from cma.email_thread_event c
      where c.tenant_id = ev.tenant_id and c.connection_id = ev.connection_id and c.thread_source_id = ev.thread_source_id
        and c.kind in ('closed', 'reopened') and c.occurred_at < ev.occurred_at) pc
    where ev.tenant_id = p_tenant_id and ev.kind = 'reopened'
      and ev.occurred_at >= p_from and ev.occurred_at < p_to
      and pc.at is not null and pc.at >= coalesce(pc.reopened_at, '-infinity'::timestamptz)
  ),
  t as (
    select x.* from cma.email_threads_counted_of(p_tenant_id, (select coalesce(array_agg(distinct o.thread_id), '{}') from o)) x
  )
  select t.connection_id, t.source_system, t.source_id, t.inbox_key, t.inbox_name, t.account_key, t.account_name, t.category,
         o.kind, o.open_at, t.market, t.zone,
         (o.open_at at time zone t.zone)::date,
         date_trunc('week', (o.open_at at time zone t.zone)::date::timestamp)::date,
         extract(hour from (o.open_at at time zone t.zone))::integer,
         fi.at, fr.at, fr.owner_ref,
         extract(epoch from fr.at - fi.at)::integer,
         rb.seconds,
         rb.seconds <= s.target,
         cl.at, cl.actor_kind, cl.owner_ref,
         extract(epoch from cl.at - o.open_at)::integer,
         case when cl.at is not null then cma.business_seconds_of(p_tenant_id, t.market, o.open_at, cl.at) end
  from o
  join t on t.id = o.thread_id
  cross join s
  left join lateral (
    select c.occurred_at as at, c.actor_kind, c.owner_ref
    from cma.email_thread_event c
    where c.tenant_id = p_tenant_id and c.connection_id = t.connection_id and c.thread_source_id = t.source_id
      and c.kind = 'closed' and c.occurred_at >= o.open_at
    order by c.occurred_at, c.source_id
    limit 1) cl on true
  left join lateral (
    select min(m.occurred_at) as at
    from cma.email_message m
    where m.tenant_id = p_tenant_id and m.connection_id = t.connection_id and m.thread_source_id = t.source_id
      and m.source_kind = 'inbox_message' and m.direction in ('in', 'forwarded') and m.source_deleted_at is null
      and m.occurred_at > o.span_from and (cl.at is null or m.occurred_at <= cl.at)) fi on true
  left join lateral (
    select m.occurred_at as at, m.owner_ref
    from cma.email_message m
    where fi.at is not null
      and m.tenant_id = p_tenant_id and m.connection_id = t.connection_id and m.thread_source_id = t.source_id
      and m.source_kind = 'inbox_message' and m.direction = 'out' and m.actor_kind = 'agent' and m.status <> 'failed'
      and m.source_deleted_at is null
      and m.occurred_at > fi.at and (cl.at is null or m.occurred_at <= cl.at)
    order by m.occurred_at, m.source_id
    limit 1) fr on true
  cross join lateral (
    select case when fr.at is not null then cma.business_seconds_of(p_tenant_id, t.market, fi.at, fr.at) end as seconds) rb
$$;

-- The closes of counted conversations in [p_from, p_to): one row per close event, with the closing
-- actor's kind and, for an agent, owner id; the date and hour in the thread's market zone
create or replace function cma.email_closes_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  connection_id     uuid,
  source_system     text,
  thread_source_id  text,
  inbox_key         text,
  inbox_name        text,
  account_key       text,
  account_name      text,
  category          text,
  closed_at         timestamptz,
  actor_kind        text,
  owner_ref         text,
  market            text,
  zone              text,
  business_date     date,
  week_start        date,
  local_hour        integer
)
language sql stable
as $$
  with c as (
    select ev.occurred_at, ev.actor_kind, ev.owner_ref, th.id as thread_id
    from cma.email_thread_event ev
    join cma.email_thread th
      on th.tenant_id = ev.tenant_id and th.connection_id = ev.connection_id and th.source_id = ev.thread_source_id
    where ev.tenant_id = p_tenant_id and ev.kind = 'closed' and ev.occurred_at >= p_from and ev.occurred_at < p_to
  ),
  t as (
    select x.* from cma.email_threads_counted_of(p_tenant_id, (select coalesce(array_agg(distinct c.thread_id), '{}') from c)) x
  )
  select t.connection_id, t.source_system, t.source_id, t.inbox_key, t.inbox_name, t.account_key, t.account_name, t.category,
         c.occurred_at, c.actor_kind, c.owner_ref, t.market, t.zone,
         (c.occurred_at at time zone t.zone)::date,
         date_trunc('week', (c.occurred_at at time zone t.zone)::date::timestamp)::date,
         extract(hour from (c.occurred_at at time zone t.zone))::integer
  from c
  join t on t.id = c.thread_id
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. The figures
-- ---------------------------------------------------------------------------------------------
-- The emails, openings and closes of the business dates [p_from, p_to] (each in its own zone), narrowed
-- by the filters before anything is counted (p_market a market code or 'unknown'; p_inbox and p_account
-- connection id ':' source id; an engagement has neither, so either filter leaves it out), per group of
-- each dimension asked for (day, week, market, inbox, account, category; 'none' for an email without
-- an inbox, a mailbox or a category; day_inbox, week_inbox, day_account and week_account: the date and
-- the inbox or mailbox, as 'date|key') and in total (dimension 'total', group_key null). With p_until
-- (the previous span of a period that reaches today) the last date counts only up to p_until's time of
-- day in each row's own zone (as 0008j)
create or replace function cma.email_figures_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_inbox text, p_account text,
                                                p_dimensions text[], p_until timestamptz default null)
returns table (
  dimension                      text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  b as (
    -- a day on each side, so a market in another zone than the tenant's keeps its whole dates
    select (p_from - 1)::timestamp at time zone s.zone as from_at, (p_to + 2)::timestamp at time zone s.zone as to_at from s
  ),
  e as materialized (
    select x.* from b cross join lateral cma.email_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to
      and (p_until is null or x.business_date < p_to or x.local_time <= (p_until at time zone x.zone)::time)
      and (p_market is null or x.market = p_market)
      and (p_inbox is null or x.inbox_key = p_inbox)
      and (p_account is null or x.account_key = p_account)
  ),
  o as materialized (
    select x.* from b cross join lateral cma.email_openings_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to
      and (p_until is null or x.business_date < p_to or (x.opened_at at time zone x.zone)::time <= (p_until at time zone x.zone)::time)
      and (p_market is null or x.market = p_market)
      and (p_inbox is null or x.inbox_key = p_inbox)
      and (p_account is null or x.account_key = p_account)
  ),
  c as materialized (
    select x.* from b cross join lateral cma.email_closes_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to
      and (p_until is null or x.business_date < p_to or (x.closed_at at time zone x.zone)::time <= (p_until at time zone x.zone)::time)
      and (p_market is null or x.market = p_market)
      and (p_inbox is null or x.inbox_key = p_inbox)
      and (p_account is null or x.account_key = p_account)
  ),
  facts as (
    select 'email'::text as what, e.business_date, e.week_start, e.market, e.inbox_key, e.inbox_name, e.account_key, e.account_name,
           e.category, e.is_received, e.is_logged_reply, e.is_agent_send, e.is_automated, e.is_bounced_failed,
           null::timestamptz as first_reply_at, null::integer as reply_seconds, null::integer as reply_business_seconds,
           null::boolean as reply_within_target, null::timestamptz as closed_at, null::integer as close_seconds,
           null::integer as close_business_seconds
    from e
    union all
    select 'opening', o.business_date, o.week_start, o.market, o.inbox_key, o.inbox_name, o.account_key, o.account_name, o.category,
           false, false, false, false, false, o.first_reply_at, o.reply_seconds, o.reply_business_seconds, o.reply_within_target,
           o.closed_at, o.close_seconds, o.close_business_seconds
    from o
    union all
    select 'close', c.business_date, c.week_start, c.market, c.inbox_key, c.inbox_name, c.account_key, c.account_name, c.category,
           false, false, false, false, false, null, null, null, null, null, null, null
    from c
  ),
  g as (
    select d.dim, d.k, d.l, f.*
    from facts f
    cross join lateral (
      values ('total', null::text, null::text),
             ('day', f.business_date::text, f.business_date::text),
             ('week', f.week_start::text, f.week_start::text),
             ('market', f.market, f.market),
             ('inbox', coalesce(f.inbox_key, 'none'), f.inbox_name),
             ('account', coalesce(f.account_key, 'none'), f.account_name),
             ('category', coalesce(f.category, 'none'), f.category),
             ('day_inbox', f.business_date::text || '|' || coalesce(f.inbox_key, 'none'), f.inbox_name),
             ('week_inbox', f.week_start::text || '|' || coalesce(f.inbox_key, 'none'), f.inbox_name),
             ('day_account', f.business_date::text || '|' || coalesce(f.account_key, 'none'), f.account_name),
             ('week_account', f.week_start::text || '|' || coalesce(f.account_key, 'none'), f.account_name)) as d(dim, k, l)
    where d.dim = 'total' or d.dim = any (p_dimensions)
  ),
  agg as (
    select g.dim, g.k, max(g.l) as l,
           (count(*) filter (where g.what = 'email' and g.is_received))::integer as received,
           (count(*) filter (where g.what = 'email' and g.is_logged_reply))::integer as logged_replies,
           (count(*) filter (where g.what = 'email' and g.is_agent_send))::integer as sent_agent,
           (count(*) filter (where g.what = 'email' and g.is_automated))::integer as sent_automated,
           (count(*) filter (where g.what = 'email' and g.is_bounced_failed))::integer as bounced_failed,
           (count(*) filter (where g.what = 'opening'))::integer as threads_opened,
           (count(*) filter (where g.what = 'close'))::integer as threads_closed,
           (count(*) filter (where g.what = 'opening' and g.first_reply_at is not null))::integer as replied,
           percentile_cont(0.5) within group (order by g.reply_seconds) filter (where g.what = 'opening' and g.first_reply_at is not null) as rm,
           percentile_cont(0.5) within group (order by g.reply_business_seconds)
             filter (where g.what = 'opening' and g.reply_business_seconds is not null) as rbm,
           (count(*) filter (where g.what = 'opening' and g.reply_within_target))::integer as within_target,
           (count(*) filter (where g.what = 'opening' and g.reply_business_seconds is not null))::integer as target_known,
           (count(*) filter (where g.what = 'opening' and g.first_reply_at is not null and g.reply_business_seconds is null))::integer as no_hours,
           percentile_cont(0.5) within group (order by g.close_seconds) filter (where g.what = 'opening' and g.closed_at is not null) as cm,
           percentile_cont(0.5) within group (order by g.close_business_seconds)
             filter (where g.what = 'opening' and g.close_business_seconds is not null) as cbm
    from g
    group by g.dim, g.k
  )
  select a.dim, a.k, a.l, a.received, a.logged_replies, a.sent_agent, a.sent_automated, a.bounced_failed, a.threads_opened,
         a.threads_closed, a.replied, round(a.rm::numeric, 1), round(a.rbm::numeric, 1), a.within_target, a.target_known, a.no_hours,
         round(a.cm::numeric, 1), round(a.cbm::numeric, 1)
  from agg a
  union all
  -- the total is there even for a period without anything
  select 'total', null, null, 0, 0, 0, 0, 0, 0, 0, 0, null, null, 0, 0, 0, null, null
  where not exists (select 1 from agg where agg.dim = 'total')
  order by 1, 2
$$;

-- The overview: the groups of p_group and the total of the period ('current'), then the total of the
-- previous period ('previous'), like for like (cma.forms_previous_of, as 0008j and 0008p). p_now is
-- now() for the application; a verifier gives a fixed instant
create or replace function cma.email_overview_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_market text, p_inbox text,
                                                 p_account text, p_now timestamptz default now())
returns table (
  period                         text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language sql stable
as $$
  select x.period, x.group_key, x.group_label, x.received, x.logged_replies, x.sent_agent, x.sent_automated, x.bounced_failed,
         x.threads_opened, x.threads_closed, x.replied, x.reply_median_seconds, x.reply_median_business_seconds, x.within_target,
         x.target_known, x.no_hours, x.close_median_seconds, x.close_median_business_seconds
  from (
    select 'current'::text as period, 1 as part, f.dimension = 'total' as is_total, f.*
    from cma.email_figures_of(p_tenant_id, p_from, p_to, p_market, p_inbox, p_account, array[p_group]) f
    union all
    select 'previous', 2, true, f.*
    from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now) v
    cross join lateral cma.email_figures_of(p_tenant_id, v.prev_from, v.prev_to, p_market, p_inbox, p_account, '{}'::text[], v.until) f
  ) x
  order by x.part, x.is_total, case when p_group in ('day', 'week') then x.group_key end, x.group_label, x.group_key
$$;

-- The period's figures per inbox, mailbox, category and market at once (one pass over the period),
-- for the report's tables; no previous period
create or replace function cma.email_by_dimension_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_inbox text,
                                                     p_account text)
returns table (
  dimension                      text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language sql stable
as $$
  select f.* from cma.email_figures_of(p_tenant_id, p_from, p_to, p_market, p_inbox, p_account,
                                       array['inbox', 'account', 'category', 'market']) f
  where f.dimension <> 'total'
  order by array_position(array['inbox', 'account', 'category', 'market'], f.dimension), f.group_key = 'none', f.group_label, f.group_key
$$;

-- The report page in one read: the period's figures per p_group (day or week), market, inbox, mailbox
-- and category, the received messages per date and inbox and per date and mailbox (the same pass over
-- the period), and the total ('current'); then the previous period's total ('previous'), like for like
create or replace function cma.email_report_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_market text, p_inbox text,
                                               p_account text, p_now timestamptz default now())
returns table (
  period                         text,
  dimension                      text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language sql stable
as $$
  select x.period, x.dimension, x.group_key, x.group_label, x.received, x.logged_replies, x.sent_agent, x.sent_automated,
         x.bounced_failed, x.threads_opened, x.threads_closed, x.replied, x.reply_median_seconds, x.reply_median_business_seconds,
         x.within_target, x.target_known, x.no_hours, x.close_median_seconds, x.close_median_business_seconds
  from (
    select 'current'::text as period, 1 as part, f.*
    from cma.email_figures_of(p_tenant_id, p_from, p_to, p_market, p_inbox, p_account,
                              array[p_group, 'market', 'inbox', 'account', 'category', p_group || '_inbox', p_group || '_account']) f
    union all
    select 'previous', 2, f.*
    from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now) v
    cross join lateral cma.email_figures_of(p_tenant_id, v.prev_from, v.prev_to, p_market, p_inbox, p_account, '{}'::text[], v.until) f
  ) x
  order by x.part, x.dimension, x.group_key
$$;

-- Received inbox messages per day or ISO week (group_key) and inbox or mailbox (series_key, 'none' for
-- a message without one), for the columns of the report
create or replace function cma.email_received_series_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_split text,
                                                        p_market text, p_inbox text, p_account text)
returns table (group_key text, series_key text, series_label text, received integer)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id)
  select case p_group when 'week' then x.week_start::text else x.business_date::text end,
         coalesce(case p_split when 'account' then x.account_key else x.inbox_key end, 'none'),
         max(case p_split when 'account' then x.account_name else x.inbox_name end),
         count(*)::integer
  from s
  cross join lateral cma.email_of(p_tenant_id, (p_from - 1)::timestamp at time zone s.zone, (p_to + 2)::timestamp at time zone s.zone) x
  where x.business_date between p_from and p_to and x.is_received
    and (p_market is null or x.market = p_market)
    and (p_inbox is null or x.inbox_key = p_inbox)
    and (p_account is null or x.account_key = p_account)
  group by 1, 2
  order by 1, 3, 2
$$;

-- Per person: the agent sends (the sender's owner id), the first replies (the replying agent) and the
-- closes by an agent (the closing agent), each matched to the person holding '<adapter>_owner' with
-- that id (0008e); an action of an owner id without a person, or a send without an owner, is not
-- linked (row_kind 'not_linked', with the count of such owner ids, never which); then the total. Per
-- person sorted by name, never ranked; sends per hour of day in each email's own zone (24 counts)
create or replace function cma.email_per_person_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_inbox text, p_account text)
returns table (
  row_kind                       text,
  user_id                        uuid,
  display_name                   text,
  unlinked_owners                integer,
  sent                           integer,
  replies                        integer,
  threads_closed                 integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  sent_by_hour                   integer[]
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  b as (select (p_from - 1)::timestamp at time zone s.zone as from_at, (p_to + 2)::timestamp at time zone s.zone as to_at from s),
  acts as (
    select 'send'::text as what, x.source_system, x.owner_ref, x.local_hour, null::integer as rs, null::integer as rbs, null::boolean as wt
    from b cross join lateral cma.email_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to and x.is_agent_send
      and (p_market is null or x.market = p_market) and (p_inbox is null or x.inbox_key = p_inbox)
      and (p_account is null or x.account_key = p_account)
    union all
    select 'reply', x.source_system, x.reply_owner_ref, null, x.reply_seconds, x.reply_business_seconds, x.reply_within_target
    from b cross join lateral cma.email_openings_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to and x.first_reply_at is not null
      and (p_market is null or x.market = p_market) and (p_inbox is null or x.inbox_key = p_inbox)
      and (p_account is null or x.account_key = p_account)
    union all
    select 'close', x.source_system, x.owner_ref, null, null, null, null
    from b cross join lateral cma.email_closes_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to and x.actor_kind = 'agent'
      and (p_market is null or x.market = p_market) and (p_inbox is null or x.inbox_key = p_inbox)
      and (p_account is null or x.account_key = p_account)
  ),
  p as (
    select case when u.id is null then 'not_linked' else 'person' end as row_kind, u.id as user_id, u.display_name, a.*
    from acts a
    left join cma.app_user_external_id xi
      on xi.tenant_id = p_tenant_id and xi.system = a.source_system || '_owner' and xi.external_id = a.owner_ref
    left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = xi.user_id
  )
  select coalesce(p.row_kind, 'total'), p.user_id, p.display_name,
         case when p.row_kind = 'not_linked' then (count(distinct p.owner_ref))::integer end,
         (count(*) filter (where p.what = 'send'))::integer,
         (count(*) filter (where p.what = 'reply'))::integer,
         (count(*) filter (where p.what = 'close'))::integer,
         round((percentile_cont(0.5) within group (order by p.rs) filter (where p.what = 'reply'))::numeric, 1),
         round((percentile_cont(0.5) within group (order by p.rbs) filter (where p.what = 'reply' and p.rbs is not null))::numeric, 1),
         (count(*) filter (where p.what = 'reply' and p.wt))::integer,
         (count(*) filter (where p.what = 'reply' and p.rbs is not null))::integer,
         array(select (select count(*) from unnest(array_agg(p.local_hour) filter (where p.what = 'send')) x where x = h)::integer
               from generate_series(0, 23) h)
  from p
  group by grouping sets ((p.row_kind, p.user_id, p.display_name), ())
  order by grouping(p.row_kind), p.row_kind = 'not_linked', p.display_name, p.user_id
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Waiting now and not responding (now; no period)
-- ---------------------------------------------------------------------------------------------
-- The conversations waiting now: open, counted, not spam, whose latest incoming message is later than
-- their latest agent message out (not failed): waiting since the first incoming message after that
-- agent message, else the first ever, in business seconds of the thread's market (null for an unknown
-- market) and elapsed, longest waiting first. Ids, ages and the market; no message, no contact
create or replace function cma.email_waiting_of(p_tenant_id uuid, p_now timestamptz default now())
returns table (
  connection_id            uuid,
  thread_source_id         text,
  inbox_key                text,
  inbox_name               text,
  account_key              text,
  account_name             text,
  market                   text,
  ticket_source_id         text,
  waiting_since            timestamptz,
  waited_seconds           integer,
  waited_business_seconds  integer
)
language sql stable
as $$
  with o as (
    select th.id, th.connection_id, th.source_id, th.ticket_source_id
    from cma.email_thread th
    where th.tenant_id = p_tenant_id and th.status = 'open' and not th.is_spam
  ),
  w as (
    select o.*, lo.at as last_out, li.at as last_in
    from o
    left join lateral (
      select max(m.occurred_at) as at from cma.email_message m
      where m.tenant_id = p_tenant_id and m.connection_id = o.connection_id and m.thread_source_id = o.source_id
        and m.source_kind = 'inbox_message' and m.direction = 'out' and m.actor_kind = 'agent' and m.status <> 'failed'
        and m.source_deleted_at is null) lo on true
    left join lateral (
      select max(m.occurred_at) as at from cma.email_message m
      where m.tenant_id = p_tenant_id and m.connection_id = o.connection_id and m.thread_source_id = o.source_id
        and m.source_kind = 'inbox_message' and m.direction in ('in', 'forwarded') and m.source_deleted_at is null) li on true
    where li.at is not null and (lo.at is null or li.at > lo.at)
  ),
  t as (
    select x.* from cma.email_threads_counted_of(p_tenant_id, (select coalesce(array_agg(w.id), '{}') from w)) x
  )
  select t.connection_id, t.source_id, t.inbox_key, t.inbox_name, t.account_key, t.account_name, t.market, w.ticket_source_id,
         fi.at, greatest(0, extract(epoch from p_now - fi.at))::integer, cma.business_seconds_of(p_tenant_id, t.market, fi.at, p_now)
  from w
  join t on t.id = w.id
  cross join lateral (
    select min(m.occurred_at) as at from cma.email_message m
    where m.tenant_id = p_tenant_id and m.connection_id = w.connection_id and m.thread_source_id = w.source_id
      and m.source_kind = 'inbox_message' and m.direction in ('in', 'forwarded') and m.source_deleted_at is null
      and m.occurred_at > coalesce(w.last_out, '-infinity'::timestamptz)) fi
  order by fi.at, t.source_id
$$;

-- The open lead deals not responding: 0007d's open lead deals (counted lead pipelines, from
-- intake.start_date, not closed, not deleted) whose contacts' latest agent email out (an engagement of
-- an agent send, or an inbox message out by an agent, as cma.email_of counts them) is at least
-- email.no_response_days old, without an incoming engagement or inbox message from those contacts, or a
-- connected call (cma.crm_call_connected_of) on the deal or those contacts, since it. Ids, the market,
-- the email's age; oldest first
create or replace function cma.email_not_responding_of(p_tenant_id uuid, p_now timestamptz default now())
returns table (
  connection_id     uuid,
  deal_source_id    text,
  pipeline_label    text,
  market            text,
  owner_ref         text,
  source_system     text,
  last_email_at     timestamptz,
  days_since        integer
)
language sql stable
as $$
  with s as (
    select cma.setting_of(t.id, 'email.no_response_days')::integer as days from cma.tenant t where t.id = p_tenant_id
  ),
  d as (
    select l.* from cma.lead_deals_of(p_tenant_id, null, null) l where not l.is_closed and cardinality(l.contacts) > 0
  ),
  last_out as (
    select d.deal_id, max(m.occurred_at) as at
    from d
    join cma.email_message m
      on m.tenant_id = p_tenant_id and m.connection_id = d.connection_id and m.contact_source_id = any (d.contacts)
    join cma.integration_connection c on c.tenant_id = m.tenant_id and c.id = m.connection_id
    left join cma.email_thread th
      on m.source_kind = 'inbox_message' and th.tenant_id = m.tenant_id and th.connection_id = m.connection_id
     and th.source_id = m.thread_source_id
    where m.direction = 'out' and m.status = 'sent' and m.source_deleted_at is null
      and case when m.source_kind = 'crm_email'
               then not (lower(coalesce(m.origin, '')) = any (cma.setting_codes(c.settings, 'email_inbox_copy_origins')))
                    and not (lower(coalesce(m.origin, '')) = any (cma.setting_codes(c.settings, 'email_automated_origins')))
               else m.actor_kind = 'agent' and not coalesce(th.is_spam, false) end
    group by d.deal_id
  )
  select d.connection_id, d.source_id, d.pipeline_label, d.market, d.owner_ref, d.source_system, lo.at,
         floor(extract(epoch from p_now - lo.at) / 86400)::integer
  from d
  join last_out lo on lo.deal_id = d.deal_id
  cross join s
  where lo.at <= p_now - make_interval(days => s.days)
    and not exists (
      select 1 from cma.email_message m
      where m.tenant_id = p_tenant_id and m.connection_id = d.connection_id and m.contact_source_id = any (d.contacts)
        and m.direction in ('in', 'forwarded') and m.source_deleted_at is null and m.occurred_at > lo.at)
    and not exists (
      select 1
      from cma.crm_association a
      join cma.crm_call cc on cc.tenant_id = a.tenant_id and cc.connection_id = a.connection_id and cc.source_id = a.from_id
      cross join lateral cma.crm_call_connected_of(p_tenant_id, cc.id) k
      where a.tenant_id = p_tenant_id and a.connection_id = d.connection_id and a.from_type = 'crm_call' and a.removed_at is null
        and ((a.to_type = 'contact' and a.to_id = any (d.contacts)) or (a.to_type = 'deal' and a.to_id = d.source_id))
        and cc.source_deleted_at is null and k.is_connected and k.effective_at > lo.at)
  order by lo.at, d.source_id
$$;

-- The business date of the tenant's earliest counted email (as cma.email_of counts one, in its own
-- zone), or null (as 0008k): tenant-wide, the filters do not narrow it. Read in windows of seven days
-- from the earliest stored email, each bound a value of its own so the read keeps to the index; the
-- earliest date is among the emails up to two days after the first one found (zones differ by at
-- most 26 hours)
create or replace function cma.email_history_start_of(p_tenant_id uuid)
returns date
language plpgsql stable
as $$
declare
  v_at    timestamptz;
  v_found timestamptz;
  v_to    timestamptz;
begin
  select min(em.occurred_at) into v_at from cma.email_message em where em.tenant_id = p_tenant_id and em.source_deleted_at is null;
  while v_at is not null loop
    v_to := v_at + interval '7 days';
    select min(x.occurred_at) into v_found from cma.email_of(p_tenant_id, v_at, v_to) x;
    if v_found is not null then
      v_to := v_found + interval '2 days';
      return (select min(x.business_date) from cma.email_of(p_tenant_id, v_found, v_to) x);
    end if;
    select min(em.occurred_at) into v_at from cma.email_message em
    where em.tenant_id = p_tenant_id and em.source_deleted_at is null and em.occurred_at >= v_to;
  end loop;
  return null;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. The application's reads (permission checked, filters checked, current tenant, row-level security)
-- ---------------------------------------------------------------------------------------------
-- The filters every read takes: a market is a two-letter code or 'unknown'; an inbox and a mailbox a
-- connection id ':' source id. Anything else CMA04
create or replace function cma.email_filters_check(p_market text, p_inbox text, p_account text)
returns void
language plpgsql immutable
as $$
begin
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'a market filter is a market code or unknown, not %', p_market using errcode = 'CMA04';
  end if;
  if p_inbox is not null and p_inbox !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[^@[:space:]]{1,100}$' then
    raise exception 'an inbox filter is a connection id and an inbox id, not %', p_inbox using errcode = 'CMA04';
  end if;
  if p_account is not null and p_account !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[^@[:space:]]{1,100}$' then
    raise exception 'a mailbox filter is a connection id and a mailbox id, not %', p_account using errcode = 'CMA04';
  end if;
end
$$;

create or replace function cma.email_overview(p_from date, p_to date, p_group text, p_market text, p_inbox text, p_account text)
returns table (
  period                         text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'week', 'market', 'inbox', 'account', 'category') then
    raise exception 'group by day, week, market, inbox, account or category, not %', p_group using errcode = 'CMA04';
  end if;
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.email_filters_check(p_market, p_inbox, p_account);
  return query select * from cma.email_overview_of(v_tenant, p_from, p_to, p_group, p_market, p_inbox, p_account);
end
$$;

create or replace function cma.email_by_dimension(p_from date, p_to date, p_market text, p_inbox text, p_account text)
returns table (
  dimension                      text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.email_filters_check(p_market, p_inbox, p_account);
  return query select * from cma.email_by_dimension_of(v_tenant, p_from, p_to, p_market, p_inbox, p_account);
end
$$;

-- The report page's one read (cma.email_report_of): reports.view or performance.team
create or replace function cma.email_report(p_from date, p_to date, p_group text, p_market text, p_inbox text, p_account text)
returns table (
  period                         text,
  dimension                      text,
  group_key                      text,
  group_label                    text,
  received                       integer,
  logged_replies                 integer,
  sent_agent                     integer,
  sent_automated                 integer,
  bounced_failed                 integer,
  threads_opened                 integer,
  threads_closed                 integer,
  replied                        integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  no_hours                       integer,
  close_median_seconds           numeric,
  close_median_business_seconds  numeric
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
  perform cma.email_filters_check(p_market, p_inbox, p_account);
  return query select * from cma.email_report_of(v_tenant, p_from, p_to, p_group, p_market, p_inbox, p_account);
end
$$;

create or replace function cma.email_received_series(p_from date, p_to date, p_group text, p_split text, p_market text, p_inbox text,
                                                     p_account text)
returns table (group_key text, series_key text, series_label text, received integer)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'week') then
    raise exception 'group by day or week, not %', p_group using errcode = 'CMA04';
  end if;
  if p_split is null or p_split not in ('inbox', 'account') then
    raise exception 'split by inbox or account, not %', p_split using errcode = 'CMA04';
  end if;
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.email_filters_check(p_market, p_inbox, p_account);
  return query select * from cma.email_received_series_of(v_tenant, p_from, p_to, p_group, p_split, p_market, p_inbox, p_account);
end
$$;

-- Per person: performance.team, and the tenant's reports.per_person holding email (else CMA06)
create or replace function cma.email_per_person(p_from date, p_to date, p_market text, p_inbox text, p_account text)
returns table (
  row_kind                       text,
  user_id                        uuid,
  display_name                   text,
  unlinked_owners                integer,
  sent                           integer,
  replies                        integer,
  threads_closed                 integer,
  reply_median_seconds           numeric,
  reply_median_business_seconds  numeric,
  within_target                  integer,
  target_known                   integer,
  sent_by_hour                   integer[]
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_per_person('email');
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.email_filters_check(p_market, p_inbox, p_account);
  return query select * from cma.email_per_person_of(v_tenant, p_from, p_to, p_market, p_inbox, p_account);
end
$$;

-- Waiting now: the first follow_up.list_rows rows after the filters (or p_rows, held within 1 to 500),
-- each with the filtered total and the record link (the connection's record_url_thread template, else
-- the ticket's record_url_ticket)
create or replace function cma.email_waiting(p_market text, p_inbox text, p_account text, p_rows integer default null)
returns table (
  connection_id            uuid,
  thread_source_id         text,
  inbox_key                text,
  inbox_name               text,
  account_key              text,
  account_name             text,
  market                   text,
  waiting_since            timestamptz,
  waited_seconds           integer,
  waited_business_seconds  integer,
  record_url               text,
  total_rows               integer
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_rows   integer;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.email_filters_check(p_market, p_inbox, p_account);
  v_rows := least(500, greatest(1, coalesce(p_rows, cma.setting_of(v_tenant, 'follow_up.list_rows')::integer)));
  return query
  select w.connection_id, w.thread_source_id, w.inbox_key, w.inbox_name, w.account_key, w.account_name, w.market, w.waiting_since,
         w.waited_seconds, w.waited_business_seconds,
         coalesce(cma.record_url(w.connection_id, 'thread', w.thread_source_id),
                  case when w.ticket_source_id is not null then cma.record_url(w.connection_id, 'ticket', w.ticket_source_id) end),
         (count(*) over ())::integer
  from cma.email_waiting_of(v_tenant) w
  where (p_market is null or w.market = p_market) and (p_inbox is null or w.inbox_key = p_inbox)
    and (p_account is null or w.account_key = p_account)
  order by w.waiting_since, w.thread_source_id
  limit v_rows;
end
$$;

-- Not responding: the first follow_up.list_rows rows of the market (or p_rows, held within 1 to 500),
-- each with the filtered total, the owner's person (null when the owner maps to nobody) and the deal's
-- record link
create or replace function cma.email_not_responding(p_market text, p_rows integer default null)
returns table (
  connection_id   uuid,
  deal_source_id  text,
  pipeline_label  text,
  market          text,
  owner_user_id   uuid,
  last_email_at   timestamptz,
  days_since      integer,
  record_url      text,
  total_rows      integer
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_rows   integer;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.email_filters_check(p_market, null, null);
  v_rows := least(500, greatest(1, coalesce(p_rows, cma.setting_of(v_tenant, 'follow_up.list_rows')::integer)));
  return query
  select r.connection_id, r.deal_source_id, r.pipeline_label, r.market, xi.user_id, r.last_email_at, r.days_since,
         cma.record_url(r.connection_id, 'deal', r.deal_source_id), (count(*) over ())::integer
  from cma.email_not_responding_of(v_tenant) r
  left join cma.app_user_external_id xi
    on xi.tenant_id = v_tenant and xi.system = r.source_system || '_owner' and xi.external_id = r.owner_ref
  where (p_market is null or r.market = p_market)
  order by r.last_email_at, r.deal_source_id
  limit v_rows;
end
$$;

create or replace function cma.email_history_start()
returns date
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  return cma.email_history_start_of(v_tenant);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 11. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.ingest_upsert_inbox_accounts(uuid,jsonb)',
    'cma.ingest_upsert_threads(uuid,jsonb)',
    'cma.ingest_upsert_emails(uuid,jsonb)',
    'cma.set_inbox_account(uuid,text,text,boolean,text)',
    'cma.connection_config(uuid)',
    'cma.email_market_of(uuid,uuid,text,text)',
    'cma.email_of(uuid,timestamptz,timestamptz)',
    'cma.email_threads_counted_of(uuid,uuid[])',
    'cma.email_openings_of(uuid,timestamptz,timestamptz)',
    'cma.email_closes_of(uuid,timestamptz,timestamptz)',
    'cma.email_figures_of(uuid,date,date,text,text,text,text[],timestamptz)',
    'cma.email_overview_of(uuid,date,date,text,text,text,text,timestamptz)',
    'cma.email_by_dimension_of(uuid,date,date,text,text,text)',
    'cma.email_report_of(uuid,date,date,text,text,text,text,timestamptz)',
    'cma.email_report(date,date,text,text,text,text)',
    'cma.email_received_series_of(uuid,date,date,text,text,text,text,text)',
    'cma.email_per_person_of(uuid,date,date,text,text,text)',
    'cma.email_waiting_of(uuid,timestamptz)',
    'cma.email_not_responding_of(uuid,timestamptz)',
    'cma.email_history_start_of(uuid)',
    'cma.email_overview(date,date,text,text,text,text)',
    'cma.email_by_dimension(date,date,text,text,text)',
    'cma.email_received_series(date,date,text,text,text,text,text)',
    'cma.email_per_person(date,date,text,text,text)',
    'cma.email_waiting(text,text,text,integer)',
    'cma.email_not_responding(text,integer)',
    'cma.email_history_start()',
    'cma.email_filters_check(text,text,text)',
    'cma.per_person_on(uuid,text)',
    'cma.assert_per_person(text)',
    'cma.is_per_person_list(text)',
    'cma.setting_codes(jsonb,text)',
    'cma.crm_call_connected_of(uuid,uuid)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 12. Reporting views
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.connection_inbox_account as
  select tenant_id, connection_id, source_account_id, name, label, inbox_source_id, channel_source_id, is_counted, market, status,
         refreshed_at, updated_at
  from cma.connection_inbox_account
  where cma_read.reader_sees(tenant_id);

-- 0008m's views with the new columns at the end (the earlier columns as they were)
create or replace view cma_read.email_thread as
  select id, tenant_id, connection_id, source_system, source_id, inbox_source_id, channel_source_id, status, source_created_at,
         closed_at, owner_ref, contact_source_id, ticket_source_id, is_spam, is_archived, category, latest_received_at,
         latest_sent_at, source_updated_at, forgotten_at, synced_at, account_ref
  from cma.email_thread
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.email_message as
  select id, tenant_id, connection_id, source_system, source_kind, source_id, thread_source_id, inbox_source_id, channel_source_id,
         direction, status, occurred_at, actor_kind, owner_ref, category, contact_source_id, source_created_at, source_updated_at,
         source_deleted_at, synced_at, account_ref, origin
  from cma.email_message
  where cma_read.reader_sees(tenant_id);

-- Waiting now and not responding for readers, as 0008o's open lists: each over a SECURITY DEFINER
-- function in cma_read (owned by cma_owner, search path pinned, executable by readers only) that reads
-- every tenant the reader sees; ids, codes and ages only
create or replace function cma_read.email_waiting_rows()
returns table (tenant_id uuid, connection_id uuid, thread_source_id text, inbox_key text, account_key text, market text,
               waiting_since timestamptz, waited_seconds integer, waited_business_seconds integer)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, r.connection_id, r.thread_source_id, r.inbox_key, r.account_key, r.market, r.waiting_since, r.waited_seconds,
         r.waited_business_seconds
  from cma.tenant t cross join lateral cma.email_waiting_of(t.id) r where cma_read.reader_sees(t.id)
$$;

create or replace function cma_read.email_not_responding_rows()
returns table (tenant_id uuid, connection_id uuid, deal_source_id text, market text, last_email_at timestamptz, days_since integer)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, r.connection_id, r.deal_source_id, r.market, r.last_email_at, r.days_since
  from cma.tenant t cross join lateral cma.email_not_responding_of(t.id) r where cma_read.reader_sees(t.id)
$$;

do $$
declare
  f text;
begin
  foreach f in array array['cma_read.email_waiting_rows()', 'cma_read.email_not_responding_rows()'] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_readonly', f);
  end loop;
end
$$;

create or replace view cma_read.email_waiting as
  select * from cma_read.email_waiting_rows();

create or replace view cma_read.email_not_responding as
  select * from cma_read.email_not_responding_rows();

-- ---------------------------------------------------------------------------------------------
-- 13. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008t', 'Email reports: mailboxes (the inboxes'' channel accounts) with label, counted and market, account refs on emails and threads, an engagement''s origin with inbox copies and automations as configuration, the setting reports.per_person, the market''s inbox step through the mailbox, the definitions cma.email_of, email_openings_of and email_closes_of, the overview, the figures per inbox, mailbox, category and market, received per day and inbox or mailbox, per person, waiting now, not responding, the history start, the reporting views')
on conflict (version) do nothing;

commit;
reset role;
