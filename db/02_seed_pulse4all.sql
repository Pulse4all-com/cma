-- CMA seed: Pulse4all configuration
-- Run as yourself (IAM login) after 01_foundation.sql, in dev and in prod. Safe to rerun.
-- Customer configuration, not schema: the two tenants, their organisations, their channels, the
-- Subscriptions work statuses, the export settings, the app links, (after 0008i) the missed-call
-- reasons and telephony settings, (after 0008j) the connected-call threshold, (after 0008l) the
-- invitation email domain, (after 0008t) the per-person reports Pulse4all Subscriptions shows,
-- (after 0008v) its journeys of Campaign monitoring, (after 0008ze) its negative-review alert rule and (after
-- 0008zi) its asset register catalogs.
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

-- Teams and skills for Pulse4all Subscriptions (after migration 0004; README: Teams and skills,
-- decided 6 October 2026): Team EN, NL, DE, FR and Nordics with their markets (ISO 3166-1 alpha-2,
-- to confirm with Arno), languages (ISO 639-1) and the work types Sales, Operations and Debt. The
-- language scale Basic, Good, Fluent, Native comes from the migration. Only adds rows a tenant does
-- not have yet, so a later change on the configuration screen survives a rerun. Invest gets its
-- lists at the copy to Invest (Roadmap step 10).
do $$
declare
  v_subs uuid := (select id from cma.tenant where slug = 'pulse4all-subscriptions');
begin
  if to_regclass('cma.team') is null then
    raise notice 'cma.team does not exist yet (migration 0004): rerun this seed after 21_teams_skills.sql';
    return;
  end if;

  insert into cma.team (tenant_id, key, name, markets, sort_order)
  select v_subs, t.key, t.name, t.markets, t.sort_order
  from (values
    ('en',      'Team EN',      array['gb', 'ie'],             10),
    ('nl',      'Team NL',      array['nl', 'be'],             20),
    ('de',      'Team DE',      array['de', 'at', 'ch'],       30),
    ('fr',      'Team FR',      array['fr'],                   40),
    ('nordics', 'Team Nordics', array['dk', 'se', 'no', 'fi'], 50)
  ) as t(key, name, markets, sort_order)
  on conflict (tenant_id, key) do nothing;

  insert into cma.skill (tenant_id, dimension, key, name, sort_order)
  select v_subs, s.dimension, s.key, s.name, s.sort_order
  from (values
    ('language',  'en', 'English',    10),
    ('language',  'nl', 'Dutch',      20),
    ('language',  'de', 'German',     30),
    ('language',  'fr', 'French',     40),
    ('language',  'da', 'Danish',     50),
    ('language',  'sv', 'Swedish',    60),
    ('language',  'no', 'Norwegian',  70),
    ('language',  'fi', 'Finnish',    80),
    ('work_type', 'sales',      'Sales',      10),
    ('work_type', 'operations', 'Operations', 20),
    ('work_type', 'debt',       'Debt',       30)
  ) as s(dimension, key, name, sort_order)
  on conflict (tenant_id, dimension, key) do nothing;
end
$$;

-- Workday window and forgotten-day close per tenant (after addition 0008b; Martin, 12 October 2026):
-- a working day runs from 07:00 to 22:00 in the day's zone; a day still open an hour after 22:00 is
-- closed at the planned shift end, else at 17:00. Only sets values a tenant does not have yet, so a
-- later change on the configuration screen survives a rerun; every value passes the catalog's check.
do $$
begin
  -- two steps: the catalog itself only exists from 0003b on
  if to_regclass('cma.setting') is null then
    raise notice 'the workday window settings do not exist yet (addition 0008b): rerun this seed after 46_workday_window.sql';
    return;
  end if;
  if not exists (select 1 from cma.setting where key = 'workday.window_end') then
    raise notice 'the workday window settings do not exist yet (addition 0008b): rerun this seed after 46_workday_window.sql';
    return;
  end if;
  insert into cma.tenant_setting (tenant_id, key, value)
  select t.id, s.key, s.value
  from (values
    (1, 'workday.window_start',             '07:00'),
    (2, 'workday.window_end',               '22:00'),
    (3, 'workday.auto_close_at',            '17:00'),
    (4, 'workday.auto_close_grace_minutes', '60')
  ) as s(ord, key, value)
  cross join cma.tenant t
  where t.slug in ('pulse4all-subscriptions', 'pulse4all-invest')
  order by t.slug, s.ord
  on conflict (tenant_id, key) do nothing;
end
$$;

-- The import status for Pulse4all Subscriptions (after addition 0008d; Martin, 12 October 2026): the
-- sessions of the earlier system (Steam Connect, 2 January to 9 October 2026) are loaded as one batch
-- in a status of their own, "Steam session", working, productive, paid and billable, with the gaps
-- between sessions in Break (docs/import/README.md). It is seeded inactive and never offered: no
-- screen lists an inactive status for a choice, and the load accepts it because nothing was ever
-- booked on it. Rerun-safe: it only adds the row when the tenant does not have it yet.
do $$
declare
  v_subs uuid := (select id from cma.tenant where slug = 'pulse4all-subscriptions');
begin
  if to_regclass('cma.import_batch') is null then
    raise notice 'the legacy time import does not exist yet (addition 0008d): rerun this seed after 50_legacy_time_import.sql';
    return;
  end if;
  insert into cma.work_status (tenant_id, key, name, is_working, is_productive, is_paid, is_billable, is_default, sort_order, status)
  values (v_subs, 'legacy_session', 'Steam session', true, true, true, true, false, 900, 'inactive')
  on conflict (tenant_id, key) do nothing;
end
$$;

-- Inbound service and callbacks per tenant (after addition 0008i; brief B15, 14 October 2026; the
-- defaults are to confirm with Kira, README Decision log): Aircall's missed-call reasons with their
-- labels, whether an unanswered call with the reason counts in the service level and whether it
-- needs a callback; the service level at 20 seconds, callbacks looked for over 3 days, a call
-- waiting at most 30 minutes. The source system is the Aircall connections' adapter, a data value.
-- Both tenants: Invest gets its own Aircall connection on the same company later (README, Open
-- decisions). Only adds what a tenant does not have yet, so a later change on Configuration >
-- Sources survives a rerun; every value passes the catalog's check.
do $$
begin
  if to_regclass('cma.telephony_missed_reason') is null then
    raise notice 'the missed-reason catalog does not exist yet (addition 0008i): rerun this seed after 60_inbound_service.sql';
    return;
  end if;
  insert into cma.telephony_missed_reason (tenant_id, source_system, code, label, counts_in_service_level, needs_callback)
  select t.id, 'aircall', r.code, r.label, r.counts_in_service_level, true
  from (values
    (1, 'out_of_opening_hours',  'Outside opening hours',  false),
    (2, 'short_abandoned',       'Hung up within 10 s',    false),
    (3, 'abandoned_in_ivr',      'Hung up in the menu',    true),
    (4, 'no_available_agent',    'No agent available',     true),
    (5, 'agents_did_not_answer', 'Agents did not answer',  true),
    (6, 'unknown',               'Unknown',                true)
  ) as r(ord, code, label, counts_in_service_level)
  cross join cma.tenant t
  where t.slug in ('pulse4all-subscriptions', 'pulse4all-invest')
  order by t.slug, r.ord
  on conflict (tenant_id, source_system, code) do nothing;

  insert into cma.tenant_setting (tenant_id, key, value)
  select t.id, s.key, s.value
  from (values
    (1, 'telephony.service_level_seconds',  '20'),
    (2, 'telephony.callback_lookback_days', '3'),
    (3, 'telephony.waiting_max_minutes',    '30')
  ) as s(ord, key, value)
  cross join cma.tenant t
  where t.slug in ('pulse4all-subscriptions', 'pulse4all-invest')
  order by t.slug, s.ord
  on conflict (tenant_id, key) do nothing;
end
$$;

-- The connected-call threshold per tenant (after addition 0008j; brief B16, 14 October 2026): 0, so an
-- outbound call counts as connected when it is answered, at any talk time, as Aircall's connected
-- (docs/definitions.md, Connected; Decision log, 24 October 2026, "Definitions: Connected"). The 10
-- seconds seeded before are retired; 100_definitions_calls.sql (0008zc) moves a tenant holding them to
-- 0. Only adds what a tenant does not have yet, so a later change on Configuration survives a rerun.
do $$
begin
  -- on a fresh database this seed runs before the settings catalog exists (13), so look it up by name first
  if to_regclass('cma.setting') is null then
    raise notice 'the settings catalog does not exist yet (migration 0003b): rerun this seed after 62_calls_overview.sql';
    return;
  end if;
  if not exists (select 1 from cma.setting where key = 'telephony.connected_min_seconds') then
    raise notice 'the connected-call threshold does not exist yet (addition 0008j): rerun this seed after 62_calls_overview.sql';
    return;
  end if;
  insert into cma.tenant_setting (tenant_id, key, value)
  select t.id, 'telephony.connected_min_seconds', '0'
  from cma.tenant t
  where t.slug in ('pulse4all-subscriptions', 'pulse4all-invest')
  order by t.slug
  on conflict (tenant_id, key) do nothing;
end
$$;

-- The invitation email domain per tenant (after addition 0008l; Martin, 15 October 2026): Pulse4all
-- invites pulse4all.com addresses only. IAP admits only pulse4all.com accounts (README:
-- Authentication), so an invitation to another domain could never be accepted; with the setting it
-- is refused when it is created instead of giving a link that expires unexplained. Only adds what a
-- tenant does not have yet, so a later change on Configuration > Exports (section Invitations)
-- survives a rerun; a reset there to the default (any domain) removes the row, so a rerun sets
-- pulse4all.com again. The value passes the catalog's check (cma.is_domain_list).
do $$
begin
  -- on a fresh database this seed runs before the settings catalog exists (13), so look it up by name first
  if to_regclass('cma.setting') is null then
    raise notice 'the settings catalog does not exist yet (migration 0003b): rerun this seed after 66_invitations.sql';
    return;
  end if;
  if not exists (select 1 from cma.setting where key = 'auth.invitation_email_domains') then
    raise notice 'the invitation settings do not exist yet (addition 0008l): rerun this seed after 66_invitations.sql';
    return;
  end if;
  insert into cma.tenant_setting (tenant_id, key, value)
  select t.id, 'auth.invitation_email_domains', 'pulse4all.com'
  from cma.tenant t
  where t.slug in ('pulse4all-subscriptions', 'pulse4all-invest')
  order by t.slug
  on conflict (tenant_id, key) do nothing;
end
$$;

-- The follow-up layer per tenant (after addition 0008o; night run N16-B, 16 October 2026): tickets answered within
-- four business hours of their market (KPI 9), at risk from 75 % of that, open leads bucketed at 1, 2 and 5 business
-- days, a callback kept within four hours of its due time (KPI 5). Product defaults as values, so a change on
-- Configuration survives a rerun (only what a tenant does not have yet is added).
do $$
begin
  -- on a fresh database this seed runs before the settings catalog exists (13), so look it up by name first
  if to_regclass('cma.setting') is null then
    raise notice 'the settings catalog does not exist yet (migration 0003b): rerun this seed after 72_follow_up.sql';
    return;
  end if;
  if not exists (select 1 from cma.setting where key = 'tickets.sla_minutes') then
    raise notice 'the follow-up settings do not exist yet (addition 0008o): rerun this seed after 72_follow_up.sql';
    return;
  end if;
  insert into cma.tenant_setting (tenant_id, key, value)
  select t.id, s.key, s.value
  from (values
    (1, 'tickets.sla_minutes',               '240'),
    (2, 'tickets.sla_warning_pct',           '75'),
    (3, 'leads.age_buckets_business_days',   '1,2,5'),
    (4, 'tasks.callback_window_minutes',     '240')
  ) as s(ord, key, value)
  cross join cma.tenant t
  where t.slug in ('pulse4all-subscriptions', 'pulse4all-invest')
  order by t.slug, s.ord
  on conflict (tenant_id, key) do nothing;
end
$$;

-- The per-person reports per tenant (after addition 0008t; night run N19-A, 18 October 2026): Pulse4all
-- Subscriptions shows the email figures per person (Reports, Email per agent), as Yordi (compliance) agreed on
-- 18 October 2026 (README Decision log); orders per agent stays off until he confirms it, and Pulse4all Invest
-- shows none (the setting's default, empty). Only where the tenant has no value yet, so a change on
-- Configuration survives a rerun.
do $$
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
  insert into cma.tenant_setting (tenant_id, key, value)
  select t.id, 'reports.per_person', 'email'
  from cma.tenant t
  where t.slug = 'pulse4all-subscriptions'
  on conflict (tenant_id, key) do nothing;
end
$$;

-- The journeys of Campaign monitoring (after addition 0008v; night run N19-A, 18 October 2026): placeholders for
-- Pulse4all Subscriptions only, named and described by Martin (README Decision log). The FCA journey for UK consumers
-- with its data prerequisites, and OPC and Exchange, whose steps and population Kira defines. No design link: Martin
-- sets it once the design exists. Only journeys the tenant does not have yet are added, so a change on Configuration
-- (a name, a link, a status) survives a rerun; the market is GB only where the tenant's catalog holds GB.
do $$
begin
  if to_regclass('cma.journey') is null then
    raise notice 'the journeys do not exist yet (addition 0008v): rerun this seed after 86_journeys.sql';
    return;
  end if;
  insert into cma.journey (tenant_id, code, name, summary, market, prerequisites, sort_order)
  select t.id, j.code, j.name, j.summary,
         (select m.code from cma.market m where m.tenant_id = t.id and m.code = j.market), j.prerequisites, j.sort_order
  from (values
    ('fca-uk-consumers', 'FCA · UK consumers',
     'Every UK consumer customer through every required communication and step, with drill-down per customer and an audit pack.',
     'GB',
     array['Consumer or business flag on every GB contact',
           'Agreement date on the contract',
           'A call tag that proves the welcome call',
           'Template ids on the journey''s emails',
           'Call-recording consent decided',
           'Step list by Gemma and Kira, checked by Yordi',
           'Drill-down permission and access log agreed with Yordi'],
     10),
    ('opc', 'OPC', 'Steps, coverage and drill-down to be defined with Kira.', null,
     array['Step list and population defined by Kira.'], 20),
    ('exchange', 'Exchange', 'Steps, coverage and drill-down to be defined with Kira.', null,
     array['Step list and population defined by Kira.'], 30)
  ) as j(code, name, summary, market, prerequisites, sort_order)
  cross join cma.tenant t
  where t.slug = 'pulse4all-subscriptions'
  order by j.sort_order
  on conflict (tenant_id, code) do nothing;
end
$$;

-- The negative-review alert rule (after addition 0008ze, brief B18, 25 October 2026): Pulse4all Subscriptions gets one
-- rule, Negative review, switched off until Kira decides the threshold and the audience (README Open decisions). Once on,
-- a published review of a counted review channel rated at or below reviews.negative_max_rating alerts the holders of
-- performance.team, without the language or clocked-in conditions and without a fallback, at most a day old. Only where
-- the tenant has no rule of that name yet, so a change on Configuration (switched on, another audience) survives a rerun.
do $$
begin
  if to_regclass('cma.message_rule') is null then
    raise notice 'the alert rules do not exist yet (addition 0008ze): rerun this seed after 104_reviews.sql';
    return;
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'cma' and table_name = 'message_rule' and column_name = 'max_rating') then
    raise notice 'the review alert rule does not exist yet (addition 0008ze): rerun this seed after 104_reviews.sql';
    return;
  end if;
  insert into cma.message_rule (tenant_id, name, trigger, record_type, pipeline_ids, audience_permission, match_language,
                                only_clocked_in, fallback_permission, urgency, max_age_minutes, max_rating, enabled)
  select t.id, 'Negative review', 'review_submitted', 'review', '{}', 'performance.team', false, false, null, 'normal', 1440,
         coalesce(nullif(cma.setting_of(t.id, 'reviews.negative_max_rating'), '')::numeric, 2), false
  from cma.tenant t
  where t.slug = 'pulse4all-subscriptions'
  on conflict (tenant_id, name) do nothing;
end
$$;

-- The asset register's catalogs for Pulse4all Subscriptions (after addition 0008zi; Martin, 27 October 2026): the two
-- models the register holds (Philips HS1 and FRx, with the labels its export writes), the components that come due (pads
-- and battery), their rules for both models (pads 24 months, battery 54 months, acted on 60 days before the due date),
-- the register's device statuses with their flags (Active/Customer in the field and tracked, In Storage in stock and
-- tracked, Internal Usage tracked, Stolen/Missing and Decommissioned not tracked), a bundling window of 90 days, and a
-- market alias for every country the export writes whose market the catalog holds. The lead days and the window are to
-- confirm with Kira and Arno (README Open decisions). An alias is added only where the catalog holds its market (dev
-- holds ES and IT since 27 October 2026; prod is to check on Configuration, Markets before the first real load), so in a
-- catalog without ES or IT the export's Spain and Italy show under device_market_unmapped until the market is added
-- (Configuration, Markets) and this seed runs again. Only rows the tenant does not have yet are added, so a change on
-- Configuration or in Studio survives a rerun.
do $$
declare
  v_subs uuid := (select id from cma.tenant where slug = 'pulse4all-subscriptions');
begin
  if to_regclass('cma.device_model') is null then
    raise notice 'the asset register does not exist yet (addition 0008zi): rerun this seed after 112_assets.sql';
    return;
  end if;
  insert into cma.device_model (tenant_id, key, name, brand, aliases, sort_order) values
    (v_subs, 'hs1', 'HS1', 'Philips', array['hs1', 'heartstart hs1', 'philips heartstart hs1'], 10),
    (v_subs, 'frx', 'FRx', 'Philips', array['frx', 'heartstart frx', 'philips heartstart frx'], 20)
  on conflict (tenant_id, key) do nothing;
  insert into cma.device_component_kind (tenant_id, key, name, sort_order) values
    (v_subs, 'pads', 'Pads', 10),
    (v_subs, 'battery', 'Battery', 20)
  on conflict (tenant_id, key) do nothing;
  insert into cma.maintenance_rule (tenant_id, model_key, component_key, interval_months, lead_days) values
    (v_subs, 'hs1', 'pads', 24, 60),
    (v_subs, 'hs1', 'battery', 54, 60),
    (v_subs, 'frx', 'pads', 24, 60),
    (v_subs, 'frx', 'battery', 54, 60)
  on conflict (tenant_id, model_key, component_key) do nothing;
  insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked, aliases, sort_order) values
    (v_subs, 'active_customer', 'Active/Customer', true, false, true, array['active/customer'], 10),
    (v_subs, 'in_storage', 'In Storage', false, true, true, array['in storage'], 20),
    (v_subs, 'internal_usage', 'Internal Usage', false, false, true, array['internal usage'], 30),
    (v_subs, 'stolen_missing', 'Stolen/Missing', false, false, false, array['stolen/missing'], 40),
    (v_subs, 'decommissioned', 'Decommissioned', false, false, false, array['decommissioned'], 50)
  on conflict (tenant_id, key) do nothing;
  insert into cma.tenant_setting (tenant_id, key, value) values (v_subs, 'assets.bundle_window_days', '90')
  on conflict (tenant_id, key) do nothing;
  insert into cma.market_alias (tenant_id, alias, code)
  select v_subs, a.alias, a.code
  from (values ('united kingdom', 'GB'), ('ireland', 'IE'), ('netherlands', 'NL'), ('belgium', 'BE'), ('germany', 'DE'), ('austria', 'AT'),
               ('france', 'FR'), ('sweden', 'SE'), ('denmark', 'DK'), ('norway', 'NO'), ('finland', 'FI'), ('spain', 'ES'),
               ('italy', 'IT')) as a(alias, code)
  where exists (select 1 from cma.market m where m.tenant_id = v_subs and m.code = a.code)
  on conflict (tenant_id, alias) do nothing;
end
$$;
