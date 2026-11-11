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
    (v_subs, 'pulse4all', 'admin@example.com',      'Test Admin'),        -- admin (0004): manages everyone, configures
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
    (v_subs, 'admin@example.com',      'admin'),
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

-- Teams and skills for the test people (after migration 0004 and the Pulse4all seed's teams and
-- skills), written through the functions as the test admin so the audit rows name a person. Only
-- where the person has no current membership or skill yet, so a rerun changes nothing.
do $$
declare
  v_subs  uuid := (select id from cma.tenant where slug = 'pulse4all-subscriptions');
  v_admin uuid := (select id from cma.app_user where tenant_id = v_subs and email = 'admin@example.com');
  r       record;
begin
  if to_regclass('cma.team') is null or v_admin is null then
    raise notice 'teams and skills fixture skipped (migration 0004 or the admin user missing)';
    return;
  end if;
  if not exists (select 1 from cma.team where tenant_id = v_subs and key = 'nl') then
    raise notice 'teams and skills fixture skipped: rerun 02_seed_pulse4all.sql first';
    return;
  end if;
  perform set_config('app.tenant_id', v_subs::text, true);
  perform set_config('app.user_id', v_admin::text, true);
  perform set_config('app.actor_label', 'seed:dev-teams-skills', true);
  for r in
    select u.id, s.teams, s.skills
    from (values
      ('agent.one@example.com',  array['nl', 'en'],  '[{"key":"nl","level":4},{"key":"en","level":2},{"key":"sales"},{"key":"operations"}]'::jsonb),
      ('agent.two@example.com',  array['nordics'],   '[{"key":"da","level":4},{"key":"sv","level":2},{"key":"en","level":3},{"key":"sales"}]'::jsonb),
      ('supervisor@example.com', array['nl'],        '[{"key":"nl","level":4},{"key":"en","level":3},{"key":"operations"},{"key":"debt"}]'::jsonb)
    ) as s(email, teams, skills)
    join cma.app_user u on u.tenant_id = v_subs and u.email = s.email
  loop
    if not exists (select 1 from cma.team_member where tenant_id = v_subs and user_id = r.id and valid_to is null) then
      perform cma.set_person_teams(r.id, r.teams);
    end if;
    if not exists (select 1 from cma.user_skill where tenant_id = v_subs and user_id = r.id and valid_to is null) then
      perform cma.set_person_skills(r.id, r.skills);
    end if;
  end loop;
end
$$;

-- The per-person reports on in dev (after addition 0008t; night run N19-A, 18 October 2026), so Email per
-- agent and Orders per person can be tried on the dev data before a decision for prod: the seed sets it, since
-- 02 writes Pulse4all's own value (email) first. Attempts per agent joins them once addition 0008y lets the
-- setting hold attempts (19 October 2026); before it, a rerun after 92_attempts_per_deal.sql adds it. Deals per
-- person (Reports, Funnel) joins them once addition 0008zb lets it hold deals (20 October 2026; off for Pulse4all
-- until Yordi agrees); before it, a rerun after 98_funnel.sql adds it.
do $$
declare
  v_value text;
begin
  -- two steps: PL/pgSQL plans an IF's whole expression, so a lookup in the catalog fails before 13 creates it
  if to_regclass('cma.setting') is null then
    raise notice 'the per-person setting does not exist yet (addition 0008t): rerun this seed after 82_email_reports.sql';
    return;
  end if;
  if not exists (select 1 from cma.setting where key = 'reports.per_person') then
    raise notice 'the per-person setting does not exist yet (addition 0008t): rerun this seed after 82_email_reports.sql';
    return;
  end if;
  if cma.is_per_person_list('email,orders,attempts,deals') then
    v_value := 'email,orders,attempts,deals';
  elsif cma.is_per_person_list('email,orders,attempts') then
    raise notice 'the per-person setting does not take deals yet (addition 0008zb): rerun this seed after 98_funnel.sql';
    v_value := 'email,orders,attempts';
  else
    raise notice 'the per-person setting does not take attempts yet (addition 0008y): rerun this seed after 92_attempts_per_deal.sql';
    v_value := 'email,orders';
  end if;
  insert into cma.tenant_setting (tenant_id, key, value)
  select t.id, 'reports.per_person', v_value
  from cma.tenant t
  where t.slug = 'pulse4all-subscriptions'
  on conflict (tenant_id, key) do update set value = excluded.value
    where cma.tenant_setting.value is distinct from excluded.value;
end
$$;

-- Customers → Active on test data (after addition 0009l; brief B35, 11 November 2026): a synthetic customer base of
-- Pulse4all Subscriptions in dev, so the page can be looked at without a real customer: three seed stores (seed-nl in NL,
-- seed-gb in GB with pounds, seed-de in DE), each with its subscriptions connection, a seed CRM connection whose
-- contacts carry a segment (a quarter B2B, half B2C, a quarter none), 150 customers per store (two of three linked to a
-- contact) and 540 subscriptions created over 30 months: seven of ten active, one failed, one canceled with its time,
-- one in twenty paused, one in twenty expired with its event; mostly monthly, one in twenty yearly. The British store's
-- subscriptions older than 18 months all carry the day 18 months back (subscriptions moved into the subscription app
-- carry the date they moved: the page's dominant-cohort note). Indicative euro rates of 1 November 2026 for the page's
-- approximate total (test values, not a source). Every id is invented (seed-…); no name, address, email or phone. The
-- seed connections hold no token, so no job reads them. Rerunnable: every row is written once (its times are taken
-- from the first run), the rates only while they are empty. Direct / Indirect stays Unknown for these customers: the
-- seed writes no order deal. A database without 0009l yet says so; rerun this seed after 172_active_customers.sql.
do $$
declare
  v_subs  uuid := (select id from cma.tenant where slug = 'pulse4all-subscriptions');
  v_crm   uuid;
  v_shop  uuid[] := '{}';
  v_sub   uuid[] := '{}';
  v_codes text[] := array['NL', 'GB', 'DE'];
  v_cur   text[] := array['EUR', 'GBP', 'EUR'];
  v_zones text[] := array['Europe/Amsterdam', 'Europe/London', 'Europe/Berlin'];
  c       uuid;
  h       text;
begin
  if to_regprocedure('cma.active_top(date,text,text,text)') is null then
    raise notice 'Customers → Active does not exist yet (addition 0009l): rerun this seed after 172_active_customers.sql';
    return;
  end if;
  insert into cma.tenant_setting (tenant_id, key, value)
  values (v_subs, 'reports.fx_eur_rates', '{"as_of": "2026-11-01", "GBP": 1.15, "CHF": 1.06, "DKK": 0.134, "SEK": 0.091, "NOK": 0.086, "PLN": 0.235}')
  on conflict (tenant_id, key) do update set value = excluded.value where cma.tenant_setting.value = '{}';

  select x.id into v_crm from cma.integration_connection x where x.tenant_id = v_subs and x.adapter = 'seedcrm';
  if v_crm is null then
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_subs, 'seedcrm', 'crm', 'Seed CRM (test data)', 'seed-portal') returning id into v_crm;
  end if;
  for i in 1 .. 3 loop
    h := 'seed-' || lower(v_codes[i]);
    select x.id into c from cma.integration_connection x where x.tenant_id = v_subs and x.adapter = 'seedshop' and x.external_account_id = h || '.shop.example.invalid';
    if c is null then
      insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
      values (v_subs, 'seedshop', 'commerce', 'Seed shop ' || v_codes[i] || ' (test data)', h || '.shop.example.invalid') returning id into c;
    end if;
    v_shop := v_shop || c;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
    select v_subs, c, h, 'Seed ' || v_codes[i], v_codes[i], v_cur[i], v_zones[i]
    where not exists (select 1 from cma.commerce_store s where s.tenant_id = v_subs and s.handle = h);
    select x.id into c from cma.integration_connection x where x.tenant_id = v_subs and x.adapter = 'seedsubs' and x.external_account_id = h || '.shop.example.invalid';
    if c is null then
      insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
      values (v_subs, 'seedsubs', 'subscriptions', 'Seed subscriptions ' || v_codes[i] || ' (test data)', h || '.shop.example.invalid') returning id into c;
    end if;
    v_sub := v_sub || c;
  end loop;

  insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, segment)
  select v_subs, v_crm, 'seedcrm', 'seed-k' || g, case g % 4 when 0 then 'B2B' when 3 then null else 'B2C' end
  from generate_series(1, 300) g
  on conflict (tenant_id, connection_id, source_id) do nothing;
  -- customer g of a store: created 20 to 919 days back; two of three linked to contact g
  insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, orders_count, amount_spent, amount_currency,
                                     source_created_at, crm_connection_id, crm_contact_source_id, matched_at)
  select v_subs, v_shop[i], 'seedshop', 'seed-c' || i || '-' || g, 1 + g % 6, 150 + (g * 37) % 900, v_cur[i],
         now() - make_interval(days => 20 + (g * 61 + i * 7) % 900),
         case when g % 3 <> 0 then v_crm end, case when g % 3 <> 0 then 'seed-k' || (1 + (g * 3 + i) % 300) end, case when g % 3 <> 0 then now() end
  from generate_series(1, 3) i cross join generate_series(1, 150) g
  on conflict (tenant_id, connection_id, source_id) do nothing;
  -- subscription g of a store: its customer 1 + (g * 7) % 150 (30 customers with two), created 10 to 909 days back
  insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, current_cycle, billing_interval,
                                billing_interval_count, amount_per_cycle, currency, source_created_at, paused_at, canceled_at)
  select v_subs, v_sub[i], 'seedsubs', 'seed-s' || i || '-' || g, 'seed-c' || i || '-' || (1 + (g * 7) % 150), x.status, g % 24,
         case when g % 20 = 5 then 'year' else 'month' end, 1, case when g % 20 = 5 then 10 * (20 + g % 25) else 20 + g % 25 end, v_cur[i],
         x.created,
         case when x.status = 'paused' then x.created + (now() - x.created) * 0.9 end,
         case when x.status = 'canceled' then x.created + (now() - x.created) * ((10 + (g * 13) % 80) / 100.0) end
  from generate_series(1, 3) i
  cross join generate_series(1, 180) g
  cross join lateral (select (array['canceled', 'failed', 'active', 'active', 'active', 'active', 'active', 'active', 'active', 'active'])[1 + g % 10] as s0,
                             now() - make_interval(days => case when i = 2 and 10 + (g * 53) % 900 > 540 then 540 else 10 + (g * 53) % 900 end) as created) y
  cross join lateral (select case when g % 20 = 9 then 'paused' when g % 20 = 19 then 'expired' else y.s0 end as status, y.created) x
  on conflict (tenant_id, connection_id, source_id) do nothing;
  insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, status_from, status_to)
  select s.tenant_id, s.connection_id, 'seedsubs', 'seed-e-' || s.source_id, s.source_id, 'status_changed',
         s.source_created_at + (now() - s.source_created_at) * 0.6, 'active', 'expired'
  from cma.subscription s
  where s.tenant_id = v_subs and s.source_system = 'seedsubs' and s.status = 'expired'
  on conflict (tenant_id, connection_id, source_id) do nothing;
end
$$;

