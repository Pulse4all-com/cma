-- =============================================================================================
-- 102_reviews.sql: addition 0008zd, reviews from a review platform: channels, reviews, links, alerts and reports
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 100_definitions_calls.sql (0008zc). Rerunnable, forward-only, in one transaction. Run as your own IAM login: dev
-- first, then 103_verify_reviews.sql (dev), then 101, 99, 79, 75 and 41 again (dev; 99 from the Terminal); then prod.
-- Nothing in the web of main reads what this adds, so the script may run before or after the web deploy.
--
-- Why (Decision log, 25 October 2026): the review platform owns the reviews of a business line (Trusted Shops for
-- Pulse4all Subscriptions); the CMA polls them into Postgres, maps them to markets through their channel, links them
-- to an order or a CRM contact where it can, reports them and alerts on negative ones. Read only: nothing is written
-- to the review platform or the CRM. A review is a standalone fact with an optional link; it never holds the
-- reviewer's name, email or phone, nor the review's title or text.
--
-- What it adds
--   connection kind    integration_connection.kind gains reviews: the connection holds review channels and reviews.
--                      cma.connection_held_kinds_of() and cma.set_connection_kind() know it
--   channels           cma.review_channel: the platform's channels per connection (source id, name, locale), the
--                      market each one serves (configuration, a catalog market's code) and whether its reviews count
--                      in reporting (is_counted, default false): a new channel lands without a market and not
--                      counted. first_seen_at, source_deleted_at (gone from the platform's list). Ingest refreshes
--                      name, locale and deletion only; market and is_counted are people's, as a line's
--   reviews            cma.review: one row per review of a connection (source id), its channel, type, the source's
--                      state, whether it is published (the adapter decides from the source's state, so no vendor's
--                      state word lives here), the rating (1 to 5, two decimals), submitted and updated at the source,
--                      whether it has a reply, the invite's event type, the transaction reference, the link level
--                      (order, contact or none) with the order, the CRM contact and when the link was made, a
--                      filtered raw (a fixed set of metadata keys, checked) and synced_at. The market is the
--                      channel's, never stored twice
--   settings           reviews.negative_max_rating (2: a review rated 2 or lower is negative), reviews.history_start_date
--                      (empty: the backfill reads all history)
--   ingest             cma.ingest_upsert_review_channels(connection, items): the whole channel list;
--                      cma.ingest_upsert_reviews(connection, items): reviews with a stale guard on the source's update
--                      time, each linked to the tenant's one commerce order whose order name, else whose source id,
--                      equals its transaction reference, and then to that order's customer's CRM contact (0008h);
--                      cma.set_review_contact(connection, review, CRM connection, contact): the contact the ingest
--                      service found by the reviewer's email in memory, for a review without an order;
--                      cma.forget_review_contact_links(CRM connection, contact): the CRM's privacy deletion of a
--                      contact clears every review's link to it (as 0008h does for commerce)
--   alerts             message_rule.trigger gains review_submitted with message_rule.max_rating (null: any rating);
--                      cma.upsert_review_rule() configures one; cma.ingest_review_alerts(connection, reviews): a
--                      published review of a counted channel that reaches a rule raises one message (the record
--                      alerts' uniqueness), holding the market, the channel's name, the rating, the time and the link
--                      of the connection's record_url_review template only; cma.message_rules() gains max_rating
--   sources            cma.connection_catalogs() gains reviewChannels; cma.set_review_channel(connection, channel,
--                      market, is_counted) (tenant.configure)
--   reports            cma.reviews_page(from, to, market, group) (reports.view or performance.team, at most 92 days):
--                      count, average rating, negative reviews, the distribution by whole star, link levels and invite
--                      event types with the previous period like for like, per day or ISO week, per market and per
--                      channel, and the markets in their review-channel state (no_channel, channel_no_reviews,
--                      has_reviews). No per-person figure exists
--   data quality       review_channel_unmapped (with the reviews held of each) and market_without_review_channel (an
--                      active market without a counted channel, once the tenant has a reviews connection):
--                      cma.data_quality_reviews_checks(), cma.data_quality_of() and cma.data_quality() as 0008zc and
--                      0008p with the two checks; cma_read.dq_ views for both
--   readers            cma_read.review_channel, cma_read.review (no raw), cma_read.reviews_per_day, reviews_per_week,
--                      reviews_per_market and reviews_per_channel (count, average, distribution, link levels, the
--                      previous day or week), cma_read.review_market_state
--   runs               sync_run.job gains reviews_poll
--
-- Counted: a review counts in reporting when it is published and its channel is counted. Everything is SECURITY
-- INVOKER and executable by the application only; the cma_read functions are SECURITY DEFINER, owned by cma_owner,
-- search path pinned, executable by readers only.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zc') then
    raise exception 'addition 0008zc (100_definitions_calls.sql) must run before 0008zd';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The connection's kind: reviews
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_constraint c where c.conrelid = 'cma.integration_connection'::regclass
             and c.conname = 'integration_connection_kind_check' and pg_get_constraintdef(c.oid) not like '%reviews%') then
    alter table cma.integration_connection drop constraint integration_connection_kind_check;
  end if;
  if not exists (select 1 from pg_constraint c where c.conrelid = 'cma.integration_connection'::regclass
                 and c.conname = 'integration_connection_kind_check') then
    alter table cma.integration_connection add constraint integration_connection_kind_check
      check (kind in ('crm', 'telephony', 'commerce', 'automation', 'reviews'));
  end if;
end
$$;
comment on column cma.integration_connection.kind is
  'The kind of source in the data model''s terms (crm, telephony, commerce, automation, reviews), never a vendor; null until set (0008e; reviews 0008zd)';

-- ---------------------------------------------------------------------------------------------
-- 2. Channels and reviews
-- ---------------------------------------------------------------------------------------------
-- A review platform's channels (a shop, a domain) per connection. The market and the counted flag are configuration;
-- name, locale and the deletion come from the source. A channel is never deleted: gone from the source's list, it
-- keeps its reviews and gets source_deleted_at
create table if not exists cma.review_channel (
  id                 uuid primary key default uuidv7(),
  tenant_id          uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id      uuid not null,
  source_id          text not null check (length(source_id) between 1 and 100 and source_id = btrim(source_id)),
  name               text not null check (length(btrim(name)) between 1 and 200),
  locale             text check (locale ~ '^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,3}$'),
  market             text,
  is_counted         boolean not null default false,
  first_seen_at      timestamptz not null default now(),
  source_deleted_at  timestamptz,
  updated_at         timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id),
  foreign key (tenant_id, market) references cma.market (tenant_id, code)
);
comment on table cma.review_channel is 'A review platform''s channels per connection: name and locale from the source, the market served and whether its reviews count (configuration). A new channel has no market and is not counted (0008zd)';
comment on column cma.review_channel.market is 'The catalog market the channel serves (configuration, a market code); null: not mapped yet';
comment on column cma.review_channel.is_counted is 'Whether the channel''s published reviews count in reporting and alerts (configuration; false for a new channel)';
create or replace trigger set_updated_at before update on cma.review_channel
  for each row execute function cma.set_updated_at();

-- The filtered raw of a review: a fixed set of metadata keys, never a name, an address, a phone number, a title or a
-- text; event and transaction hold their type and reference only
create or replace function cma.review_raw_ok(p_raw jsonb)
returns boolean
language sql immutable
as $$
  select p_raw is not null and jsonb_typeof(p_raw) = 'object' and length(p_raw::text) <= 2048
     and not exists (select 1 from jsonb_object_keys(p_raw) k
                     where k not in ('id', 'channelRef', 'rating', 'type', 'state', 'submittedAt', 'updatedAt', 'inviteRef',
                                     'event', 'transaction'))
     and (not (p_raw ? 'event') or (jsonb_typeof(p_raw -> 'event') = 'object'
                                    and not exists (select 1 from jsonb_object_keys(p_raw -> 'event') k where k <> 'type')))
     and (not (p_raw ? 'transaction') or (jsonb_typeof(p_raw -> 'transaction') = 'object'
                                          and not exists (select 1 from jsonb_object_keys(p_raw -> 'transaction') k where k <> 'reference')))
$$;
revoke execute on function cma.review_raw_ok(jsonb) from public;
grant execute on function cma.review_raw_ok(jsonb) to cma_app;

create table if not exists cma.review (
  id                     uuid primary key default uuidv7(),
  tenant_id              uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id          uuid not null,
  review_channel_id      uuid not null,
  source_system          text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_id              text not null check (length(source_id) between 1 and 100 and source_id = btrim(source_id)),
  review_type            text not null check (review_type ~ '^[A-Za-z0-9_.-]{1,40}$'),
  state                  text not null check (state ~ '^[A-Za-z0-9_.-]{1,40}$'),
  is_published           boolean not null,
  rating                 numeric(3,2) not null check (rating between 1 and 5),
  submitted_at           timestamptz not null,
  source_updated_at      timestamptz,
  has_reply              boolean not null default false,
  invite_event_type      text check (length(invite_event_type) between 1 and 60 and invite_event_type !~ '[[:cntrl:]]'),
  transaction_ref        text check (length(transaction_ref) between 1 and 100 and transaction_ref !~ '[[:cntrl:]]'),
  link_level             text not null default 'none' check (link_level in ('order', 'contact', 'none')),
  commerce_order_id      uuid,
  crm_connection_id      uuid,
  crm_contact_source_id  text check (length(crm_contact_source_id) between 1 and 100 and crm_contact_source_id = btrim(crm_contact_source_id)),
  matched_at             timestamptz,
  raw                    jsonb not null default '{}'::jsonb check (cma.review_raw_ok(raw)),
  synced_at              timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  check ((link_level = 'order') = (commerce_order_id is not null)),
  check ((crm_connection_id is null) = (crm_contact_source_id is null)),
  check (link_level <> 'contact' or crm_contact_source_id is not null),
  check (link_level <> 'none' or crm_contact_source_id is null),
  check ((link_level = 'none') = (matched_at is null)),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id),
  foreign key (tenant_id, review_channel_id) references cma.review_channel (tenant_id, id),
  foreign key (tenant_id, commerce_order_id) references cma.commerce_order (tenant_id, id),
  foreign key (tenant_id, crm_connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.review is 'Reviews of a review platform per connection: channel, type, state, published, rating, times, reply, invite event type, transaction reference and the link to an order or a CRM contact. Never the reviewer''s name, email or phone, nor a title or text. Owned by the review platform (0008zd)';
comment on column cma.review.is_published is 'Whether the review is published at the source; the adapter decides it from the source''s state. Reporting counts published reviews of counted channels only';
comment on column cma.review.link_level is 'order: the transaction reference names one commerce order of the tenant; contact: no order, a CRM contact found by the reviewer''s email (in memory, never stored); none';
comment on column cma.review.crm_contact_source_id is 'The CRM contact: the linked order''s customer''s contact (0008h), or the contact the email matched; an id, kept in the CMA only';
comment on column cma.review.matched_at is 'When the current link was made; null without a link';
comment on column cma.review.raw is 'The review''s metadata only: id, channelRef, rating, type, state, submittedAt, updatedAt, inviteRef, event.type, transaction.reference (checked)';
create index if not exists review_submitted_idx on cma.review (tenant_id, submitted_at);
create index if not exists review_channel_idx on cma.review (tenant_id, review_channel_id, submitted_at);
create index if not exists review_contact_idx on cma.review (tenant_id, crm_connection_id, crm_contact_source_id) where crm_contact_source_id is not null;
create index if not exists review_order_idx on cma.review (tenant_id, commerce_order_id) where commerce_order_id is not null;

-- The order link reads a tenant's orders by order name across its stores; its fallback by source id, which only a
-- reference that is no order name reaches, goes through the unique key (tenant_id, connection_id, source_id)
create index if not exists commerce_order_name_idx on cma.commerce_order (tenant_id, order_name) where order_name is not null;

select cma.setup_tenant_table('cma.review_channel');
select cma.setup_tenant_table('cma.review');

-- The application never deletes a channel or a review
revoke delete on cma.review_channel, cma.review from cma_app;

-- The kinds a connection's rows imply, as 0008n (70), plus reviews when it holds review channels or reviews
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
           or exists (select 1 from cma.crm_task x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_task_status x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_task_type x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'crm' end,
    case when exists (select 1 from cma.telephony_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_tag x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_number x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'telephony' end,
    case when exists (select 1 from cma.commerce_store x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.commerce_customer x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.commerce_order x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'commerce' end,
    case when exists (select 1 from cma.review_channel x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.review x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'reviews' end], null)
$$;

-- As 0008e, with reviews among the kinds
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
  if coalesce(p_kind, '') not in ('crm', 'telephony', 'commerce', 'automation', 'reviews') then
    raise exception 'kind must be crm, telephony, commerce, automation or reviews' using errcode = 'CMA04';
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

-- Whether a tenant has a reviews connection: an active connection of kind reviews, or one holding review channels
create or replace function cma.reviews_connected_of(p_tenant_id uuid)
returns boolean
language sql stable
as $$
  select exists (select 1 from cma.integration_connection c
                 where c.tenant_id = p_tenant_id and c.status = 'active'
                   and (c.kind = 'reviews'
                        or exists (select 1 from cma.review_channel ch where ch.tenant_id = c.tenant_id and ch.connection_id = c.id)))
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('reviews.negative_max_rating', 'integer', null, '2',
     'A review rated this many stars or fewer is a negative review (a whole number from 1 to 4)'),
  ('reviews.history_start_date',  'text',    null, '',
     'First date the reviews backfill reads, as YYYY-MM-DD; empty means all history (every review the channels hold)')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0008zc (100), with reviews.negative_max_rating (1 to 4) and reviews.history_start_date (a date, or empty) next to
-- email.start_date
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
  if new.key in ('leads.age_buckets_business_days', 'attempts.since_last_buckets_business_days', 'attempts.speed_buckets_business_minutes') then
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
  -- reviews (0008zd): the highest rating that is a negative review, a whole star from 1 to 4
  elsif new.key = 'reviews.negative_max_rating'
        and (case when length(new.value) > 1 then true else new.value::integer not between 1 and 4 end) then
    raise exception 'Setting % takes a whole number of stars from 1 to 4', new.key using errcode = 'CMA04';
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Ingest: the channel catalog, reviews and their links (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- A connection the reviews may land in: its kind is reviews, or not set yet (its rows then make it one); CMA04 otherwise
create or replace function cma.assert_reviews_connection(p_connection_id uuid)
returns void
language plpgsql stable
as $$
declare
  v_kind text;
begin
  select c.kind into v_kind from cma.integration_connection c
  where c.tenant_id = cma.current_tenant_id() and c.id = p_connection_id;
  if v_kind is not null and v_kind <> 'reviews' then
    raise exception 'connection % is a % connection, not a reviews connection', p_connection_id, v_kind using errcode = 'CMA04';
  end if;
end
$$;

-- The source's whole channel list: [{channelId, name, locale}], at most 500. A new channel is added without a market and
-- not counted; a known one gets its name and locale and, when it was gone, comes back; a channel missing from the list
-- gets source_deleted_at. An empty list changes nothing (no channel to go by). A locale that is no language tag is
-- stored as none. Answers how many channels were added or changed
create or replace function cma.ingest_upsert_review_channels(p_connection_id uuid, p_items jsonb)
returns integer
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_n      integer := 0;
  v_k      integer;
  v_id     text;
  v_name   text;
  v_locale text;
  i        jsonb;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  perform cma.assert_reviews_connection(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'items must be an array of at most 500 channels' using errcode = 'CMA04';
  end if;
  if jsonb_array_length(p_items) = 0 then
    return 0;
  end if;
  for i in select x from jsonb_array_elements(p_items) x loop
    v_id := btrim(i ->> 'channelId');
    v_name := left(btrim(coalesce(i ->> 'name', '')), 200);
    v_locale := nullif(btrim(coalesce(i ->> 'locale', '')), '');
    if v_id is null or length(v_id) not between 1 and 100 or v_id ~ '[[:cntrl:]]' then
      raise exception 'a channel needs an id of 1 to 100 characters' using errcode = 'CMA04';
    end if;
    if v_name = '' then
      v_name := v_id;
    end if;
    if v_locale !~ '^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,3}$' then
      v_locale := null;
    end if;
    insert into cma.review_channel (tenant_id, connection_id, source_id, name, locale)
    values (v_tenant, p_connection_id, v_id, v_name, v_locale)
    on conflict (tenant_id, connection_id, source_id) do update
      set name = excluded.name, locale = excluded.locale, source_deleted_at = null
      where (cma.review_channel.name, cma.review_channel.locale, cma.review_channel.source_deleted_at)
            is distinct from (excluded.name, excluded.locale, null::timestamptz);
    get diagnostics v_k = row_count;
    v_n := v_n + v_k;
  end loop;
  update cma.review_channel ch set source_deleted_at = now()
  where ch.tenant_id = v_tenant and ch.connection_id = p_connection_id and ch.source_deleted_at is null
    and not exists (select 1 from jsonb_array_elements(p_items) x where btrim(x ->> 'channelId') = ch.source_id);
  get diagnostics v_k = row_count;
  return v_n + v_k;
end
$$;

-- The tenant's one commerce order a review's transaction reference names: by order name, else by source id; none when
-- the reference is empty, names no order or names several (not deleted at the source)
create or replace function cma.review_order_of(p_tenant_id uuid, p_ref text)
returns uuid
language sql stable
as $$
  select coalesce(
           (select case when count(*) = 1 then (array_agg(o.id))[1] end
            from cma.commerce_order o
            where o.tenant_id = p_tenant_id and o.order_name = btrim(p_ref) and o.source_deleted_at is null),
           (select case when count(*) = 1 then (array_agg(o.id))[1] end
            from cma.commerce_order o
            where o.tenant_id = p_tenant_id and o.source_id = btrim(p_ref) and o.source_deleted_at is null))
  where nullif(btrim(p_ref), '') is not null
$$;

-- Reviews of a connection: [{reviewId, channelId, type, state, isPublished, rating, submittedAt, updatedAt, hasReply,
-- inviteEventType, transactionRef, raw}], at most 500, the channel already in the catalog. A review whose source update
-- time is older than the stored one is stale and left as it is. The link, each time a review is written or read again
-- unchanged: an order (cma.review_order_of) makes the level order, with the order's customer's CRM contact (0008h), or
-- else the contact the review held; without an order a contact found earlier by email stays (level contact); else none.
-- matched_at keeps its time while the link stays the same. Answers per review its outcome (inserted, updated,
-- unchanged, stale, unknown_channel), its link level and whether it holds a contact; nothing for a review whose
-- channel the catalog lacks (outcome unknown_channel, not stored)
create or replace function cma.ingest_upsert_reviews(p_connection_id uuid, p_items jsonb)
returns table (source_id text, outcome text, link_level text, has_contact boolean)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_system  text;
  i         jsonb;
  v_id      text;
  v_channel uuid;
  v_type    text;
  v_state   text;
  v_pub     boolean;
  v_rating  numeric;
  v_sub     timestamptz;
  v_upd     timestamptz;
  v_reply   boolean;
  v_event   text;
  v_ref     text;
  v_raw     jsonb;
  v_old     cma.review;
  v_order   uuid;
  v_crm     uuid;
  v_contact text;
  v_level   text;
  v_matched timestamptz;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  perform cma.assert_reviews_connection(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'items must be an array of at most 500 reviews' using errcode = 'CMA04';
  end if;
  for i in select x from jsonb_array_elements(p_items) x loop
    v_id := btrim(i ->> 'reviewId');
    if v_id is null or length(v_id) not between 1 and 100 or v_id ~ '[[:cntrl:]]' then
      raise exception 'a review needs an id of 1 to 100 characters' using errcode = 'CMA04';
    end if;
    v_channel := null;
    select ch.id into v_channel from cma.review_channel ch
    where ch.tenant_id = v_tenant and ch.connection_id = p_connection_id and ch.source_id = btrim(i ->> 'channelId');
    if v_channel is null then
      source_id := v_id; outcome := 'unknown_channel'; link_level := null; has_contact := null;
      return next;
      continue;
    end if;
    if jsonb_typeof(i -> 'rating') <> 'number' or jsonb_typeof(i -> 'isPublished') <> 'boolean' then
      raise exception 'review %: rating must be a number and isPublished true or false', v_id using errcode = 'CMA04';
    end if;
    v_rating := (i ->> 'rating')::numeric;
    v_pub := (i ->> 'isPublished')::boolean;
    v_type := btrim(i ->> 'type');
    v_state := btrim(i ->> 'state');
    v_sub := cma.json_time(i -> 'submittedAt', 'submittedAt');
    v_upd := cma.json_time(i -> 'updatedAt', 'updatedAt');
    v_reply := coalesce((i ->> 'hasReply')::boolean, false);
    v_event := nullif(btrim(coalesce(i ->> 'inviteEventType', '')), '');
    v_ref := nullif(btrim(coalesce(i ->> 'transactionRef', '')), '');
    v_raw := coalesce(i -> 'raw', '{}'::jsonb);
    if v_sub is null or v_rating is null or v_rating not between 1 and 5 or v_type is null or v_state is null then
      raise exception 'review %: submittedAt, a rating from 1 to 5, a type and a state are needed', v_id using errcode = 'CMA04';
    end if;
    v_rating := round(v_rating, 2);

    v_old := null;
    select * into v_old from cma.review r
    where r.tenant_id = v_tenant and r.connection_id = p_connection_id and r.source_id = v_id
    for update;
    if v_old.id is not null and v_upd is not null and v_old.source_updated_at is not null and v_upd < v_old.source_updated_at then
      source_id := v_id; outcome := 'stale'; link_level := v_old.link_level; has_contact := v_old.crm_contact_source_id is not null;
      return next;
      continue;
    end if;

    -- the link
    v_order := cma.review_order_of(v_tenant, v_ref);
    v_crm := null;
    v_contact := null;
    if v_order is not null then
      select cu.crm_connection_id, cu.crm_contact_source_id into v_crm, v_contact
      from cma.commerce_order o
      join cma.commerce_customer cu
        on cu.tenant_id = o.tenant_id and cu.connection_id = o.connection_id and cu.source_id = o.customer_source_id
      where o.tenant_id = v_tenant and o.id = v_order and cu.crm_contact_source_id is not null;
      if v_contact is null and v_old.crm_contact_source_id is not null then
        v_crm := v_old.crm_connection_id;
        v_contact := v_old.crm_contact_source_id;
      end if;
      v_level := 'order';
    elsif v_old.link_level = 'contact' then
      v_level := 'contact';
      v_crm := v_old.crm_connection_id;
      v_contact := v_old.crm_contact_source_id;
    else
      v_level := 'none';
    end if;
    v_matched := case when v_level = 'none' then null
                      when v_old.id is not null and v_old.link_level = v_level and v_old.commerce_order_id is not distinct from v_order
                           and v_old.crm_connection_id is not distinct from v_crm
                           and v_old.crm_contact_source_id is not distinct from v_contact then v_old.matched_at
                      else now() end;

    if v_old.id is null then
      insert into cma.review (tenant_id, connection_id, review_channel_id, source_system, source_id, review_type, state, is_published,
                              rating, submitted_at, source_updated_at, has_reply, invite_event_type, transaction_ref, link_level,
                              commerce_order_id, crm_connection_id, crm_contact_source_id, matched_at, raw)
      values (v_tenant, p_connection_id, v_channel, v_system, v_id, v_type, v_state, v_pub, v_rating, v_sub, v_upd, v_reply, v_event,
              v_ref, v_level, v_order, v_crm, v_contact, v_matched, v_raw);
      outcome := 'inserted';
    elsif (v_old.review_channel_id, v_old.review_type, v_old.state, v_old.is_published, v_old.rating, v_old.submitted_at,
           v_old.source_updated_at, v_old.has_reply, v_old.invite_event_type, v_old.transaction_ref, v_old.link_level,
           v_old.commerce_order_id, v_old.crm_connection_id, v_old.crm_contact_source_id, v_old.matched_at, v_old.raw)
          is distinct from
          (v_channel, v_type, v_state, v_pub, v_rating, v_sub, v_upd, v_reply, v_event, v_ref, v_level, v_order, v_crm, v_contact,
           v_matched, v_raw) then
      update cma.review r
         set review_channel_id = v_channel, review_type = v_type, state = v_state, is_published = v_pub, rating = v_rating,
             submitted_at = v_sub, source_updated_at = v_upd, has_reply = v_reply, invite_event_type = v_event,
             transaction_ref = v_ref, link_level = v_level, commerce_order_id = v_order, crm_connection_id = v_crm,
             crm_contact_source_id = v_contact, matched_at = v_matched, raw = v_raw, synced_at = now()
       where r.tenant_id = v_tenant and r.id = v_old.id;
      outcome := 'updated';
    else
      outcome := 'unchanged';
    end if;
    source_id := v_id;
    link_level := v_level;
    has_contact := v_contact is not null;
    return next;
  end loop;
exception when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
  raise exception 'invalid review: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- The CRM contact the ingest service found by a review's email (in memory only), for a review without an order: links,
-- relinks or, with a null contact, clears. The CRM connection must be active and a CRM connection of the tenant (as
-- 0008h). Answers linked, relinked, unchanged, cleared, unlinked, order (the review is linked to an order: its contact
-- is the order's, nothing changes) or unknown (no such review: nothing to do)
create or replace function cma.set_review_contact(p_connection_id uuid, p_review_id text, p_crm_connection_id uuid, p_contact_id text)
returns text
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_row     cma.review;
  v_contact text := nullif(btrim(p_contact_id), '');
  v_kind    text;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  select * into v_row from cma.review r
  where r.tenant_id = v_tenant and r.connection_id = p_connection_id and r.source_id = btrim(p_review_id)
  for update;
  if v_row.id is null then
    return 'unknown';
  end if;
  if v_row.link_level = 'order' then
    return 'order';
  end if;
  if v_contact is null then
    if v_row.link_level = 'none' then
      return 'unlinked';
    end if;
    update cma.review r set link_level = 'none', crm_connection_id = null, crm_contact_source_id = null, matched_at = null, synced_at = now()
    where r.tenant_id = v_tenant and r.id = v_row.id;
    return 'cleared';
  end if;
  if length(v_contact) > 100 then
    raise exception 'a contact id is 1 to 100 characters' using errcode = 'CMA04';
  end if;
  perform cma.active_connection_adapter(p_crm_connection_id);
  select c.kind into v_kind from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_crm_connection_id;
  if not (coalesce(v_kind, '') = 'crm'
          or (v_kind is null and cma.connection_held_kinds_of(v_tenant, p_crm_connection_id) = array['crm'])) then
    raise exception 'connection % is not a CRM connection', p_crm_connection_id using errcode = 'CMA04';
  end if;
  if v_row.crm_connection_id = p_crm_connection_id and v_row.crm_contact_source_id = v_contact then
    return 'unchanged';
  end if;
  update cma.review r
     set link_level = 'contact', crm_connection_id = p_crm_connection_id, crm_contact_source_id = v_contact, matched_at = now(), synced_at = now()
   where r.tenant_id = v_tenant and r.id = v_row.id;
  return case when v_row.crm_contact_source_id is null then 'linked' else 'relinked' end;
end
$$;

-- The CRM deleted a contact for privacy: every review's link to it in the current tenant is cleared (as 0008h's
-- commerce links). A review linked by email loses its link (level none); a review linked to an order keeps the order.
-- Answers how many reviews lost the contact
create or replace function cma.forget_review_contact_links(p_crm_connection_id uuid, p_contact_id text)
returns integer
language plpgsql
as $$
declare
  v_n integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.assert_connection(p_crm_connection_id);
  update cma.review r
     set crm_connection_id = null, crm_contact_source_id = null,
         link_level = case when r.link_level = 'order' then 'order' else 'none' end,
         matched_at = case when r.link_level = 'order' then r.matched_at end,
         synced_at = now()
   where r.tenant_id = cma.current_tenant_id() and r.crm_connection_id = p_crm_connection_id
     and r.crm_contact_source_id = btrim(p_contact_id);
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Alert rules: review_submitted with a highest rating
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_constraint c where c.conrelid = 'cma.message_rule'::regclass and c.conname = 'message_rule_trigger_check'
             and pg_get_constraintdef(c.oid) not like '%review_submitted%') then
    alter table cma.message_rule drop constraint message_rule_trigger_check;
  end if;
  if not exists (select 1 from pg_constraint c where c.conrelid = 'cma.message_rule'::regclass and c.conname = 'message_rule_trigger_check') then
    alter table cma.message_rule add constraint message_rule_trigger_check
      check (trigger in ('record_created', 'record_assigned', 'review_submitted'));
  end if;
end
$$;
alter table cma.message_rule add column if not exists max_rating numeric(3,2);
do $$
begin
  if not exists (select 1 from pg_constraint c where c.conrelid = 'cma.message_rule'::regclass and c.conname = 'message_rule_max_rating_check') then
    alter table cma.message_rule add constraint message_rule_max_rating_check
      check (max_rating is null or (max_rating between 1 and 5 and trigger = 'review_submitted'));
  end if;
  if not exists (select 1 from pg_constraint c where c.conrelid = 'cma.message_rule'::regclass and c.conname = 'message_rule_review_check') then
    alter table cma.message_rule add constraint message_rule_review_check
      check (trigger <> 'review_submitted' or (record_type = 'review' and cardinality(pipeline_ids) = 0));
  end if;
end
$$;
comment on column cma.message_rule.trigger is 'record_created: a new record alerts an audience; record_assigned: a record alerts the person its owner maps to (0008a); review_submitted: a published review of a counted channel alerts an audience (0008zd)';
comment on column cma.message_rule.max_rating is 'review_submitted only: the highest rating that raises the alert (1 to 5); null: any rating (0008zd)';

-- A review rule (tenant.configure), identified by name like every rule: record type review, no pipelines, an audience as
-- a created-record rule's, and the highest rating that raises it (null: any). A name that belongs to a rule of another
-- trigger is CMA03
create or replace function cma.upsert_review_rule(p_name text, p_audience_permission text, p_match_language boolean,
                                                  p_only_clocked_in boolean, p_fallback_permission text, p_urgency text,
                                                  p_max_rating numeric, p_max_age_minutes integer default null)
returns uuid
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_id     uuid;
begin
  perform cma.assert_permission('tenant.configure');
  if coalesce(length(btrim(p_name)), 0) not between 1 and 80 then
    raise exception 'a rule needs a name of 1 to 80 characters' using errcode = 'CMA04';
  end if;
  if p_match_language is null or p_only_clocked_in is null then
    raise exception 'match_language and only_clocked_in must be true or false' using errcode = 'CMA04';
  end if;
  if coalesce(p_urgency, '') not in ('normal', 'urgent') then
    raise exception 'urgency must be normal or urgent' using errcode = 'CMA04';
  end if;
  if p_max_rating is not null and p_max_rating not between 1 and 5 then
    raise exception 'the highest rating is 1 to 5, or none for any rating' using errcode = 'CMA04';
  end if;
  if not exists (select 1 from cma.permission p where p.key = p_audience_permission) then
    raise exception 'no permission %', p_audience_permission using errcode = 'CMA02';
  end if;
  if p_fallback_permission is not null and not exists (select 1 from cma.permission p where p.key = p_fallback_permission) then
    raise exception 'no permission %', p_fallback_permission using errcode = 'CMA02';
  end if;
  if exists (select 1 from cma.message_rule r where r.tenant_id = v_tenant and r.name = btrim(p_name) and r.trigger <> 'review_submitted') then
    raise exception 'a rule of another trigger has the name %', btrim(p_name) using errcode = 'CMA03';
  end if;
  insert into cma.message_rule (tenant_id, name, trigger, record_type, pipeline_ids, audience_permission, match_language,
                                only_clocked_in, fallback_permission, urgency, max_age_minutes, max_rating)
  values (v_tenant, btrim(p_name), 'review_submitted', 'review', '{}', p_audience_permission, p_match_language, p_only_clocked_in,
          p_fallback_permission, p_urgency, p_max_age_minutes, round(p_max_rating, 2))
  on conflict (tenant_id, name) do update
    set audience_permission = excluded.audience_permission, match_language = excluded.match_language,
        only_clocked_in = excluded.only_clocked_in, fallback_permission = excluded.fallback_permission,
        urgency = excluded.urgency, max_age_minutes = excluded.max_age_minutes, max_rating = excluded.max_rating
  returning id into v_id;
  return v_id;
exception when check_violation or not_null_violation then
  raise exception 'invalid review rule: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- As 0008e, with each rule's highest rating (review_submitted; null otherwise or for any rating) last
drop function if exists cma.message_rules();
create function cma.message_rules()
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
  last_alert_at        timestamptz,
  max_rating           numeric
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
           (select max(m.created_at) from cma.message m where m.tenant_id = r.tenant_id and m.rule_id = r.id),
           r.max_rating::numeric
    from cma.message_rule r
    where r.tenant_id = cma.current_tenant_id()
    order by (not r.enabled), r.name;
end
$$;

-- Review alerts (ingest.write): the ingest service's call after it wrote reviews. For each review of the connection
-- (published, of a counted channel, submitted less than the rule's age limit ago) and each enabled review rule whose
-- highest rating it does not exceed: recipients as a created-record alert's (cma.ingest_record_alerts of 0008c: the
-- audience permission, clocked in if the rule asks, the market's language at its minimum level if the rule asks; nobody:
-- the fallback permission), the market being the channel's. One message per rule and review (the record alerts' index),
-- so a second call writes nothing. The message holds the market, the channel's name, the rating, the time in the
-- tenant's zone and the link of the connection's record_url_review template; nothing of the reviewer or the text.
-- Answers the number of messages written
create or replace function cma.ingest_review_alerts(p_connection_id uuid, p_source_ids text[])
returns integer
language plpgsql
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  v_default  integer;
  v_zone     text;
  r          record;
  m          cma.market;
  v_users    uuid[];
  v_fallback boolean;
  v_msg      uuid;
  v_written  integer := 0;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if p_source_ids is null or cardinality(p_source_ids) > 500 then
    raise exception 'source ids must be an array of at most 500' using errcode = 'CMA04';
  end if;
  v_default := coalesce((select s.value::integer from cma.tenant_settings() s where s.key = 'alerts.max_age_minutes'), 60);
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;

  for r in
    select rv.source_id, rv.rating, rv.submitted_at, ch.market, ch.name as channel_name,
           ru.id as rule_id, ru.name as rule_name, ru.audience_permission, ru.match_language, ru.only_clocked_in,
           ru.fallback_permission, ru.urgency, ru.max_rating, coalesce(ru.max_age_minutes, v_default) as max_age
    from cma.review rv
    join cma.review_channel ch on ch.tenant_id = rv.tenant_id and ch.id = rv.review_channel_id
    join cma.message_rule ru
      on ru.tenant_id = rv.tenant_id and ru.enabled and ru.trigger = 'review_submitted'
     and (ru.max_rating is null or rv.rating <= ru.max_rating)
    where rv.tenant_id = v_tenant and rv.connection_id = p_connection_id and rv.source_id = any (p_source_ids)
      and rv.is_published and ch.is_counted
    order by rv.submitted_at, rv.source_id, ru.name
  loop
    if r.submitted_at < now() - make_interval(mins => r.max_age) then
      continue;
    end if;
    if exists (select 1 from cma.message x
               where x.tenant_id = v_tenant and x.rule_id = r.rule_id and x.ref_system = v_system
                 and x.ref_type = 'review' and x.ref_id = r.source_id) then
      continue;
    end if;

    m := null;
    select * into m from cma.market mk where mk.tenant_id = v_tenant and mk.code = r.market;

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
    values (v_tenant, 'alert', r.urgency, 'New review',
            left(coalesce(r.market, 'unknown') || ' · ' || r.channel_name || ' · rating ' || trim_scale(r.rating)::text || ' of 5 · submitted '
                 || to_char(r.submitted_at at time zone v_zone, 'HH24:MI'), 500),
            v_system, 'review', r.source_id, cma.record_url(p_connection_id, 'review', r.source_id), r.rule_id,
            jsonb_build_object('rule', r.rule_name, 'permission', r.audience_permission, 'market', r.market,
                               'matchLanguage', r.match_language, 'onlyClockedIn', r.only_clocked_in,
                               'fallback', v_fallback, 'maxRating', r.max_rating),
            cma.current_user_id())
    on conflict (tenant_id, rule_id, ref_system, ref_type, ref_id) where rule_id is not null and not (target ? 'assignee') do nothing
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
-- 6. Sources: a review channel's market and counted flag (tenant.configure)
-- ---------------------------------------------------------------------------------------------
-- A channel of the connection's catalog (CMA02 otherwise): its market (a catalog market's code, or null for none) and
-- whether its reviews count. Ingest never writes either, so a catalog refresh keeps them
create or replace function cma.set_review_channel(p_connection_id uuid, p_channel_id text, p_market text, p_is_counted boolean)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_is_counted is null then
    raise exception 'counted must be true or false' using errcode = 'CMA04';
  end if;
  if p_market is not null then
    perform cma.assert_market(p_market, false);
  end if;
  update cma.review_channel ch set market = p_market, is_counted = p_is_counted
  where ch.tenant_id = cma.current_tenant_id() and ch.connection_id = p_connection_id and ch.source_id = btrim(p_channel_id)
    and (ch.market, ch.is_counted) is distinct from (p_market, p_is_counted);
  if not found and not exists (select 1 from cma.review_channel ch
                               where ch.tenant_id = cma.current_tenant_id() and ch.connection_id = p_connection_id
                                 and ch.source_id = btrim(p_channel_id)) then
    raise exception 'no review channel % in connection %', p_channel_id, p_connection_id using errcode = 'CMA02';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Sources: the review channels in the connection's catalogs
-- ---------------------------------------------------------------------------------------------
-- As 0008zc (100), with the review channels: source id, name, locale, market, counted, first seen, gone, the reviews held
-- and the latest submitted time
-- As 0008p (74), and each tag with its meaning (null for none)
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
                                                           'status', t.status, 'meaning', t.meaning)
                                       order by t.name, t.tag_ref)
                      from cma.telephony_tag t where t.tenant_id = v_tenant and t.connection_id = p_connection_id), '[]'::jsonb),
    'sampleIds', coalesce((select jsonb_object_agg(x.record_type, x.source_id)
                           from (select distinct on (r.record_type) r.record_type, r.source_id
                                 from cma.crm_record r
                                 where r.tenant_id = v_tenant and r.connection_id = p_connection_id and r.source_deleted_at is null
                                 order by r.record_type, r.source_created_at desc nulls last, r.source_id) x), '{}'::jsonb),
    'reviewChannels', coalesce((select jsonb_agg(jsonb_build_object('channelId', ch.source_id, 'name', ch.name, 'locale', ch.locale,
                                                                      'market', ch.market, 'isCounted', ch.is_counted,
                                                                      'firstSeenAt', ch.first_seen_at, 'deletedAt', ch.source_deleted_at,
                                                                      'reviews', (select count(*) from cma.review r
                                                                                  where r.tenant_id = ch.tenant_id and r.review_channel_id = ch.id),
                                                                      'lastSubmittedAt', (select max(r.submitted_at) from cma.review r
                                                                                          where r.tenant_id = ch.tenant_id and r.review_channel_id = ch.id))
                                                  order by (ch.source_deleted_at is not null), ch.name, ch.source_id)
                                from cma.review_channel ch where ch.tenant_id = v_tenant and ch.connection_id = p_connection_id), '[]'::jsonb));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Data quality: unmapped review channels and markets without one
-- ---------------------------------------------------------------------------------------------
-- The reviews' checks, listed apart and shown after 0008p's, as each addition lists its own (41, 69, 73 and 75 pin
-- theirs): shown once the tenant has a reviews connection, or while one finds something
create or replace function cma.data_quality_reviews_checks()
returns table (check_key text, sort_order integer, description text)
language sql immutable
as $$
  values
    ('review_channel_unmapped',       210, 'Review channels without a market, with the reviews held of each'),
    ('market_without_review_channel', 220, 'Active markets without a counted review channel')
$$;

-- As 0008zc (100), plus review_channel_unmapped (a review channel the source holds without a market; the value holds
-- the reviews held of it) and market_without_review_channel (an active market without a counted review channel the
-- source holds, once the tenant has a reviews connection)
create or replace function cma.data_quality_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_start timestamptz;
begin
  select cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone into v_start
  from cma.tenant t where t.id = p_tenant_id;

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
  -- outbound call not connected (no answer) and without a current tag is skipped when the connection says so
  -- (dq_unlinked_skip = outbound_unanswered_untagged, the default for a telephony connection; 0008o; 0008zc)
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
             and tc.answered_at is null
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
                    where not (a.v = any (ff.options || ff.retired_options))))
  union all
  -- review channels the source holds without a market (0008zd), with how many reviews the CMA holds of each
  select 'review_channel_unmapped', ch.connection_id, 'review_channel', ch.source_id,
         (select count(*) from cma.review r where r.tenant_id = ch.tenant_id and r.review_channel_id = ch.id)::text
  from cma.review_channel ch
  where ch.tenant_id = p_tenant_id and ch.source_deleted_at is null and ch.market is null
  union all
  -- active markets without a counted review channel, once the tenant has a reviews connection (0008zd)
  select 'market_without_review_channel', null::uuid, 'market', m.code, null::text
  from cma.market m
  where m.tenant_id = p_tenant_id and m.status = 'active' and cma.reviews_connected_of(p_tenant_id)
    and not exists (select 1 from cma.review_channel ch
                    where ch.tenant_id = m.tenant_id and ch.market = m.code and ch.is_counted and ch.source_deleted_at is null);

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

-- As 0008p (74), plus the reviews' checks: listed once the tenant has a reviews connection, or while one finds something.
-- A tenant without either keeps every earlier row exactly
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
      union all
      select rc.check_key, rc.sort_order, rc.description from cma.data_quality_reviews_checks() rc
      where cma.reviews_connected_of(v_tenant) or exists (select 1 from q where q.check_key = rc.check_key)
    )
    select c.check_key, c.description,
           case when c.check_key = 'writeback_parked' and to_regclass('cma.outbox_action') is null then null
                else (select count(*) from q where q.check_key = c.check_key)::integer end
    from c
    order by c.sort_order;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Reports, Reviews (reports.view or performance.team)
-- ---------------------------------------------------------------------------------------------
-- The counted reviews of a tenant (published, of a counted channel), each with its channel, market (the channel's, else
-- unknown), rating, whole star (rounded up, so a star k holds the ratings above k - 1 up to k and the negative reviews
-- are whole stars), whether it is negative (rating at or below reviews.negative_max_rating), its business date and time
-- in the tenant's zone, its ISO week, link level and invite event type. Reads the setting once
create or replace function cma.reviews_of(p_tenant_id uuid)
returns table (review_id uuid, connection_id uuid, review_channel_id uuid, channel_source_id text, channel_name text, market text,
               rating numeric, stars integer, is_negative boolean, submitted_at timestamptz, business_date date, local_time time,
               week_start date, link_level text, invite_event_type text)
language sql stable
as $$
  select r.id, r.connection_id, ch.id, ch.source_id, ch.name, coalesce(ch.market, 'unknown'), r.rating, ceil(r.rating)::integer,
         r.rating <= s.neg, r.submitted_at, z.local::date, z.local::time, date_trunc('week', z.local)::date, r.link_level,
         r.invite_event_type
  from cma.review r
  join cma.review_channel ch on ch.tenant_id = r.tenant_id and ch.id = r.review_channel_id
  cross join (select cma.setting_of(p_tenant_id, 'reviews.negative_max_rating')::numeric as neg,
                     (select t.timezone from cma.tenant t where t.id = p_tenant_id) as zone
              offset 0) s   -- read once, not per review (offset 0 keeps the planner from pulling the two reads into every row)
  cross join lateral (select r.submitted_at at time zone s.zone as local) z
  where r.tenant_id = p_tenant_id and r.is_published and ch.is_counted
$$;

-- Every active market of a tenant with its review-channel state: no_channel (no counted channel the source still holds
-- serves it), channel_no_reviews (such a channel, without a published review), has_reviews; with the channels and the
-- published reviews they hold
create or replace function cma.review_market_states_of(p_tenant_id uuid)
returns table (market text, name text, state text, channels integer, reviews integer)
language sql stable
as $$
  with per_channel as (
    select r.review_channel_id, count(*) as reviews
    from cma.review r
    where r.tenant_id = p_tenant_id and r.is_published
    group by r.review_channel_id
  ), per_market as (
    select ch.market, count(*)::integer as channels, coalesce(sum(pc.reviews), 0)::integer as reviews
    from cma.review_channel ch
    left join per_channel pc on pc.review_channel_id = ch.id
    where ch.tenant_id = p_tenant_id and ch.is_counted and ch.source_deleted_at is null and ch.market is not null
    group by ch.market
  )
  select m.code, m.name,
         case when coalesce(pm.channels, 0) = 0 then 'no_channel' when pm.reviews = 0 then 'channel_no_reviews' else 'has_reviews' end,
         coalesce(pm.channels, 0), coalesce(pm.reviews, 0)
  from cma.market m
  left join per_market pm on pm.market = m.code
  where m.tenant_id = p_tenant_id and m.status = 'active'
  order by m.sort_order, m.code
$$;

-- The figures of a set of counted reviews from its aggregates: count, average rating (two decimals; null without
-- reviews), negative, and the link levels
create or replace function cma.review_figures(p_reviews bigint, p_average numeric, p_negative bigint, p_order bigint, p_contact bigint,
                                              p_none bigint)
returns jsonb
language sql immutable
as $$
  select jsonb_build_object('reviews', coalesce(p_reviews, 0), 'average_rating', round(p_average, 2), 'negative', coalesce(p_negative, 0),
                            'linked_order', coalesce(p_order, 0), 'linked_contact', coalesce(p_contact, 0), 'unlinked', coalesce(p_none, 0))
$$;

-- The page for an explicit tenant as of p_now (a verifier gives a fixed instant): the period's figures and the previous
-- period's, like for like (cma.forms_previous_of: when the period runs to today, the previous one is cut at the same time
-- of day), the distribution by whole star, per day or ISO week (every group of the period, empty ones too), per market,
-- per channel, link levels, invite event types, the markets' review-channel states, the history start (the first
-- counted review's date), the negative threshold, whether the tenant has a reviews connection, and the markets the filter
-- offers. p_market narrows everything but the markets' states and the filter list
create or replace function cma.reviews_page_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_group text, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone  text;
  v_prev  record;
  v_until time;
begin
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  select * into v_prev from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now);
  v_until := (v_prev.until at time zone v_zone)::time;
  return (
    with a as materialized (
      select x.*,
             cma.in_period(x.business_date, x.local_time, p_from, p_to, null) as cur,
             cma.in_period(x.business_date, x.local_time, v_prev.prev_from, v_prev.prev_to, v_until) as pre,
             case when p_group = 'day' then x.business_date else x.week_start end as group_key
      from cma.reviews_of(p_tenant_id) x
      where (p_market is null or x.market = p_market) and x.submitted_at <= p_now
    ), r as materialized (
      select * from a where cur or pre
    )
    select jsonb_build_object(
      'figures', (select cma.review_figures(count(*) filter (where cur), avg(rating) filter (where cur), count(*) filter (where cur and is_negative),
                                            count(*) filter (where cur and link_level = 'order'), count(*) filter (where cur and link_level = 'contact'),
                                            count(*) filter (where cur and link_level = 'none')) from r),
      'previous', (select cma.review_figures(count(*) filter (where pre), avg(rating) filter (where pre), count(*) filter (where pre and is_negative),
                                             count(*) filter (where pre and link_level = 'order'), count(*) filter (where pre and link_level = 'contact'),
                                             count(*) filter (where pre and link_level = 'none')) from r),
      'previous_from', v_prev.prev_from, 'previous_to', v_prev.prev_to, 'previous_partial', v_prev.until is not null,
      'distribution', (select jsonb_agg(jsonb_build_object('stars', s, 'reviews', coalesce(d.reviews, 0), 'previous', coalesce(d.previous, 0)) order by s)
                       from generate_series(1, 5) s
                       left join (select stars, count(*) filter (where cur) as reviews, count(*) filter (where pre) as previous
                                  from r group by stars) d on d.stars = s),
      'groups', (select jsonb_agg(jsonb_build_object('key', g.key)
                                  || cma.review_figures(d.reviews, d.average, d.negative, d.linked_order, d.linked_contact, d.unlinked)
                                  order by g.key)
                 from (select k::date as key
                       from generate_series(case when p_group = 'day' then p_from else date_trunc('week', p_from)::date end, p_to,
                                            case when p_group = 'day' then interval '1 day' else interval '7 days' end) k) g
                 left join (select group_key, count(*) as reviews, avg(rating) as average, count(*) filter (where is_negative) as negative,
                                   count(*) filter (where link_level = 'order') as linked_order,
                                   count(*) filter (where link_level = 'contact') as linked_contact,
                                   count(*) filter (where link_level = 'none') as unlinked
                            from r where cur group by group_key) d on d.group_key = g.key),
      'markets', (select coalesce(jsonb_agg(jsonb_build_object('market', m.market, 'name', mk.name, 'current', m.c, 'previous', m.p)
                                            order by (m.market = 'unknown'), mk.sort_order, m.market), '[]'::jsonb)
                  from (select market,
                               cma.review_figures(count(*) filter (where cur), avg(rating) filter (where cur), count(*) filter (where cur and is_negative),
                                                  count(*) filter (where cur and link_level = 'order'), count(*) filter (where cur and link_level = 'contact'),
                                                  count(*) filter (where cur and link_level = 'none')) as c,
                               cma.review_figures(count(*) filter (where pre), avg(rating) filter (where pre), count(*) filter (where pre and is_negative),
                                                  count(*) filter (where pre and link_level = 'order'), count(*) filter (where pre and link_level = 'contact'),
                                                  count(*) filter (where pre and link_level = 'none')) as p
                        from r group by market) m
                  left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = m.market),
      'channels', (select coalesce(jsonb_agg(jsonb_build_object('channel', c.channel_source_id, 'name', c.channel_name, 'market', c.market,
                                                                'current', c.c, 'previous', c.p)
                                             order by c.channel_name, c.channel_source_id), '[]'::jsonb)
                   from (select channel_source_id, channel_name, market,
                                cma.review_figures(count(*) filter (where cur), avg(rating) filter (where cur), count(*) filter (where cur and is_negative),
                                                   count(*) filter (where cur and link_level = 'order'), count(*) filter (where cur and link_level = 'contact'),
                                                   count(*) filter (where cur and link_level = 'none')) as c,
                                cma.review_figures(count(*) filter (where pre), avg(rating) filter (where pre), count(*) filter (where pre and is_negative),
                                                   count(*) filter (where pre and link_level = 'order'), count(*) filter (where pre and link_level = 'contact'),
                                                   count(*) filter (where pre and link_level = 'none')) as p
                         from r group by channel_source_id, channel_name, market) c),
      'link_levels', (select jsonb_agg(jsonb_build_object('level', l, 'reviews', coalesce(d.reviews, 0), 'previous', coalesce(d.previous, 0)) order by o)
                      from unnest(array['order', 'contact', 'none']) with ordinality u(l, o)
                      left join (select link_level, count(*) filter (where cur) as reviews, count(*) filter (where pre) as previous
                                 from r group by link_level) d on d.link_level = u.l),
      'invite_events', (select coalesce(jsonb_agg(jsonb_build_object('event_type', e.invite_event_type, 'reviews', e.reviews, 'previous', e.previous)
                                                  order by e.reviews desc, e.invite_event_type nulls last), '[]'::jsonb)
                        from (select invite_event_type, count(*) filter (where cur) as reviews, count(*) filter (where pre) as previous
                              from r group by invite_event_type) e),
      'market_states', (select coalesce(jsonb_agg(jsonb_build_object('market', s.market, 'name', s.name, 'state', s.state,
                                                                     'channels', s.channels, 'reviews', s.reviews)), '[]'::jsonb)
                        from cma.review_market_states_of(p_tenant_id) s),
      'history_start', (select min(business_date) from a),
      'negative_max_rating', cma.setting_of(p_tenant_id, 'reviews.negative_max_rating')::integer,
      'connected', cma.reviews_connected_of(p_tenant_id),
      'filter_markets', (select coalesce(jsonb_agg(f.market order by (f.market = 'unknown'), f.sort_order, f.market), '[]'::jsonb)
                         from (select distinct coalesce(ch.market, 'unknown') as market, coalesce(mk.sort_order, 2147483647) as sort_order
                               from cma.review_channel ch
                               left join cma.market mk on mk.tenant_id = ch.tenant_id and mk.code = ch.market
                               where ch.tenant_id = p_tenant_id and ch.is_counted) f))
  );
end
$$;

-- Reports, Reviews in one read (reports.view or performance.team; at most 92 days; a market's code or unknown; grouped by
-- day or week). Team figures only: no figure per person exists
create or replace function cma.reviews_page(p_from date, p_to date, p_market text default null, p_group text default 'week')
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'a market filter is a two-letter code or unknown' using errcode = 'CMA04';
  end if;
  if p_group is null or p_group not in ('day', 'week') then
    raise exception 'group by day or week' using errcode = 'CMA04';
  end if;
  return cma.reviews_page_of(v_tenant, p_from, p_to, p_market, p_group, now());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. sync_run: the reviews poll
-- ---------------------------------------------------------------------------------------------
alter table cma.sync_run drop constraint if exists sync_run_job_check;
alter table cma.sync_run add constraint sync_run_job_check
  check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls', 'email_poll', 'close_forgotten_workdays',
                 'refresh_follow_up', 'reviews_poll')) not valid;
alter table cma.sync_run validate constraint sync_run_job_check;

-- ---------------------------------------------------------------------------------------------
-- 11. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.connection_held_kinds_of(uuid,uuid)',
    'cma.set_connection_kind(uuid,text)',
    'cma.reviews_connected_of(uuid)',
    'cma.assert_reviews_connection(uuid)',
    'cma.ingest_upsert_review_channels(uuid,jsonb)',
    'cma.review_order_of(uuid,text)',
    'cma.ingest_upsert_reviews(uuid,jsonb)',
    'cma.set_review_contact(uuid,text,uuid,text)',
    'cma.forget_review_contact_links(uuid,text)',
    'cma.upsert_review_rule(text,text,boolean,boolean,text,text,numeric,integer)',
    'cma.message_rules()',
    'cma.ingest_review_alerts(uuid,text[])',
    'cma.set_review_channel(uuid,text,text,boolean)',
    'cma.connection_catalogs(uuid)',
    'cma.data_quality_reviews_checks()',
    'cma.data_quality_of(uuid)',
    'cma.data_quality()',
    'cma.reviews_of(uuid)',
    'cma.review_market_states_of(uuid)',
    'cma.review_figures(bigint,numeric,bigint,bigint,bigint,bigint)',
    'cma.reviews_page_of(uuid,date,date,text,text,timestamptz)',
    'cma.reviews_page(date,date,text,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 12. Reporting views
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.review_channel as
  select id, tenant_id, connection_id, source_id, name, locale, market, is_counted, first_seen_at, source_deleted_at, updated_at
  from cma.review_channel
  where cma_read.reader_sees(tenant_id);

-- Every column but raw: ids, codes, the rating, times and the link (an order's id, a contact's id)
create or replace view cma_read.review as
  select id, tenant_id, connection_id, review_channel_id, source_system, source_id, review_type, state, is_published, rating,
         submitted_at, source_updated_at, has_reply, invite_event_type, transaction_ref, link_level, commerce_order_id,
         crm_connection_id, crm_contact_source_id, matched_at, synced_at
  from cma.review
  where cma_read.reader_sees(tenant_id);

-- The counted reviews of every tenant the reader sees (cma.reviews_of), for the aggregate views: SECURITY DEFINER in
-- cma_read, owned by cma_owner, search path pinned, executable by readers only. Ids, codes, ratings and dates only
create or replace function cma_read.review_rows()
returns table (tenant_id uuid, review_id uuid, connection_id uuid, review_channel_id uuid, channel_name text, market text,
               rating numeric, stars integer, is_negative boolean, business_date date, week_start date, link_level text,
               invite_event_type text)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, r.review_id, r.connection_id, r.review_channel_id, r.channel_name, r.market, r.rating, r.stars, r.is_negative,
         r.business_date, r.week_start, r.link_level, r.invite_event_type
  from cma.tenant t
  cross join lateral cma.reviews_of(t.id) r
  where cma_read.reader_sees(t.id)
$$;

create or replace function cma_read.review_market_state_rows()
returns table (tenant_id uuid, market text, name text, state text, channels integer, reviews integer)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, s.market, s.name, s.state, s.channels, s.reviews
  from cma.tenant t
  cross join lateral cma.review_market_states_of(t.id) s
  where cma_read.reader_sees(t.id)
$$;

do $$
declare
  f text;
begin
  foreach f in array array['cma_read.review_rows()', 'cma_read.review_market_state_rows()'] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_readonly', f);
  end loop;
end
$$;

-- Counted reviews per day, ISO week, market and week, channel and week: count, average rating, the distribution by whole
-- star, negative reviews, the link levels, and the previous day's or week's count and average (of the same market or
-- channel)
create or replace view cma_read.reviews_per_day as
  with g as (
    select tenant_id, business_date, count(*)::integer as reviews, round(avg(rating), 2) as average_rating,
           count(*) filter (where stars = 1)::integer as stars_1, count(*) filter (where stars = 2)::integer as stars_2,
           count(*) filter (where stars = 3)::integer as stars_3, count(*) filter (where stars = 4)::integer as stars_4,
           count(*) filter (where stars = 5)::integer as stars_5, count(*) filter (where is_negative)::integer as negative,
           count(*) filter (where link_level = 'order')::integer as linked_order,
           count(*) filter (where link_level = 'contact')::integer as linked_contact,
           count(*) filter (where link_level = 'none')::integer as unlinked
    from cma_read.review_rows()
    group by tenant_id, business_date
  )
  select g.*, p.reviews as previous_reviews, p.average_rating as previous_average_rating
  from g left join g p on p.tenant_id = g.tenant_id and p.business_date = g.business_date - 1;

create or replace view cma_read.reviews_per_week as
  with g as (
    select tenant_id, week_start, count(*)::integer as reviews, round(avg(rating), 2) as average_rating,
           count(*) filter (where stars = 1)::integer as stars_1, count(*) filter (where stars = 2)::integer as stars_2,
           count(*) filter (where stars = 3)::integer as stars_3, count(*) filter (where stars = 4)::integer as stars_4,
           count(*) filter (where stars = 5)::integer as stars_5, count(*) filter (where is_negative)::integer as negative,
           count(*) filter (where link_level = 'order')::integer as linked_order,
           count(*) filter (where link_level = 'contact')::integer as linked_contact,
           count(*) filter (where link_level = 'none')::integer as unlinked
    from cma_read.review_rows()
    group by tenant_id, week_start
  )
  select g.*, p.reviews as previous_reviews, p.average_rating as previous_average_rating
  from g left join g p on p.tenant_id = g.tenant_id and p.week_start = g.week_start - 7;

create or replace view cma_read.reviews_per_market as
  with g as (
    select tenant_id, market, week_start, count(*)::integer as reviews, round(avg(rating), 2) as average_rating,
           count(*) filter (where stars = 1)::integer as stars_1, count(*) filter (where stars = 2)::integer as stars_2,
           count(*) filter (where stars = 3)::integer as stars_3, count(*) filter (where stars = 4)::integer as stars_4,
           count(*) filter (where stars = 5)::integer as stars_5, count(*) filter (where is_negative)::integer as negative,
           count(*) filter (where link_level = 'order')::integer as linked_order,
           count(*) filter (where link_level = 'contact')::integer as linked_contact,
           count(*) filter (where link_level = 'none')::integer as unlinked
    from cma_read.review_rows()
    group by tenant_id, market, week_start
  )
  select g.*, p.reviews as previous_reviews, p.average_rating as previous_average_rating
  from g left join g p on p.tenant_id = g.tenant_id and p.market = g.market and p.week_start = g.week_start - 7;

create or replace view cma_read.reviews_per_channel as
  with g as (
    select tenant_id, review_channel_id, channel_name, market, week_start, count(*)::integer as reviews,
           round(avg(rating), 2) as average_rating,
           count(*) filter (where stars = 1)::integer as stars_1, count(*) filter (where stars = 2)::integer as stars_2,
           count(*) filter (where stars = 3)::integer as stars_3, count(*) filter (where stars = 4)::integer as stars_4,
           count(*) filter (where stars = 5)::integer as stars_5, count(*) filter (where is_negative)::integer as negative,
           count(*) filter (where link_level = 'order')::integer as linked_order,
           count(*) filter (where link_level = 'contact')::integer as linked_contact,
           count(*) filter (where link_level = 'none')::integer as unlinked
    from cma_read.review_rows()
    group by tenant_id, review_channel_id, channel_name, market, week_start
  )
  select g.*, p.reviews as previous_reviews, p.average_rating as previous_average_rating
  from g left join g p on p.tenant_id = g.tenant_id and p.review_channel_id = g.review_channel_id and p.week_start = g.week_start - 7;

create or replace view cma_read.review_market_state as
  select * from cma_read.review_market_state_rows();

-- The two data-quality checks' views, as 0007d's dq_ views (ids and codes only)
create or replace view cma_read.dq_review_channel_unmapped as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'review_channel_unmapped';

create or replace view cma_read.dq_market_without_review_channel as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'market_without_review_channel';

-- ---------------------------------------------------------------------------------------------
-- 13. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zd', 'Reviews: the connection kind reviews; cma.review_channel (source id, name, locale, market and is_counted as configuration, a new channel unmapped and not counted) and cma.review (type, state, published, rating 1 to 5, times, reply, invite event type, transaction reference, the link level order, contact or none with the order, the CRM contact and matched_at, a filtered raw; never a name, an email, a phone, a title or a text); the settings reviews.negative_max_rating and reviews.history_start_date; ingest of the channel catalog and of reviews with a stale guard, the order link by order name then source id and the order''s customer''s contact, the contact found by email in memory, and the CRM''s privacy deletion; the alert trigger review_submitted with max_rating and cma.ingest_review_alerts; review channels on Sources; Reports, Reviews (cma.reviews_page); the data-quality checks review_channel_unmapped and market_without_review_channel; the reader views; sync_run job reviews_poll')
on conflict (version) do nothing;

commit;
reset role;
