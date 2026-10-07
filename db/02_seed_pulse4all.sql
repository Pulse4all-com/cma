-- CMA seed: Pulse4all configuration
-- Run as yourself (IAM login) after 01_foundation.sql, in dev and in prod. Safe to rerun.
-- Customer configuration, not schema: the two tenants, their organisations and their channels.
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
