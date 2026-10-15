-- =============================================================================================
-- 66_invitations.sql: addition 0008l, invitations by email
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 64_calls_history_start.sql (0008k). Rerunnable, forward-only, in one transaction. Run as your own
-- IAM login, dev first, then prod; then 67_verify_invitations.sql (dev), then 63_verify_calls_overview.sql
-- (dev) and 65_verify_calls_history_start.sql (dev) again.
--
-- Backlog CMA-018 (README Decision log, 15 October 2026): a person who may add people invites someone
-- by work email with a chosen role, instead of asking for their account id. The invitee opens the
-- link, signs in, accepts, and is set up with the role, employer, teams and skills the inviter chose.
-- Matching stays on the sign-in account id: the invitation binds that id at acceptance, and only when
-- the address the sign-in provider verified equals the invited one. Add a person by account id stays
-- as it is. The CMA sends no email itself: the inviter sends the link from their own mail client.
--
-- What it adds
--   settings            auth.invitation_valid_days (default 7, 1 to 30) and
--                       auth.invitation_email_domains (comma-separated domains; default empty: any)
--   cma.invitation      one row per invitation, never deleted: address, name, language, role,
--                       employer, teams, skills with levels, the token's hash, who invited and when,
--                       expiry, acceptance (when, which person), renewal and revocation (when, who).
--                       Row-level security and audit through setup_tenant_table; the application may
--                       not read the hash, and the audit log keeps every image without it
--   cma.create_invitation()   the token returned once; refuses what Add a person refuses, the system
--                       role, an address that is a person already, a pending invitation for the
--                       address (renew it) and an address outside the domain setting
--   cma.renew_invitation(), cma.revoke_invitation(), cma.invitations()
--   cma.invitation_preview(), cma.accept_invitation()   SECURITY DEFINER, owned by cma_owner, with a
--                       pinned search path, executable by the application without a tenant context:
--                       they find the invitation by the token's hash and act on its tenant only; a
--                       sign-in that already works in another tenant is refused (other_tenant), because
--                       two tenants for one sign-in is "no access yet" until a tenant picker exists
--
-- The token: 32 bytes as 43 url-safe base64 characters, returned once by create and renew; only its
-- SHA-256 is stored, unique across tenants. The 32 bytes are the SHA-256 of three gen_random_uuid()
-- values (366 random bits from the server's strong random source): gen_random_bytes() needs the
-- pgcrypto extension, which an IAM login acting as cma_owner cannot create on Cloud SQL (README
-- Decision log, 15 October 2026).
--
-- Acceptance acts as the inviter (app.user_id = the person who issued the current link, app.actor_label
-- = invitation), through cma.add_person(), cma.set_person_teams() and cma.set_person_skills(), so the
-- inviter's permission and role ceiling are checked again at that moment and the audit names them.
-- A function that runs as cma_owner passes the protect_system trigger, so the system role is refused
-- here explicitly, at creation, renewal and acceptance.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted. No message carries an address or a token.
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
  if not exists (select 1 from cma.schema_migration where version = '0008k') then
    raise exception 'addition 0008k (64_calls_history_start.sql) must run before 0008l';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('auth.invitation_valid_days',    'integer', null, '7',
     'Days an invitation link stays valid, 1 to 30; a new link starts the days again'),
  ('auth.invitation_email_domains', 'text',    null, '',
     'Email domains invitations may go to, comma-separated (example.com,example.org); empty means any domain')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- One domain name, lower case: labels of letters, digits and hyphens, at least two
create or replace function cma.is_domain_list(p_value text)
returns boolean
language sql immutable
as $$
  select p_value = ''
      or (length(p_value) <= 500
          and p_value ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(,([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$')
$$;

-- As 0008b, plus the two invitation settings: whole days from 1 to 30, and a domain list written in
-- lower case without spaces (an empty list is no domain check)
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
  if s.value_type = 'boolean' and new.value not in ('true', 'false') then
    raise exception 'Setting % takes true or false', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'integer' and new.value !~ '^-?[0-9]+$' then
    raise exception 'Setting % takes a whole number', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'date' then
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
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;
revoke execute on function cma.check_tenant_setting() from public;

-- ---------------------------------------------------------------------------------------------
-- 2. The table
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.invitation (
  id                uuid primary key default uuidv7(),
  tenant_id         uuid not null default cma.current_tenant_id() references cma.tenant (id),
  email             text not null check (email = lower(email) and length(email) <= 200
                                         and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  display_name      text not null check (display_name = btrim(display_name) and length(display_name) between 1 and 100),
  locale            text not null check (locale ~ '^[a-z]{2}$'),
  role_id           uuid not null,
  organisation_id   uuid not null,
  team_ids          uuid[] not null default '{}',
  skills            jsonb not null default '[]' check (jsonb_typeof(skills) = 'array'),
  token_hash        text not null check (token_hash ~ '^[0-9a-f]{64}$'),
  created_by        uuid not null,
  created_at        timestamptz not null default now(),
  expires_at        timestamptz not null,
  renewed_at        timestamptz,
  renewed_by        uuid,
  accepted_at       timestamptz,
  accepted_user_id  uuid,
  revoked_at        timestamptz,
  revoked_by        uuid,
  check (expires_at > created_at),
  check ((renewed_at is null) = (renewed_by is null)),
  check ((accepted_at is null) = (accepted_user_id is null)),
  check ((revoked_at is null) = (revoked_by is null)),
  check (accepted_at is null or revoked_at is null),
  unique (tenant_id, id),
  foreign key (tenant_id, role_id)          references cma.app_role (tenant_id, id),
  foreign key (tenant_id, organisation_id)  references cma.organisation (tenant_id, id),
  foreign key (tenant_id, created_by)       references cma.app_user (tenant_id, id),
  foreign key (tenant_id, renewed_by)       references cma.app_user (tenant_id, id),
  foreign key (tenant_id, accepted_user_id) references cma.app_user (tenant_id, id),
  foreign key (tenant_id, revoked_by)       references cma.app_user (tenant_id, id)
);
comment on table cma.invitation is 'An invitation by email to join a tenant with a role, employer, teams and skills; the link''s token is stored only as its SHA-256. Never deleted: accepted, revoked and expired rows stay';
comment on column cma.invitation.token_hash is 'SHA-256 (hex) of the url-safe token the link carries; unique across tenants, read only by the owner''s functions; never in the audit log';
comment on column cma.invitation.skills is 'The skills chosen, as [{ "skill_id": uuid, "level": n or null }], validated against the scale at creation';
-- the lookup by hash, across tenants
create unique index if not exists invitation_token_hash_idx on cma.invitation (token_hash);
-- one pending invitation per address and tenant: an open or expired one is renewed or revoked, not duplicated
create unique index if not exists invitation_pending_email_idx on cma.invitation (tenant_id, email)
  where accepted_at is null and revoked_at is null;
create index if not exists invitation_created_idx on cma.invitation (tenant_id, created_at);

select cma.setup_tenant_table('cma.invitation');
-- The application never deletes, never reads the hash and changes only what renewal and revocation
-- change; acceptance runs in the owner's function
revoke select, update, delete on cma.invitation from cma_app;
grant select (id, tenant_id, email, display_name, locale, role_id, organisation_id, team_ids, skills, created_by,
              created_at, expires_at, renewed_at, renewed_by, accepted_at, accepted_user_id, revoked_at, revoked_by)
  on cma.invitation to cma_app;
grant update (token_hash, expires_at, renewed_at, renewed_by, revoked_at, revoked_by) on cma.invitation to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 3. The audit trigger: never the token's hash
-- ---------------------------------------------------------------------------------------------
-- As 0008f, plus: a change on cma.invitation keeps its images without token_hash, so neither the
-- application (which reads its tenant's audit rows) nor a reader (cma_read.audit_log) sees a hash.
create or replace function cma.audit_row()
returns trigger
language plpgsql
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
begin
  if tg_op = 'DELETE' and tg_table_schema = 'cma'
     and tg_table_name in ('telephony_call', 'telephony_call_tag', 'call_link')
     and coalesce(current_setting('cma.audit_keys_only', true), '') = 'uncounted_line' then
    v_old := jsonb_strip_nulls(jsonb_build_object(
      'id', v_old -> 'id', 'tenant_id', v_old -> 'tenant_id', 'connection_id', v_old -> 'connection_id',
      'source_id', v_old -> 'source_id', 'call_source_id', v_old -> 'call_source_id', 'tag_ref', v_old -> 'tag_ref',
      'telephony_call_id', v_old -> 'telephony_call_id', 'crm_call_id', v_old -> 'crm_call_id',
      'reason', 'uncounted_line'));
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'invitation' then
    v_old := v_old - 'token_hash';
    v_new := v_new - 'token_hash';
  end if;
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  values (
    (coalesce(v_new, v_old) ->> 'tenant_id')::uuid,
    tg_table_name,
    lower(tg_op),
    v_old,
    v_new,
    cma.current_user_id(),
    cma.current_actor_label()
  );
  return null;   -- after trigger, return value is ignored
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Helpers (the owner's; not executable by the application)
-- ---------------------------------------------------------------------------------------------
-- A new token: 32 bytes, url-safe base64 without padding (43 characters)
create or replace function cma.invitation_new_token()
returns text
language sql volatile
as $$
  select translate(rtrim(encode(sha256(uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid())),
                                'base64'), '='), '+/', '-_')
$$;

-- The stored form of a token; null for anything that is not a token, so it never matches
create or replace function cma.invitation_token_hash(p_token text)
returns text
language sql immutable
as $$
  select case when p_token ~ '^[A-Za-z0-9_-]{43}$' then encode(sha256(convert_to(p_token, 'UTF8')), 'hex') end
$$;

-- open, expired, accepted or revoked
create or replace function cma.invitation_state(p_expires_at timestamptz, p_accepted_at timestamptz, p_revoked_at timestamptz)
returns text
language sql stable
as $$
  select case when p_accepted_at is not null then 'accepted'
              when p_revoked_at is not null then 'revoked'
              when p_expires_at <= now() then 'expired'
              else 'open' end
$$;

-- The tenant's domain setting allows the address (an empty setting allows every address)
create or replace function cma.invitation_domain_allowed(p_tenant_id uuid, p_email text)
returns boolean
language sql stable
as $$
  select coalesce(cma.setting_of(p_tenant_id, 'auth.invitation_email_domains'), '') = ''
      or split_part(p_email, '@', 2) = any (string_to_array(cma.setting_of(p_tenant_id, 'auth.invitation_email_domains'), ','))
$$;

-- What a new or renewed invitation must meet for the acting user: the role exists, may be given to
-- people (never the system role) and is within the acting user's ceiling (cma.assert_role_assignable,
-- as Add a person); the address is in the domain setting and is no person of the tenant yet. Answers
-- the role's id.
create or replace function cma.assert_invitation_allowed(p_role_id uuid, p_email text)
returns uuid
language plpgsql stable
as $$
declare
  v_key        text;
  v_assignable boolean;
  v_status     text;
begin
  select r.key, r.is_assignable into v_key, v_assignable
  from cma.app_role r where r.tenant_id = cma.current_tenant_id() and r.id = p_role_id;
  if v_key is null then
    raise exception 'role not found in the current tenant' using errcode = 'CMA02';
  end if;
  if not v_assignable then
    raise exception 'role % is not assignable to people', v_key using errcode = 'CMA06';
  end if;
  perform cma.assert_role_assignable(v_key);
  if not cma.invitation_domain_allowed(cma.current_tenant_id(), p_email) then
    raise exception 'the address is outside the email domains invitations may go to' using errcode = 'CMA04';
  end if;
  select u.status into v_status from cma.app_user u where u.tenant_id = cma.current_tenant_id() and u.email = p_email;
  if v_status = 'active' then
    raise exception 'a person with this address exists in the current tenant' using errcode = 'CMA03';
  elsif v_status is not null then
    raise exception 'a person with this address exists but is inactive; reactivate them on People' using errcode = 'CMA03';
  end if;
  return p_role_id;
end
$$;

-- The sign-in already works in another tenant: an active person there holds it (the login lookup would
-- find two tenants, and without a tenant picker that is "no access yet" in both: README, Open decisions),
-- so an invitation to a second business line is not accepted with it. Owner's rights (called by the two
-- SECURITY DEFINER functions below); never executable by the application or a reader.
create or replace function cma.invitation_other_tenant(p_tenant_id uuid, p_login_system text, p_login_id text)
returns boolean
language sql stable
as $$
  select exists (
    select 1
    from cma.app_user_external_id x
    join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
    join cma.tenant   t on t.id = x.tenant_id
    where x.system = lower(btrim(coalesce(p_login_system, '')))
      and x.external_id = btrim(coalesce(p_login_id, ''))
      and x.tenant_id <> p_tenant_id
      and u.status = 'active'
      and t.status = 'active')
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The application's functions (permission checked inside, CMA06 otherwise)
-- ---------------------------------------------------------------------------------------------
-- A new invitation. Fields and checks as Add a person (address, name, employer, role within the
-- ceiling), plus a language for the mail, the teams (current ones) and the skills with levels (from
-- the scale; skills need skills.manage, as on People). Answers the id, the token (once; only its hash
-- is kept) and the expiry.
create or replace function cma.create_invitation(
  p_email             text,
  p_display_name      text,
  p_locale            text,
  p_role_key          text,
  p_organisation_key  text,
  p_team_keys         text[] default '{}',
  p_skills            jsonb default '[]'
)
returns table (invitation_id uuid, token text, expires_at timestamptz)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_actor   uuid := cma.assert_any_permission(array['users.manage_agents', 'users.manage_all']);
  v_tenant  uuid := cma.current_tenant_id();
  v_email   text := lower(btrim(coalesce(p_email, '')));
  v_name    text := btrim(coalesce(p_display_name, ''));
  v_locale  text := lower(btrim(coalesce(p_locale, '')));
  v_org     uuid;
  v_role    uuid;
  v_teams   uuid[] := '{}';
  v_team    uuid;
  v_skills  jsonb := '[]';
  item      jsonb;
  v_key     text;
  v_skill   uuid;
  v_dim     text;
  v_level   smallint;
  v_token   text;
  v_id      uuid;
  v_expires timestamptz;
  k         text;
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or length(v_email) > 200 then
    raise exception 'the address is not an email address' using errcode = 'CMA04';
  end if;
  if length(v_name) < 1 or length(v_name) > 100 then
    raise exception 'the display name must be 1 to 100 characters' using errcode = 'CMA04';
  end if;
  if v_locale !~ '^[a-z]{2}$' then
    raise exception 'the language must be a two-letter code' using errcode = 'CMA04';
  end if;
  select id into v_org from cma.organisation where tenant_id = v_tenant and key = p_organisation_key and status = 'active';
  if v_org is null then
    raise exception 'no active employer % in the current tenant', p_organisation_key using errcode = 'CMA02';
  end if;
  select r.id into v_role from cma.app_role r where r.tenant_id = v_tenant and r.key = p_role_key;
  if v_role is null then
    raise exception 'role % not found in the current tenant', p_role_key using errcode = 'CMA02';
  end if;

  foreach k in array coalesce(p_team_keys, '{}') loop
    select t.id into v_team from cma.team t where t.tenant_id = v_tenant and t.key = k and t.valid_to is null;
    if v_team is null then
      raise exception 'team % not found in the current tenant', k using errcode = 'CMA02';
    end if;
    if not v_team = any (v_teams) then
      v_teams := v_teams || v_team;
    end if;
    v_team := null;
  end loop;

  if p_skills is null or jsonb_typeof(p_skills) <> 'array' then
    raise exception 'skills must be a JSON array of { key, level }' using errcode = 'CMA04';
  end if;
  if jsonb_array_length(p_skills) > 0 then
    perform cma.assert_permission('skills.manage');
  end if;
  for item in select * from jsonb_array_elements(p_skills) loop
    v_key := item ->> 'key';
    v_level := case when jsonb_typeof(item -> 'level') = 'number' then (item ->> 'level')::smallint end;
    select s.id, s.dimension into v_skill, v_dim from cma.skill s
    where s.tenant_id = v_tenant and s.key = v_key and s.status = 'active';
    if v_skill is null then
      raise exception 'skill % not found or inactive in the current tenant', v_key using errcode = 'CMA02';
    end if;
    if exists (select 1 from jsonb_array_elements(v_skills) e where (e ->> 'skill_id')::uuid = v_skill) then
      raise exception 'skill % appears twice', v_key using errcode = 'CMA04';
    end if;
    if exists (select 1 from cma.skill_level l where l.tenant_id = v_tenant and l.dimension = v_dim) then
      if v_level is null or not exists (select 1 from cma.skill_level l where l.tenant_id = v_tenant and l.dimension = v_dim and l.level = v_level) then
        raise exception 'skill dimension % needs a level from its scale', v_dim using errcode = 'CMA04';
      end if;
    elsif v_level is not null then
      raise exception 'skill dimension % has no levels; it is held or not', v_dim using errcode = 'CMA04';
    end if;
    v_skills := v_skills || jsonb_build_array(jsonb_build_object('skill_id', v_skill, 'level', v_level));
    v_skill := null; v_dim := null;
  end loop;

  perform cma.assert_invitation_allowed(v_role, v_email);
  if exists (select 1 from cma.invitation i where i.tenant_id = v_tenant and i.email = v_email
             and i.accepted_at is null and i.revoked_at is null) then
    raise exception 'this address has a pending invitation; send a new link or revoke it' using errcode = 'CMA03';
  end if;

  v_token := cma.invitation_new_token();
  v_expires := now() + make_interval(days => cma.setting_of(v_tenant, 'auth.invitation_valid_days')::integer);
  begin
    insert into cma.invitation (tenant_id, email, display_name, locale, role_id, organisation_id, team_ids, skills,
                                token_hash, created_by, expires_at)
    values (v_tenant, v_email, v_name, v_locale, v_role, v_org, v_teams, v_skills,
            cma.invitation_token_hash(v_token), v_actor, v_expires)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'this address has a pending invitation; send a new link or revoke it' using errcode = 'CMA03';
  end;
  return query select v_id, v_token, v_expires;
end
$$;

-- A new link for an open or expired invitation: a new token (the old one stops working), a new
-- expiry from now, and the renewing person as the inviter of the link. The role must still be within
-- their ceiling, the address in the domain setting and no person of the tenant. Accepted or revoked:
-- CMA03.
create or replace function cma.renew_invitation(p_id uuid)
returns table (invitation_id uuid, token text, expires_at timestamptz)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_actor    uuid := cma.assert_any_permission(array['users.manage_agents', 'users.manage_all']);
  v_tenant   uuid := cma.current_tenant_id();
  inv        record;
  v_token    text;
  v_expires  timestamptz;
begin
  select i.id, i.email, i.role_id, i.accepted_at, i.revoked_at into inv
  from cma.invitation i where i.tenant_id = v_tenant and i.id = p_id
  for update;
  if inv.id is null then
    raise exception 'invitation not found in the current tenant' using errcode = 'CMA02';
  end if;
  if inv.accepted_at is not null or inv.revoked_at is not null then
    raise exception 'the invitation was accepted or revoked; invite again' using errcode = 'CMA03';
  end if;
  perform cma.assert_invitation_allowed(inv.role_id, inv.email);
  v_token := cma.invitation_new_token();
  v_expires := now() + make_interval(days => cma.setting_of(v_tenant, 'auth.invitation_valid_days')::integer);
  update cma.invitation i
  set token_hash = cma.invitation_token_hash(v_token), expires_at = v_expires, renewed_at = now(), renewed_by = v_actor
  where i.tenant_id = v_tenant and i.id = p_id;
  return query select p_id, v_token, v_expires;
end
$$;

-- Revokes an open or expired invitation; its link stops working. Revoking a revoked invitation
-- changes nothing; an accepted one is CMA03. The role must be within the acting user's ceiling.
create or replace function cma.revoke_invitation(p_id uuid)
returns text
language plpgsql
as $$
declare
  v_actor  uuid := cma.assert_any_permission(array['users.manage_agents', 'users.manage_all']);
  v_tenant uuid := cma.current_tenant_id();
  inv      record;
begin
  select i.id, r.key as role_key, i.accepted_at, i.revoked_at into inv
  from cma.invitation i
  join cma.app_role r on r.tenant_id = i.tenant_id and r.id = i.role_id
  where i.tenant_id = v_tenant and i.id = p_id
  for update of i;
  if inv.id is null then
    raise exception 'invitation not found in the current tenant' using errcode = 'CMA02';
  end if;
  perform cma.assert_role_assignable(inv.role_key);
  if inv.accepted_at is not null then
    raise exception 'the invitation was accepted' using errcode = 'CMA03';
  end if;
  if inv.revoked_at is null then
    update cma.invitation i set revoked_at = now(), revoked_by = v_actor where i.tenant_id = v_tenant and i.id = p_id;
  end if;
  return 'revoked';
end
$$;

-- The invitations the acting user may see: users.manage_all every one, users.manage_agents those for a
-- role they may grant (as the directory hides managing people from them). Newest first; with the
-- computed state, never the hash.
create or replace function cma.invitations()
returns table (
  invitation_id      uuid,
  email              text,
  display_name       text,
  locale             text,
  role_key           text,
  role_name          text,
  organisation_key   text,
  organisation_name  text,
  teams              jsonb,
  skills             jsonb,
  state              text,
  created_at         timestamptz,
  created_by_name    text,
  expires_at         timestamptz,
  renewed_at         timestamptz,
  accepted_at        timestamptz,
  accepted_user_id   uuid,
  accepted_name      text,
  revoked_at         timestamptz,
  revoked_by_name    text
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_user uuid := cma.assert_any_permission(array['users.manage_agents', 'users.manage_all']);
  v_all  boolean := cma.has_permission(cma.current_user_id(), 'users.manage_all');
begin
  return query
    select i.id, i.email::text, i.display_name::text, i.locale::text, r.key::text, r.name::text, o.key::text, o.name::text,
           coalesce((select jsonb_agg(jsonb_build_object('key', t.key, 'name', t.name) order by t.sort_order, t.key)
                     from cma.team t where t.tenant_id = i.tenant_id and t.id = any (i.team_ids)), '[]'::jsonb),
           coalesce((select jsonb_agg(jsonb_build_object('dimension', s.dimension, 'key', s.key, 'name', s.name,
                                                         'level', (e ->> 'level')::smallint, 'levelName', l.name)
                                      order by case s.dimension when 'language' then 1 when 'work_type' then 2 else 3 end, s.sort_order, s.key)
                     from jsonb_array_elements(i.skills) e
                     join cma.skill s on s.tenant_id = i.tenant_id and s.id = (e ->> 'skill_id')::uuid
                     left join cma.skill_level l on l.tenant_id = s.tenant_id and l.dimension = s.dimension
                                                and l.level = (e ->> 'level')::smallint), '[]'::jsonb),
           cma.invitation_state(i.expires_at, i.accepted_at, i.revoked_at),
           i.created_at, cu.display_name::text, i.expires_at, i.renewed_at,
           i.accepted_at, i.accepted_user_id, au.display_name::text, i.revoked_at, ru.display_name::text
    from cma.invitation i
    join cma.app_role r on r.tenant_id = i.tenant_id and r.id = i.role_id
    join cma.organisation o on o.tenant_id = i.tenant_id and o.id = i.organisation_id
    join cma.app_user cu on cu.tenant_id = i.tenant_id and cu.id = i.created_by
    left join cma.app_user au on au.tenant_id = i.tenant_id and au.id = i.accepted_user_id
    left join cma.app_user ru on ru.tenant_id = i.tenant_id and ru.id = i.revoked_by
    where i.tenant_id = cma.current_tenant_id()
      and (v_all or not cma.role_is_managing(i.role_id))
    order by i.created_at desc, i.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The invitee's side: SECURITY DEFINER, owned by cma_owner, no tenant context needed
-- ---------------------------------------------------------------------------------------------
-- What the link shows, without changing anything (a mail scanner may open it), in this order:
-- invalid (unknown or revoked, or a tenant switched off: nothing else), already_member (this sign-in
-- is a person of that tenant, also after accepting), invalid (accepted), other_tenant (this sign-in
-- works in another tenant already: without a tenant picker it would lose its access there), expired
-- (the tenant's name), wrong_account (the invited address, to its link holder), else open (the
-- tenant's name, the role's name and the invitation's language). The identity is the one
-- the sign-in proved: its system and id, and its verified address.
create or replace function cma.invitation_preview(p_token text, p_login_system text, p_login_id text, p_email text)
returns table (result text, tenant_name text, role_name text, invited_email text, locale text, expires_at timestamptz)
language plpgsql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
#variable_conflict use_column
declare
  inv record;
begin
  select i.tenant_id, i.email, i.locale, i.expires_at, i.accepted_at, i.revoked_at, t.name as tenant_name, t.status as tenant_status,
         r.name as role_name
    into inv
  from cma.invitation i
  join cma.tenant t on t.id = i.tenant_id
  join cma.app_role r on r.tenant_id = i.tenant_id and r.id = i.role_id
  where i.token_hash = cma.invitation_token_hash(p_token);
  if inv.tenant_id is null or inv.revoked_at is not null or inv.tenant_status <> 'active' then
    return query select 'invalid'::text, null::text, null::text, null::text, null::text, null::timestamptz;
    return;
  end if;
  if exists (select 1 from cma.app_user_external_id x
             where x.tenant_id = inv.tenant_id and x.system = lower(btrim(coalesce(p_login_system, ''))) and x.external_id = btrim(coalesce(p_login_id, ''))) then
    return query select 'already_member'::text, inv.tenant_name::text, null::text, null::text, inv.locale::text, null::timestamptz;
    return;
  end if;
  if inv.accepted_at is not null then
    return query select 'invalid'::text, null::text, null::text, null::text, null::text, null::timestamptz;
    return;
  end if;
  if cma.invitation_other_tenant(inv.tenant_id, p_login_system, p_login_id) then
    return query select 'other_tenant'::text, inv.tenant_name::text, null::text, null::text, inv.locale::text, null::timestamptz;
    return;
  end if;
  if inv.expires_at <= now() then
    return query select 'expired'::text, inv.tenant_name::text, null::text, null::text, inv.locale::text, inv.expires_at;
    return;
  end if;
  if lower(btrim(coalesce(p_email, ''))) <> inv.email then
    return query select 'wrong_account'::text, inv.tenant_name::text, inv.role_name::text, inv.email::text, inv.locale::text, inv.expires_at;
    return;
  end if;
  return query select 'open'::text, inv.tenant_name::text, inv.role_name::text, inv.email::text, inv.locale::text, inv.expires_at;
end
$$;

-- Accepts an invitation for the signed-in identity, checked in the preview's order: found by the
-- token's hash and not revoked, the sign-in id not yet linked in that tenant (already_member), not
-- accepted, the sign-in not working in another tenant (other_tenant), not expired, the verified address
-- equal to the invited one, and no person with the address there. Then, in that tenant only and as the inviter of the current link
-- (app.actor_label invitation), the person is added as Add a person adds one (cma.add_person: user,
-- sign-in id under the given system, role), with the teams that still exist and the skills still in
-- the catalog and scale, and the invitation is marked accepted; any refusal on the way (the inviter's
-- permission or ceiling gone, the role, employer or address no longer allowed) is invalid and writes
-- nothing. The role cannot be changed here. Answers the result with the tenant and the person's id
-- when accepted: accepted, invalid, expired, wrong_account, already_member or other_tenant.
create or replace function cma.accept_invitation(p_token text, p_login_system text, p_login_id text, p_email text)
returns table (result text, tenant_id uuid, user_id uuid)
language plpgsql security definer
set search_path = pg_catalog, cma, pg_temp
as $$
#variable_conflict use_column
declare
  v_system    text := lower(btrim(coalesce(p_login_system, '')));
  v_login     text := btrim(coalesce(p_login_id, ''));
  v_email     text := lower(btrim(coalesce(p_email, '')));
  inv         record;
  v_user      uuid;
  v_teams     text[];
  v_skills    jsonb;
  v_prev_t    text := current_setting('app.tenant_id', true);
  v_prev_u    text := current_setting('app.user_id', true);
  v_prev_l    text := current_setting('app.actor_label', true);
begin
  if v_system !~ '^[a-z0-9_]+$' or v_system ~ '_(owner|user)$' or v_login = '' or length(v_login) > 200 or v_login ~ '[[:space:]]' then
    raise exception 'a sign-in system and id are needed' using errcode = 'CMA04';
  end if;

  select i.id, i.tenant_id, i.email, i.display_name, i.role_id, i.organisation_id, i.team_ids, i.skills, i.expires_at,
         i.accepted_at, i.revoked_at, coalesce(i.renewed_by, i.created_by) as inviter, t.status as tenant_status
    into inv
  from cma.invitation i
  join cma.tenant t on t.id = i.tenant_id
  where i.token_hash = cma.invitation_token_hash(p_token)
  for update of i;
  if inv.id is null or inv.revoked_at is not null or inv.tenant_status <> 'active' then
    return query select 'invalid'::text, null::uuid, null::uuid;
    return;
  end if;
  if exists (select 1 from cma.app_user_external_id x where x.tenant_id = inv.tenant_id and x.system = v_system and x.external_id = v_login) then
    return query select 'already_member'::text, inv.tenant_id, null::uuid;
    return;
  end if;
  if inv.accepted_at is not null then
    return query select 'invalid'::text, null::uuid, null::uuid;
    return;
  end if;
  if cma.invitation_other_tenant(inv.tenant_id, v_system, v_login) then
    return query select 'other_tenant'::text, null::uuid, null::uuid;
    return;
  end if;
  if inv.expires_at <= now() then
    return query select 'expired'::text, null::uuid, null::uuid;
    return;
  end if;
  if v_email <> inv.email then
    return query select 'wrong_account'::text, null::uuid, null::uuid;
    return;
  end if;

  begin
    -- this tenant only, as the inviter of the current link
    perform set_config('app.tenant_id', inv.tenant_id::text, true);
    perform set_config('app.user_id', inv.inviter::text, true);
    perform set_config('app.actor_label', 'invitation', true);
    if exists (select 1 from cma.app_user u where u.tenant_id = inv.tenant_id and u.email = inv.email) then
      raise exception 'a person with this address exists' using errcode = 'CMA03';
    end if;
    if not exists (select 1 from cma.app_role r where r.tenant_id = inv.tenant_id and r.id = inv.role_id and r.is_assignable) then
      raise exception 'the role is not assignable' using errcode = 'CMA06';
    end if;
    if not cma.invitation_domain_allowed(inv.tenant_id, inv.email) then
      raise exception 'the address is outside the email domains' using errcode = 'CMA04';
    end if;
    v_user := cma.add_person(inv.email, inv.display_name,
                             (select o.key from cma.organisation o where o.tenant_id = inv.tenant_id and o.id = inv.organisation_id),
                             (select r.key from cma.app_role r where r.tenant_id = inv.tenant_id and r.id = inv.role_id),
                             v_system, v_login, null);
    select coalesce(array_agg(t.key order by t.key), '{}') into v_teams
    from cma.team t where t.tenant_id = inv.tenant_id and t.id = any (inv.team_ids) and t.valid_to is null;
    if cardinality(v_teams) > 0 then
      perform cma.set_person_teams(v_user, v_teams);
    end if;
    select coalesce(jsonb_agg(case when e ->> 'level' is null then jsonb_build_object('key', s.key)
                                   else jsonb_build_object('key', s.key, 'level', (e ->> 'level')::smallint) end
                              order by s.key), '[]'::jsonb)
      into v_skills
    from jsonb_array_elements(inv.skills) e
    join cma.skill s on s.tenant_id = inv.tenant_id and s.id = (e ->> 'skill_id')::uuid and s.status = 'active'
    where case when exists (select 1 from cma.skill_level l where l.tenant_id = s.tenant_id and l.dimension = s.dimension)
               then exists (select 1 from cma.skill_level l where l.tenant_id = s.tenant_id and l.dimension = s.dimension
                            and l.level = (e ->> 'level')::smallint)
               else e ->> 'level' is null end;
    if jsonb_array_length(v_skills) > 0 then
      perform cma.set_person_skills(v_user, v_skills);
    end if;
    update cma.invitation i set accepted_at = now(), accepted_user_id = v_user where i.tenant_id = inv.tenant_id and i.id = inv.id;
  exception when sqlstate 'CMA01' or sqlstate 'CMA02' or sqlstate 'CMA03' or sqlstate 'CMA04' or sqlstate 'CMA06' then
    perform set_config('app.tenant_id', coalesce(v_prev_t, ''), true);
    perform set_config('app.user_id', coalesce(v_prev_u, ''), true);
    perform set_config('app.actor_label', coalesce(v_prev_l, ''), true);
    return query select 'invalid'::text, null::uuid, null::uuid;
    return;
  end;
  perform set_config('app.tenant_id', coalesce(v_prev_t, ''), true);
  perform set_config('app.user_id', coalesce(v_prev_u, ''), true);
  perform set_config('app.actor_label', coalesce(v_prev_l, ''), true);
  return query select 'accepted'::text, inv.tenant_id, v_user;
end
$$;
revoke execute on function cma.invitation_other_tenant(uuid, text, text) from public;
alter function cma.invitation_preview(text, text, text, text) owner to cma_owner;
alter function cma.accept_invitation(text, text, text, text) owner to cma_owner;

-- ---------------------------------------------------------------------------------------------
-- 7. Grants: the application only (its functions call the helpers in its rights); never readers
--    or public
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.is_domain_list(text)',
    'cma.invitation_new_token()',
    'cma.invitation_token_hash(text)',
    'cma.invitation_state(timestamptz,timestamptz,timestamptz)',
    'cma.invitation_domain_allowed(uuid,text)',
    'cma.assert_invitation_allowed(uuid,text)',
    'cma.create_invitation(text,text,text,text,text,text[],jsonb)',
    'cma.renew_invitation(uuid)',
    'cma.revoke_invitation(uuid)',
    'cma.invitations()',
    'cma.invitation_preview(text,text,text,text)',
    'cma.accept_invitation(text,text,text,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Reporting view: every column but the hash
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.invitation as
  select id, tenant_id, email, display_name, locale, role_id, organisation_id, team_ids, skills, created_by, created_at,
         expires_at, renewed_at, renewed_by, accepted_at, accepted_user_id, revoked_at, revoked_by
  from cma.invitation
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 9. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008l', 'Invitations by email: cma.invitation (the token''s hash only, never in the audit), the two invitation settings, create, renew, revoke and list for the people rule, and the invitee''s preview and acceptance, which bind the sign-in id when the verified address matches')
on conflict (version) do nothing;

commit;
reset role;
