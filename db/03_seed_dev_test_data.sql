-- CMA seed: dev test data (fictional). Dev only, never run in prod.
-- Run as yourself (IAM login) after 02_seed_pulse4all.sql. Safe to rerun.
-- Example.com users with roles, employers and CRM user ids for the V1 login screen.
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
declare
  v_subs uuid := (select id from cma.tenant where slug = 'pulse4all-subscriptions');
  v_inv  uuid := (select id from cma.tenant where slug = 'pulse4all-invest');
begin
  insert into cma.app_user (tenant_id, organisation_id, email, display_name)
  select s.tenant_id, o.id, s.email, s.display_name
  from (values
    (v_subs, 'newco',     'agent.one@example.com',  'Agent One'),
    (v_subs, 'newco',     'agent.two@example.com',  'Agent Two'),
    (v_subs, 'newco',     'supervisor@example.com', 'Test Supervisor'),
    (v_subs, 'pulse4all', 'manager@example.com',    'Test Manager'),
    (v_subs, 'pulse4all', 'analyst@example.com',    'Test Analyst'),      -- analytics: no clock, the Dashboard only
    (v_inv,  'clubdeal',  'agent.one@example.com',  'Invest Agent One')   -- same email, other tenant: separate row
  ) as s(tenant_id, org_key, email, display_name)
  join cma.organisation o on o.tenant_id = s.tenant_id and o.key = s.org_key
  on conflict (tenant_id, email) do nothing;

  insert into cma.user_role (tenant_id, user_id, role_id)
  select u.tenant_id, u.id, r.id
  from (values
    (v_subs, 'agent.one@example.com',  'agent'),
    (v_subs, 'agent.two@example.com',  'agent'),
    (v_subs, 'supervisor@example.com', 'supervisor'),
    (v_subs, 'manager@example.com',    'manager'),
    (v_subs, 'analyst@example.com',    'analytics'),
    (v_inv,  'agent.one@example.com',  'agent')
  ) as s(tenant_id, email, role_key)
  join cma.app_user u on u.tenant_id = s.tenant_id and u.email = s.email
  join cma.app_role r on r.tenant_id = s.tenant_id and r.key = s.role_key
  on conflict do nothing;

  -- fictional HubSpot user ids for the V1 login screen
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
  select u.tenant_id, u.id, 'hubspot_user', s.ext
  from (values
    (v_subs, 'agent.one@example.com', '1001'),
    (v_subs, 'manager@example.com',   '1002')
  ) as s(tenant_id, email, ext)
  join cma.app_user u on u.tenant_id = s.tenant_id and u.email = s.email
  on conflict do nothing;
end
$$;

-- A dev-only app link that needs a permission (after addition 0003d), so the API verifier can prove
-- that a link is shown only to people holding it. Fictional address; nothing like it goes to prod.
do $$
declare
  v_subs uuid := (select id from cma.tenant where slug = 'pulse4all-subscriptions');
begin
  if to_regclass('cma.app_link') is not null then
    insert into cma.app_link (tenant_id, key, label, address, permission_key, sort_order)
    values (v_subs, 'team-sheet', 'Team sheet (test)', 'https://example.com/team-sheet', 'workday.team', 30)
    on conflict (tenant_id, key) do nothing;
  end if;
end
$$;
