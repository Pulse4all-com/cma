-- CMA seed: Pulse4all configuration
-- Run as yourself (IAM login) after 01_foundation.sql, in dev and in prod. Safe to rerun.
-- Customer configuration, not schema: the two tenants, their organisations, their channels, the
-- Subscriptions work statuses, the export settings and the app links.
-- Another customer gets its own seed file with its own values; the migration stays untouched.
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

-- Tenants (one per business line) with the default role ladder
select cma.create_tenant('pulse4all-subscriptions', 'Pulse4all Subscriptions', 'Europe/Amsterdam');
select cma.create_tenant('pulse4all-invest',        'Pulse4all Invest',        'Europe/Amsterdam');

-- Organisations per tenant
insert into cma.organisation (tenant_id, key, name)
select t.id, o.key, o.name
from (values
  ('pulse4all-subscriptions', 'pulse4all', 'Pulse4all'),
  ('pulse4all-subscriptions', 'newco',     'Newco'),
  ('pulse4all-invest',        'pulse4all', 'Pulse4all'),
  ('pulse4all-invest',        'clubdeal',  'Clubdeal')
) as o(tenant_slug, key, name)
join cma.tenant t on t.slug = o.tenant_slug
on conflict (tenant_id, key) do nothing;

-- Channels per tenant: what is live today. Add sms, whatsapp, chat, ... here or in the admin UI later
insert into cma.channel (tenant_id, key, name, is_synchronous)
select t.id, c.key, c.name, c.is_synchronous
from (values
  ('pulse4all-subscriptions', 'phone', 'Phone', true),
  ('pulse4all-subscriptions', 'email', 'Email', false),
  ('pulse4all-invest',        'phone', 'Phone', true),
  ('pulse4all-invest',        'email', 'Email', false)
) as c(tenant_slug, key, name, is_synchronous)
join cma.tenant t on t.slug = c.tenant_slug
on conflict (tenant_id, key) do nothing;

-- Time zone per employer (column from migration 0002). Newco works from Spain; the others follow
-- the tenant zone (Europe/Amsterdam). A user can still carry a personal zone (cma.app_user.timezone).
-- Guarded so this seed also runs on a fresh database before 0002; rerun it after 0002 in that case.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'cma' and table_name = 'organisation' and column_name = 'timezone') then
    update cma.organisation
    set timezone = 'Europe/Madrid'
    where key = 'newco' and timezone is distinct from 'Europe/Madrid';
  else
    raise notice 'organisation.timezone does not exist yet (migration 0002): rerun this seed after 05_time_model.sql';
  end if;
end
$$;

-- Work statuses for Pulse4all Subscriptions (Martin, 7 October 2026; README: Display rules and the
-- Decision log). Migration 0002 seeds the universal ladder (available, training, meeting, break,
-- lunch) for every tenant; this block turns the Subscriptions list into Pulse4all's own:
--   Available - Sales (the default) and Available - Operations, so availability hours report per
--   work type from the first day; Coaching; Training, Meeting and Coaching paid and billable;
--   Break and Lunch unpaid and not billable (time on another project is booked as Break); the
--   universal 'available' goes inactive, so history keeps its stretches and no new one lands in it.
-- Invest keeps the universal ladder until its own list is decided (Roadmap step 10).
-- Rerun-safe: it only adds statuses the tenant does not have yet, retires 'available' only on the
-- first run (while 'available_sales' does not exist), and changes the flags of 'break' only while
-- the row still carries the universal ones, so a later change on the configuration screen
-- (Roadmap step 5) survives a rerun. Existing days keep their events: an event references the
-- status row, active or not; the clock, the reports and the exports read the flags as stored.
do $$
declare
  v_subs uuid := (select id from cma.tenant where slug = 'pulse4all-subscriptions');
begin
  if to_regclass('cma.work_status') is null then
    raise notice 'cma.work_status does not exist yet (migration 0002): rerun this seed after 05_time_model.sql';
    return;
  end if;

  -- 1. Retire the universal 'available' (first run only), which also frees the one default per tenant
  update cma.work_status
  set status = 'inactive', is_default = false
  where tenant_id = v_subs and key = 'available' and status = 'active'
    and not exists (select 1 from cma.work_status
                    where tenant_id = v_subs and key = 'available_sales');

  -- 2. Pulse4all's own statuses, in the order of the My day grid (universal rows keep their numbers:
  --    training 20, meeting 30, break 40, lunch 50)
  insert into cma.work_status (tenant_id, key, name, is_working, is_productive, is_paid, is_billable, is_default, sort_order)
  select v_subs, v.key, v.name, v.is_working, v.is_productive, v.is_paid, v.is_billable, v.is_default, v.sort_order
  from (values
    ('available_sales',      'Available - Sales',      true, true,  true, true, true,  10),
    ('available_operations', 'Available - Operations', true, true,  true, true, false, 15),
    ('coaching',             'Coaching',               true, false, true, true, false, 35)
  ) as v(key, name, is_working, is_productive, is_paid, is_billable, is_default, sort_order)
  on conflict (tenant_id, key) do nothing;

  -- 3. Break: unpaid and not billable, like Lunch (the universal row is paid and billable)
  update cma.work_status
  set is_paid = false, is_billable = false
  where tenant_id = v_subs and key = 'break' and is_paid and is_billable;
end
$$;

-- Export format per tenant (after migration 0003b): Dutch Excel conventions. Only sets values a
-- tenant does not have yet, so a later change on the configuration screen survives a rerun.
-- Duration format stays the catalog default until the Steam hours CSV is compared.
do $$
begin
  if to_regclass('cma.tenant_setting') is not null then
    insert into cma.tenant_setting (tenant_id, key, value)
    select t.id, s.key, s.value
    from (values
      ('export.csv.separator',    'semicolon'),
      ('export.csv.decimal_mark', 'comma'),
      ('export.csv.date_format',  'dd-mm-yyyy')
    ) as s(key, value)
    cross join cma.tenant t
    where t.slug in ('pulse4all-subscriptions', 'pulse4all-invest')
    on conflict (tenant_id, key) do nothing;
  end if;
end
$$;

-- App links per tenant (after addition 0003d): the buttons on the Welcome page. Deep links to the
-- applications the people of this tenant work in; no permission, so everyone with a role sees
-- them. Only adds links a tenant does not have yet, so a later change on the configuration screen
-- survives a rerun. Exact portal addresses replace the generic ones when Martin provides them.
do $$
begin
  if to_regclass('cma.app_link') is not null then
    insert into cma.app_link (tenant_id, key, label, address, permission_key, sort_order)
    select t.id, l.key, l.label, l.address, null, l.sort_order
    from (values
      ('hubspot', 'HubSpot', 'https://app.hubspot.com/',       10),
      ('aircall', 'Aircall', 'https://dashboard.aircall.io/',  20)
    ) as l(key, label, address, sort_order)
    cross join cma.tenant t
    where t.slug in ('pulse4all-subscriptions', 'pulse4all-invest')
    on conflict (tenant_id, key) do nothing;
  else
    raise notice 'cma.app_link does not exist yet (addition 0003d): rerun this seed after 17_clock_in_app_links.sql';
  end if;
end
$$;
