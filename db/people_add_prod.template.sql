-- =============================================================================================
-- db/people_add_prod.template.sql: add one person with a login to a tenant
-- =============================================================================================
-- Adds (or completes) one person: the app_user row, the login id in app_user_external_id and
-- one role grant. Universal: tenant, employer, role, zone and login system are values below.
--
-- How to run
--   1. Copy this file into the Cloud SQL Studio editor, under your own IAM login, database cma.
--      Never fill it in inside the repository and never commit a filled copy.
--   2. Replace the six <…> values in step 2. The login id is the person's own:
--      curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
--        https://www.googleapis.com/oauth2/v3/userinfo          (the "sub" field)
--      The best person to paste it is the person themselves, so the id never travels.
--   3. Run all. The last result is the verdict: one row, the login id shown only as matched.
--      A refusal stops the script with "people_add: …"; nothing is written then.
--
-- Rerunnable: an existing person is reused, an existing grant is kept. It never overwrites a
-- login id, never reactivates an inactive person and never removes a role.
-- The person's first visit to the Workspace is their clock-in: nobody tests it on their behalf.
-- =============================================================================================

-- Step 1: guard and role
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;

-- Step 2: the values (the only lines to edit)
drop table if exists pg_temp.people_add;
create temp table people_add as
select
  '<TENANT_SLUG>'::text   as tenant_slug,    -- e.g. pulse4all-subscriptions
  '<EMAIL>'::text         as email,          -- display only; matching is on the login id
  '<DISPLAY_NAME>'::text  as display_name,
  '<EMPLOYER_KEY>'::text  as employer_key,   -- cma.organisation.key in that tenant
  '<ROLE_KEY>'::text      as role_key,       -- cma.app_role.key in that tenant
  '<LOGIN_ID>'::text      as login_id,       -- Google: digits only, the userinfo "sub"
  'google'::text          as login_system,   -- Pulse4all: google; another customer: its own key
  null::text              as timezone;       -- null inherits employer, then tenant

-- Step 3: checks and writes, in one statement, so all or nothing
do $$
declare
  p         pg_temp.people_add;
  v_tenant  uuid;
  v_org     uuid;
  v_role    uuid;
  v_user    uuid;
  v_status  text;
  v_runner  uuid;
  v_taken   uuid;
  v_current text;
begin
  select * into strict p from pg_temp.people_add;

  if concat_ws('|', p.tenant_slug, p.email, p.display_name, p.employer_key, p.role_key, p.login_id) ~ '[<>]' then
    raise exception 'people_add: replace every <…> value in step 2 first';
  end if;
  p.email := lower(btrim(p.email));
  p.display_name := btrim(p.display_name);
  p.login_id := btrim(p.login_id);
  if p.email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'people_add: % is not an email address', p.email;
  end if;
  if length(p.display_name) < 2 then
    raise exception 'people_add: display name is empty';
  end if;
  if p.login_system = 'google' and p.login_id !~ '^[0-9]{10,30}$' then
    raise exception 'people_add: a Google login id is the numeric userinfo "sub", not an email or Admin console key';
  end if;
  if p.timezone is not null and not exists (select 1 from pg_timezone_names where name = p.timezone) then
    raise exception 'people_add: % is not a time zone Postgres knows', p.timezone;
  end if;

  select id into v_tenant from cma.tenant where slug = p.tenant_slug and status = 'active';
  if v_tenant is null then
    raise exception 'people_add: no active tenant %', p.tenant_slug;
  end if;
  select id into v_org from cma.organisation
   where tenant_id = v_tenant and key = p.employer_key and status = 'active';
  if v_org is null then
    raise exception 'people_add: no active employer % in %', p.employer_key, p.tenant_slug;
  end if;
  select id into v_role from cma.app_role where tenant_id = v_tenant and key = p.role_key;
  if v_role is null then
    raise exception 'people_add: no role % in %', p.role_key, p.tenant_slug;
  end if;

  -- The login id may belong to nobody else in this tenant
  select user_id into v_taken from cma.app_user_external_id
   where tenant_id = v_tenant and system = p.login_system and external_id = p.login_id;

  select id, status into v_user, v_status from cma.app_user
   where tenant_id = v_tenant and email = p.email;
  if v_user is not null and v_status <> 'active' then
    raise exception 'people_add: % exists but is %; reactivating is a deliberate separate step', p.email, v_status;
  end if;
  if v_taken is not null and v_taken is distinct from v_user then
    raise exception 'people_add: this login id already belongs to another person in %', p.tenant_slug;
  end if;
  if v_user is not null then
    select external_id into v_current from cma.app_user_external_id
     where tenant_id = v_tenant and user_id = v_user and system = p.login_system;
    if v_current is not null and v_current <> p.login_id then
      raise exception 'people_add: % already has a different % login id; changing it is a deliberate separate step', p.email, p.login_system;
    end if;
  end if;

  -- Whoever runs this, if they are a person in the tenant, is recorded as the grantor
  select id into v_runner from cma.app_user
   where tenant_id = v_tenant and email = lower(session_user) and status = 'active';

  if v_user is null then
    insert into cma.app_user (tenant_id, organisation_id, email, display_name, timezone)
    values (v_tenant, v_org, p.email, p.display_name, p.timezone)
    returning id into v_user;
  end if;

  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
  values (v_tenant, v_user, p.login_system, p.login_id)
  on conflict do nothing;

  insert into cma.user_role (tenant_id, user_id, role_id, granted_by)
  values (v_tenant, v_user, v_role, v_runner)
  on conflict do nothing;
end
$$;

-- Step 4: the verdict (one row; the login id is never shown)
select t.slug                                   as tenant,
       u.email,
       u.display_name,
       u.status,
       o.key                                    as employer,
       u.timezone,
       (select string_agg(r.key || coalesce(' (' || ur.scope_type || ')', ''), ', ' order by ur.granted_at)
          from cma.user_role ur
          join cma.app_role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
         where ur.tenant_id = u.tenant_id and ur.user_id = u.id)              as roles,
       exists (select 1 from cma.app_user_external_id x
                where x.tenant_id = u.tenant_id and x.user_id = u.id
                  and x.system = p.login_system and x.external_id = btrim(p.login_id)) as login_matches,
       case when exists (select 1 from cma.app_user_external_id x
                          where x.tenant_id = u.tenant_id and x.user_id = u.id
                            and x.system = p.login_system and x.external_id = btrim(p.login_id))
             and exists (select 1 from cma.user_role ur
                          join cma.app_role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                         where ur.tenant_id = u.tenant_id and ur.user_id = u.id and r.key = p.role_key)
            then 'PASS' else 'FAIL' end                                       as verdict
  from pg_temp.people_add p
  join cma.tenant t on t.slug = p.tenant_slug
  join cma.app_user u on u.tenant_id = t.id and u.email = lower(btrim(p.email))
  left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id;
