-- =============================================================================================
-- 34_telephony.sql: migration 0007a, telephony (intake track I3)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 32_intake_core.sql (0007). Rerunnable, forward-only. Run as your own IAM login, dev first, then
-- prod; then 35_verify_telephony.sql, then 33_verify_intake_core.sql and
-- 31_verify_ingest_crm_records.sql again (unchanged).
--
-- Specification: docs/night-2026-10-10/DESIGN.md §4.2, with §2 (sources), §2.1 (what is never
-- stored) and §6.3 (the keyed hash).
--
-- What it adds
--   telephony calls    cma.telephony_call: the calls of the telephony system (direction, status,
--                      missed reason, started, answered and ended, duration and talk time, the
--                      telephony user and line, archived), the other party only as a keyed hash;
--                      stale guard on source_version_at (the newest event or read time), so events
--                      arriving out of order end in the right state
--   tags               cma.telephony_tag (the tag catalog with is_counted) and
--                      cma.telephony_call_tag (tag history: a row per tagging, closed when the tag
--                      is removed, a new row when it comes back)
--   lines              cma.telephony_number: the company's own lines with their market and
--                      is_counted (configuration)
--   call link          cma.call_link: a telephony call paired with the CRM call that logged it, on
--                      the keyed hash, the direction and at most 120 seconds apart; never rewritten,
--                      a wrong link is retired by cma.unlink_call()
--   privacy deletion   cma.ingest_contact_forget() also clears the hash on linked telephony calls
--
-- Nothing personal is stored (DESIGN §2.1): no names, numbers, comments, recordings or voicemail
-- links. The other party's number exists only as counterpart_hash (HMAC-SHA256 of the E.164
-- number with the tenant's pepper, made by the ingest service); reporting views never show it. A
-- line's digits are the company's own number, not a customer's.
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
    raise exception 'migration 0007 (32_intake_core.sql) must run before 0007a';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Telephony calls
-- ---------------------------------------------------------------------------------------------
-- One row per call of the telephony system. source_version_at is the time of the newest event or
-- read that wrote the row: an older one is stale, so an ended event that arrives before the
-- created event leaves the call ended. talk_seconds is derived (ended - answered, null while
-- unanswered). raw keeps flat, non-personal keys only (see cma.telephony_raw).
create table if not exists cma.telephony_call (
  id                 uuid primary key default uuidv7(),
  tenant_id          uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id      uuid not null,
  source_system      text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_id          text not null check (length(source_id) between 1 and 100),
  direction          text not null check (direction in ('inbound', 'outbound')),
  status             text check (length(status) <= 40),
  missed_reason      text check (length(missed_reason) <= 60),
  started_at         timestamptz,
  answered_at        timestamptz,
  ended_at           timestamptz,
  duration_seconds   integer check (duration_seconds >= 0),
  talk_seconds       integer generated always as (
                       case when answered_at is not null and ended_at is not null
                            then greatest(0, floor(extract(epoch from ended_at - answered_at)))::integer end) stored,
  user_ref           text check (length(user_ref) <= 100),
  number_ref         text check (length(number_ref) <= 100),
  counterpart_hash   text check (counterpart_hash ~ '^[0-9a-f]{64}$'),
  is_archived        boolean not null default false,
  source_version_at  timestamptz not null,
  source_deleted_at  timestamptz,
  synced_at          timestamptz not null default now(),
  raw                jsonb not null default '{}'::jsonb check (jsonb_typeof(raw) = 'object'),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.telephony_call is 'Calls of the telephony system: direction, status, times, duration and talk time, user and line; the other party only as a keyed hash. Stale guard on source_version_at. Owned by the telephony system';
comment on column cma.telephony_call.source_version_at is 'Time of the newest event or read that wrote this row; an older one is stale';
comment on column cma.telephony_call.counterpart_hash is 'HMAC-SHA256(tenant pepper, E.164 number of the other party) in hex, made by the ingest service; links to a CRM call only';
create index if not exists telephony_call_started_idx on cma.telephony_call (tenant_id, started_at);
create index if not exists telephony_call_hash_idx on cma.telephony_call (tenant_id, counterpart_hash) where counterpart_hash is not null;

-- ---------------------------------------------------------------------------------------------
-- 2. Tags: the catalog and the history per call
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.telephony_tag (
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id  uuid not null,
  tag_ref        text not null check (length(tag_ref) between 1 and 100),
  name           text not null check (length(name) between 1 and 100),
  is_counted     boolean not null default true,
  status         text not null default 'active' check (status in ('active', 'archived')),
  refreshed_at   timestamptz,
  updated_at     timestamptz not null default now(),
  primary key (tenant_id, connection_id, tag_ref),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.telephony_tag is 'Tags of the telephony system per connection; is_counted (configuration) says which count in reporting; name and status from the source';
create or replace trigger set_updated_at before update on cma.telephony_tag
  for each row execute function cma.set_updated_at();

-- A row per tagging: tagged_at is the call's source_version_at when the tag first appeared in its
-- tag set, untagged_at the one when it disappeared (null while current). A tag that comes back gets
-- a new row, so the history stays.
create table if not exists cma.telephony_call_tag (
  tenant_id       uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id   uuid not null,
  call_source_id  text not null,
  tag_ref         text not null,
  tagged_at       timestamptz not null,
  untagged_at     timestamptz,
  primary key (tenant_id, connection_id, call_source_id, tag_ref, tagged_at),
  check (untagged_at >= tagged_at),
  foreign key (tenant_id, connection_id, call_source_id) references cma.telephony_call (tenant_id, connection_id, source_id),
  foreign key (tenant_id, connection_id, tag_ref) references cma.telephony_tag (tenant_id, connection_id, tag_ref)
);
comment on table cma.telephony_call_tag is 'Tag history per telephony call: tagged_at and untagged_at (null while the tag is current), at the call''s source_version_at';
create unique index if not exists telephony_call_tag_current_idx
  on cma.telephony_call_tag (tenant_id, connection_id, call_source_id, tag_ref) where untagged_at is null;
create index if not exists telephony_call_tag_tag_idx on cma.telephony_call_tag (tenant_id, connection_id, tag_ref, tagged_at);

-- A tagging only closes, once, and nothing else about it changes
create or replace function cma.check_telephony_call_tag()
returns trigger
language plpgsql
as $$
begin
  if old.untagged_at is not null then
    raise exception 'tag % of call % is already closed', old.tag_ref, old.call_source_id using errcode = 'CMA03';
  end if;
  if (new.tenant_id, new.connection_id, new.call_source_id, new.tag_ref, new.tagged_at)
     is distinct from (old.tenant_id, old.connection_id, old.call_source_id, old.tag_ref, old.tagged_at) then
    raise exception 'only the end of a tagging changes' using errcode = 'CMA04';
  end if;
  return new;
end
$$;
revoke execute on function cma.check_telephony_call_tag() from public;
create or replace trigger check_close_once before update on cma.telephony_call_tag
  for each row execute function cma.check_telephony_call_tag();

-- ---------------------------------------------------------------------------------------------
-- 3. Lines
-- ---------------------------------------------------------------------------------------------
-- The company's own lines (not customer numbers): name and E.164 digits from the source, market and
-- is_counted as configuration.
create table if not exists cma.telephony_number (
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id  uuid not null,
  number_ref     text not null check (length(number_ref) between 1 and 100),
  name           text not null check (length(name) between 1 and 100),
  digits         text check (digits ~ '^\+[1-9][0-9]{6,14}$'),
  market         text check (market ~ '^[A-Z]{2}$'),
  is_counted     boolean not null default true,
  status         text not null default 'active' check (status in ('active', 'archived')),
  refreshed_at   timestamptz,
  updated_at     timestamptz not null default now(),
  primary key (tenant_id, connection_id, number_ref),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.telephony_number is 'The company''s own telephony lines per connection: name and E.164 digits from the source; market and is_counted (configuration)';
create or replace trigger set_updated_at before update on cma.telephony_number
  for each row execute function cma.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- 4. The call link
-- ---------------------------------------------------------------------------------------------
-- A telephony call and the CRM call that logged it, paired by cma.link_calls(): equal non-null
-- hash, the same direction, at most 120 seconds apart, nearest first, each side once. Never
-- rewritten: a wrong link is retired (unlinked_at, unlinked_by) and that pair is never linked
-- again. delta_seconds = telephony started_at - CRM occurred_at.
create table if not exists cma.call_link (
  id                 uuid primary key default uuidv7(),
  tenant_id          uuid not null default cma.current_tenant_id() references cma.tenant (id),
  telephony_call_id  uuid not null,
  crm_call_id        uuid not null,
  method             text not null check (method in ('hash_time')),
  delta_seconds      integer not null check (abs(delta_seconds) <= 86400),
  linked_at          timestamptz not null default now(),
  linked_by          uuid default cma.current_user_id(),
  unlinked_at        timestamptz,
  unlinked_by        uuid,
  unique (tenant_id, id),
  check ((unlinked_at is null) = (unlinked_by is null)),
  foreign key (tenant_id, telephony_call_id) references cma.telephony_call (tenant_id, id),
  foreign key (tenant_id, crm_call_id) references cma.crm_call (tenant_id, id),
  foreign key (tenant_id, linked_by) references cma.app_user (tenant_id, id),
  foreign key (tenant_id, unlinked_by) references cma.app_user (tenant_id, id)
);
comment on table cma.call_link is 'A telephony call paired with the CRM call that logged it (keyed hash, direction, 120 s). Never rewritten; a wrong link is retired by cma.unlink_call()';
create unique index if not exists call_link_telephony_idx on cma.call_link (tenant_id, telephony_call_id) where unlinked_at is null;
create unique index if not exists call_link_crm_idx on cma.call_link (tenant_id, crm_call_id) where unlinked_at is null;
create index if not exists call_link_pair_idx on cma.call_link (tenant_id, telephony_call_id, crm_call_id);

-- A link only retires, once, and nothing else about it changes
create or replace function cma.check_call_link()
returns trigger
language plpgsql
as $$
begin
  if old.unlinked_at is not null then
    raise exception 'call link % is already retired', old.id using errcode = 'CMA03';
  end if;
  if (new.id, new.tenant_id, new.telephony_call_id, new.crm_call_id, new.method, new.delta_seconds, new.linked_at, new.linked_by)
     is distinct from (old.id, old.tenant_id, old.telephony_call_id, old.crm_call_id, old.method, old.delta_seconds, old.linked_at, old.linked_by) then
    raise exception 'a call link is never rewritten, only retired' using errcode = 'CMA04';
  end if;
  return new;
end
$$;
revoke execute on function cma.check_call_link() from public;
create or replace trigger check_retire_once before update on cma.call_link
  for each row execute function cma.check_call_link();

-- ---------------------------------------------------------------------------------------------
-- 5. Row-level security, audit and privileges
-- ---------------------------------------------------------------------------------------------
select cma.setup_tenant_table('cma.telephony_call');
select cma.setup_tenant_table('cma.telephony_tag');
select cma.setup_tenant_table('cma.telephony_call_tag');
select cma.setup_tenant_table('cma.telephony_number');
select cma.setup_tenant_table('cma.call_link');

-- The application never deletes from these tables. A tagging changes only in its end; a link only
-- in its retirement.
revoke delete on cma.telephony_call, cma.telephony_tag, cma.telephony_call_tag, cma.telephony_number, cma.call_link from cma_app;
revoke update on cma.telephony_call_tag from cma_app;
grant update (untagged_at) on cma.telephony_call_tag to cma_app;
revoke update on cma.call_link from cma_app;
grant update (unlinked_at, unlinked_by) on cma.call_link to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 6. Internal helpers
-- ---------------------------------------------------------------------------------------------
-- The raw payload as stored: a flat object of at most 50 keys whose values are numbers, booleans
-- or strings of at most 200 characters. Dropped: nested objects and arrays (the other party, the
-- user, the line, tags, comments), keys that name personal or free-text data (digits, phone,
-- number, email, name, comment, note, recording, voicemail, asset, contact, address, body, content,
-- link, url, transcript, summary) and strings that look like a phone number. The ingest service
-- sends an allowlist; this is the second line.
create or replace function cma.telephony_raw(p_raw jsonb)
returns jsonb
language sql immutable
as $$
  select coalesce((
    select jsonb_object_agg(e.key, e.value)
    from (select e.key, e.value
          from jsonb_each(case when jsonb_typeof(p_raw) = 'object' then p_raw else '{}'::jsonb end) e
          where e.key ~ '^[A-Za-z0-9_.-]{1,60}$'
            and e.key !~* '(digit|phone|number|e164|email|mail|name|comment|note|record|voicemail|asset|contact|address|body|content|link|url|transcript|summary)'
            and (jsonb_typeof(e.value) in ('number', 'boolean')
                 or (jsonb_typeof(e.value) = 'string'
                     and length(e.value #>> '{}') <= 200
                     and not ((e.value #>> '{}') ~ '^\+?[0-9 ().-]{7,20}$' and (e.value #>> '{}') !~ '^\d{4}-\d{2}-\d{2}')))
          order by e.key
          limit 50) e), '{}'::jsonb)
$$;
revoke execute on function cma.telephony_raw(jsonb) from public;

-- A tag reference from a call's tag set: a string or {tagRef, name}
create or replace function cma.telephony_tag_ref(p_tag jsonb)
returns text
language sql immutable
as $$
  select nullif(btrim(case when jsonb_typeof(p_tag) = 'object' then p_tag ->> 'tagRef'
                           when jsonb_typeof(p_tag) in ('string', 'number') then p_tag #>> '{}' end), '')
$$;
revoke execute on function cma.telephony_tag_ref(jsonb) from public;

-- ---------------------------------------------------------------------------------------------
-- 7. The ingest write path (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- Upserts telephony calls as the source answered them, at most 500:
--   [{sourceId, direction, status, missedReason, startedAt, answeredAt, endedAt, durationSeconds,
--     userRef, numberRef, counterpartHash, isArchived, versionAt, deletedAt?, tags?, raw?}]
-- versionAt (the event's or the read's time) is the stale guard: a call older than the stored
-- version is stale and changes nothing. tags, when present, is the call's whole current tag set
-- (tag refs, or {tagRef, name}): tags no longer in it are closed and new ones opened, both at
-- versionAt; an absent tags key leaves the tags as they are, an empty list closes them all. A tag
-- not yet in the catalog joins it, counted, with its name or its ref. A deleted call keeps its id,
-- times and tags and loses its hash and raw payload. Outcomes: inserted, updated, stale, deleted,
-- unknown (a deletion of a call never seen).
create or replace function cma.ingest_upsert_telephony_calls(p_connection_id uuid, p_calls jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  c          jsonb;
  v_src      text;
  v_version  timestamptz;
  v_deleted  timestamptz;
  v_old      cma.telephony_call;
  v_dir      text;
  v_tags     text[];
  t          jsonb;
  v_ref      text;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if p_calls is null or jsonb_typeof(p_calls) <> 'array' or jsonb_array_length(p_calls) > 500 then
    raise exception 'calls must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for c in select value from jsonb_array_elements(p_calls) loop
    v_src := btrim(c ->> 'sourceId');
    if coalesce(v_src, '') = '' then
      raise exception 'every call needs a sourceId' using errcode = 'CMA04';
    end if;
    v_version := cma.json_time(c -> 'versionAt', 'versionAt');
    v_deleted := cma.json_time(c -> 'deletedAt', 'deletedAt');
    select * into v_old from cma.telephony_call tc
    where tc.tenant_id = v_tenant and tc.connection_id = p_connection_id and tc.source_id = v_src
    for update;

    if v_deleted is not null then
      if v_old.id is null then
        return query select v_src, 'unknown'::text;
      else
        update cma.telephony_call tc
           set source_deleted_at = v_deleted, counterpart_hash = null, raw = '{}'::jsonb, synced_at = now(),
               source_version_at = greatest(tc.source_version_at, coalesce(v_version, tc.source_version_at))
         where tc.tenant_id = v_tenant and tc.id = v_old.id;
        return query select v_src, 'deleted'::text;
      end if;
      continue;
    end if;

    if v_version is null then
      raise exception 'every call needs a versionAt (the time of its event or read)' using errcode = 'CMA04';
    end if;
    if v_old.id is not null and v_version < v_old.source_version_at then
      return query select v_src, 'stale'::text;
      continue;
    end if;

    v_dir := lower(btrim(c ->> 'direction'));
    if v_dir is null or v_dir not in ('inbound', 'outbound') then
      raise exception 'direction must be inbound or outbound, got %', c ->> 'direction' using errcode = 'CMA04';
    end if;
    if c ? 'isArchived' and jsonb_typeof(c -> 'isArchived') not in ('boolean', 'null') then
      raise exception 'isArchived must be true or false' using errcode = 'CMA04';
    end if;
    if c ? 'tags' and jsonb_typeof(c -> 'tags') not in ('array', 'null') then
      raise exception 'tags must be a list of tag refs' using errcode = 'CMA04';
    end if;

    if v_old.id is null then
      insert into cma.telephony_call (tenant_id, connection_id, source_system, source_id, direction, status, missed_reason,
                                      started_at, answered_at, ended_at, duration_seconds, user_ref, number_ref,
                                      counterpart_hash, is_archived, source_version_at, raw)
      values (v_tenant, p_connection_id, v_system, v_src, v_dir, nullif(btrim(c ->> 'status'), ''),
              nullif(btrim(c ->> 'missedReason'), ''),
              cma.json_time(c -> 'startedAt', 'startedAt'), cma.json_time(c -> 'answeredAt', 'answeredAt'),
              cma.json_time(c -> 'endedAt', 'endedAt'), (c ->> 'durationSeconds')::integer,
              nullif(btrim(c ->> 'userRef'), ''), nullif(btrim(c ->> 'numberRef'), ''),
              nullif(lower(btrim(c ->> 'counterpartHash')), ''), coalesce((c ->> 'isArchived')::boolean, false),
              v_version, cma.telephony_raw(c -> 'raw'));
    else
      update cma.telephony_call tc
         set direction = v_dir,
             status = nullif(btrim(c ->> 'status'), ''),
             missed_reason = nullif(btrim(c ->> 'missedReason'), ''),
             started_at = cma.json_time(c -> 'startedAt', 'startedAt'),
             answered_at = cma.json_time(c -> 'answeredAt', 'answeredAt'),
             ended_at = cma.json_time(c -> 'endedAt', 'endedAt'),
             duration_seconds = (c ->> 'durationSeconds')::integer,
             user_ref = nullif(btrim(c ->> 'userRef'), ''),
             number_ref = nullif(btrim(c ->> 'numberRef'), ''),
             counterpart_hash = nullif(lower(btrim(c ->> 'counterpartHash')), ''),
             is_archived = coalesce((c ->> 'isArchived')::boolean, false),
             source_version_at = v_version,
             source_deleted_at = null,
             synced_at = now(),
             raw = cma.telephony_raw(c -> 'raw')
       where tc.tenant_id = v_tenant and tc.id = v_old.id;
    end if;

    -- the tag set, by difference at versionAt
    if jsonb_typeof(c -> 'tags') = 'array' then
      if jsonb_array_length(c -> 'tags') > 50 then
        raise exception 'at most 50 tags per call' using errcode = 'CMA04';
      end if;
      v_tags := '{}';
      for t in select value from jsonb_array_elements(c -> 'tags') loop
        v_ref := cma.telephony_tag_ref(t);
        if v_ref is null or length(v_ref) > 100 then
          raise exception 'every tag needs a tagRef of 1 to 100 characters' using errcode = 'CMA04';
        end if;
        insert into cma.telephony_tag (tenant_id, connection_id, tag_ref, name)
        values (v_tenant, p_connection_id, v_ref,
                left(coalesce(nullif(btrim(case when jsonb_typeof(t) = 'object' then t ->> 'name' end), ''), v_ref), 100))
        on conflict (tenant_id, connection_id, tag_ref) do nothing;
        v_tags := array_append(v_tags, v_ref);
      end loop;
      update cma.telephony_call_tag ct set untagged_at = v_version
      where ct.tenant_id = v_tenant and ct.connection_id = p_connection_id and ct.call_source_id = v_src
        and ct.untagged_at is null and not (ct.tag_ref = any (v_tags));
      insert into cma.telephony_call_tag (tenant_id, connection_id, call_source_id, tag_ref, tagged_at)
      select distinct v_tenant, p_connection_id, v_src, x.ref, v_version
      from unnest(v_tags) x(ref)
      where not exists (select 1 from cma.telephony_call_tag ct
                        where ct.tenant_id = v_tenant and ct.connection_id = p_connection_id and ct.call_source_id = v_src
                          and ct.tag_ref = x.ref and ct.untagged_at is null);
    end if;
    return query select v_src, case when v_old.id is null then 'inserted' else 'updated' end;
  end loop;
exception
  when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range or unique_violation then
    raise exception 'invalid telephony call: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Refreshes a catalog of the telephony system. p_kind 'tag': [{tagRef, name}]; 'number':
-- [{numberRef, name, digits}] (digits in E.164; anything else is left empty). The configured
-- columns (is_counted; market) stay; an entry missing from the list is archived. Answers the number
-- of active entries.
create or replace function cma.ingest_upsert_telephony_catalog(p_connection_id uuid, p_kind text, p_items jsonb)
returns integer
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  i        jsonb;
  v_ref    text;
  v_digits text;
  v_n      integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_kind is null or p_kind not in ('tag', 'number') then
    raise exception 'the catalog kind is tag or number, got %', p_kind using errcode = 'CMA04';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'catalog entries must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for i in select value from jsonb_array_elements(p_items) loop
    v_ref := nullif(btrim(i ->> case p_kind when 'tag' then 'tagRef' else 'numberRef' end), '');
    if v_ref is null then
      raise exception 'every % needs its %', p_kind, case p_kind when 'tag' then 'tagRef' else 'numberRef' end using errcode = 'CMA04';
    end if;
    if p_kind = 'tag' then
      insert into cma.telephony_tag (tenant_id, connection_id, tag_ref, name, status, refreshed_at)
      values (v_tenant, p_connection_id, v_ref, left(coalesce(nullif(btrim(i ->> 'name'), ''), v_ref), 100), 'active', now())
      on conflict (tenant_id, connection_id, tag_ref)
        do update set name = excluded.name, status = 'active', refreshed_at = now();
    else
      v_digits := regexp_replace(coalesce(i ->> 'digits', ''), '[\s().-]', '', 'g');
      if v_digits !~ '^\+[1-9][0-9]{6,14}$' then
        v_digits := null;
      end if;
      insert into cma.telephony_number (tenant_id, connection_id, number_ref, name, digits, status, refreshed_at)
      values (v_tenant, p_connection_id, v_ref, left(coalesce(nullif(btrim(i ->> 'name'), ''), v_ref), 100), v_digits, 'active', now())
      on conflict (tenant_id, connection_id, number_ref)
        do update set name = excluded.name, digits = excluded.digits, status = 'active', refreshed_at = now();
    end if;
  end loop;
  if p_kind = 'tag' then
    update cma.telephony_tag g set status = 'archived'
    where g.tenant_id = v_tenant and g.connection_id = p_connection_id and g.status = 'active'
      and not exists (select 1 from jsonb_array_elements(p_items) x where btrim(x ->> 'tagRef') = g.tag_ref);
    select count(*)::integer into v_n from cma.telephony_tag g
    where g.tenant_id = v_tenant and g.connection_id = p_connection_id and g.status = 'active';
  else
    update cma.telephony_number n set status = 'archived'
    where n.tenant_id = v_tenant and n.connection_id = p_connection_id and n.status = 'active'
      and not exists (select 1 from jsonb_array_elements(p_items) x where btrim(x ->> 'numberRef') = n.number_ref);
    select count(*)::integer into v_n from cma.telephony_number n
    where n.tenant_id = v_tenant and n.connection_id = p_connection_id and n.status = 'active';
  end if;
  return v_n;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid % catalog: %', p_kind, sqlerrm using errcode = 'CMA04';
end
$$;

-- Pairs telephony calls started at or after p_since with CRM calls of the same tenant: equal
-- non-null counterpart_hash, the same direction, |started_at - occurred_at| <= 120 seconds, neither
-- side deleted or already linked, and never a pair whose link was retired. Nearest first, each side
-- once (the partial unique indexes decide, so two runs at once cannot link a side twice). Answers
-- the number of links made. ingest.write (the sweep) or tenant.configure.
create or replace function cma.link_calls(p_since timestamptz)
returns integer
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  p        record;
  v_rows   integer;
  v_n      integer := 0;
begin
  perform cma.assert_any_permission(array['ingest.write', 'tenant.configure']);
  if p_since is null then
    raise exception 'link_calls needs a start time' using errcode = 'CMA04';
  end if;
  for p in
    select t.id as telephony_call_id, k.id as crm_call_id,
           round(extract(epoch from t.started_at - k.occurred_at))::integer as delta
    from cma.telephony_call t
    join cma.crm_call k
      on k.tenant_id = t.tenant_id
     and k.counterpart_hash = t.counterpart_hash
     and k.direction = t.direction
     and k.occurred_at between t.started_at - interval '120 seconds' and t.started_at + interval '120 seconds'
     and k.source_deleted_at is null
    where t.tenant_id = v_tenant
      and t.started_at >= p_since
      and t.counterpart_hash is not null
      and t.source_deleted_at is null
      and not exists (select 1 from cma.call_link l
                      where l.tenant_id = v_tenant and l.unlinked_at is null
                        and (l.telephony_call_id = t.id or l.crm_call_id = k.id))
      and not exists (select 1 from cma.call_link l
                      where l.tenant_id = v_tenant and l.telephony_call_id = t.id and l.crm_call_id = k.id)
    order by abs(extract(epoch from t.started_at - k.occurred_at)), t.started_at, t.id, k.id
  loop
    insert into cma.call_link (tenant_id, telephony_call_id, crm_call_id, method, delta_seconds)
    values (v_tenant, p.telephony_call_id, p.crm_call_id, 'hash_time', p.delta)
    on conflict do nothing;
    get diagnostics v_rows = row_count;
    v_n := v_n + v_rows;
  end loop;
  return v_n;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Configuration (tenant.configure)
-- ---------------------------------------------------------------------------------------------
-- A line's market (null clears it) and whether its calls count. A line not yet read from the source
-- is added with its ref as name.
create or replace function cma.set_telephony_number(p_connection_id uuid, p_number_ref text, p_market text, p_is_counted boolean)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_is_counted is null then
    raise exception 'is_counted must be true or false' using errcode = 'CMA04';
  end if;
  if p_market is not null then
    perform cma.assert_market(p_market, false);
  end if;
  insert into cma.telephony_number (tenant_id, connection_id, number_ref, name, market, is_counted)
  values (cma.current_tenant_id(), p_connection_id, btrim(p_number_ref), left(btrim(p_number_ref), 100), p_market, p_is_counted)
  on conflict (tenant_id, connection_id, number_ref) do update
    set market = excluded.market, is_counted = excluded.is_counted;
exception when check_violation or not_null_violation then
  raise exception 'invalid line: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Whether calls with a tag count. A tag not yet read from the source is added with its ref as name.
create or replace function cma.set_telephony_tag(p_connection_id uuid, p_tag_ref text, p_is_counted boolean)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_is_counted is null then
    raise exception 'is_counted must be true or false' using errcode = 'CMA04';
  end if;
  insert into cma.telephony_tag (tenant_id, connection_id, tag_ref, name, is_counted)
  values (cma.current_tenant_id(), p_connection_id, btrim(p_tag_ref), left(btrim(p_tag_ref), 100), p_is_counted)
  on conflict (tenant_id, connection_id, tag_ref) do update set is_counted = excluded.is_counted;
exception when check_violation or not_null_violation then
  raise exception 'invalid tag: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Retires a wrong link, recording the person. The pair is never linked again; both calls may be
-- linked to another candidate by the next cma.link_calls().
create or replace function cma.unlink_call(p_link_id uuid)
returns void
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_retired timestamptz;
begin
  perform cma.assert_permission('tenant.configure');
  select l.unlinked_at into v_retired from cma.call_link l where l.tenant_id = v_tenant and l.id = p_link_id for update;
  if not found then
    raise exception 'no call link % in the current tenant', p_link_id using errcode = 'CMA02';
  end if;
  if v_retired is not null then
    raise exception 'call link % is already retired', p_link_id using errcode = 'CMA03';
  end if;
  update cma.call_link l set unlinked_at = now(), unlinked_by = cma.current_user_id()
  where l.tenant_id = v_tenant and l.id = p_link_id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. The privacy deletion, redefined
-- ---------------------------------------------------------------------------------------------
-- As 0007, and the hash is also cleared on telephony calls linked (now or formerly) to the
-- contact's CRM calls. Answers {contacts, refs, calls, submissions}, plus telephony_calls when a
-- telephony hash was cleared (0007's answer shape stays as it was otherwise).
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
  v_res := jsonb_build_object('contacts', v_c, 'refs', v_r, 'calls', v_k, 'submissions', v_s);
  if v_t > 0 then
    v_res := v_res || jsonb_build_object('telephony_calls', v_t);
  end if;
  return v_res;
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
    'cma.ingest_upsert_telephony_calls(uuid,jsonb)',
    'cma.ingest_upsert_telephony_catalog(uuid,text,jsonb)',
    'cma.link_calls(timestamptz)',
    'cma.set_telephony_number(uuid,text,text,boolean)',
    'cma.set_telephony_tag(uuid,text,boolean)',
    'cma.unlink_call(uuid)',
    'cma.ingest_contact_forget(uuid,text)',
    -- helpers the functions above call in the caller's rights
    'cma.telephony_raw(jsonb)',
    'cma.telephony_tag_ref(jsonb)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 11. Reporting views (no raw payloads, no hashes)
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.telephony_call as
  select id, tenant_id, connection_id, source_system, source_id, direction, status, missed_reason, started_at, answered_at,
         ended_at, duration_seconds, talk_seconds, user_ref, number_ref, is_archived, source_version_at, source_deleted_at,
         synced_at
  from cma.telephony_call
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.telephony_call_tag as
  select tenant_id, connection_id, call_source_id, tag_ref, tagged_at, untagged_at
  from cma.telephony_call_tag
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.telephony_tag as
  select tenant_id, connection_id, tag_ref, name, is_counted, status, refreshed_at
  from cma.telephony_tag
  where cma_read.reader_sees(tenant_id);

-- digits is the company's own line, not a customer number
create or replace view cma_read.telephony_number as
  select tenant_id, connection_id, number_ref, name, digits, market, is_counted, status, refreshed_at
  from cma.telephony_number
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.call_link as
  select id, tenant_id, telephony_call_id, crm_call_id, method, delta_seconds, linked_at, unlinked_at
  from cma.call_link
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 12. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0007a', 'Telephony: calls with a stale guard on the source version, tags with history, lines with market, the keyed-hash call link to CRM calls, contact forget clearing linked telephony hashes')
on conflict (version) do nothing;

reset role;
