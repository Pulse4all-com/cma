-- =============================================================================================
-- 91_verify_report_speed.sql: verifies addition 0008x, the report functions answer a month in under a second
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure and
-- privileges; block B builds a throwaway tenant at prod's volume inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; every market, owner, connection, deal,
-- contact, call, email, store customer and order is an invented value, and no row carries a name, an
-- address or a phone number (a phone exists only as an invented 64-character hash). Every check writes
-- one row, PASS or FAIL, and the last result lists them with the verdict, because Cloud SQL Studio shows
-- no notices. Run as your own IAM login in dev, after 90_report_speed.sql; then 83 and 85 again
-- (unchanged). It runs for a few minutes: the old first-orders pass alone takes most of them.
--   A  structure and privileges: the addition row after 0008w; the row types cma.first_order (exactly
--      cma.first_orders_of's columns) and cma.email_fact; every function of 0008x the application's only
--      and in the caller's rights; the three catalogs analyzed
--   B  behaviour and speed. The generator (pg_temp.v0008x_generate) builds a tenant at prod's counts of
--      19 October 2026 (docs/perf-2026-10-19/prod-output.txt, sections 2 and 3): 14 markets with 31
--      aliases, 22 owners, a CRM, a telephony and 14 store connections, 5,257 contacts, 1,763 won order
--      deals (1,486 in October's read window) and 1,309 lead deals, 4,120 tickets, 4,156 CRM and 4,096
--      telephony calls (4,074 linked, up to about a dozen per number), 1,362 conversations with 2,793
--      messages and their events, 2,470 CRM emails (a few contacts with hundreds), 525 form submissions,
--      11,313 store customers and 2,806 orders (mostly renewals); with the shape of section 3 (the calls
--      per number, the emails per contact). The definitions of 0008t and 0008u are copied below verbatim
--      into pg_temp (pg_temp.v0008x_old_*). Checked: the tenant's counts; first_orders_of over October's
--      read window and the previous span's equal to 0008u's; the report per day and per week for one
--      market, the amounts and per person equal; cma.first_orders_page as the application equal to the
--      report, the amounts and the list; email_of, the counted conversations, the openings and the closes
--      equal to 0008t's; the report per day and per week for one market, the overview, per dimension,
--      the received series and per person equal; cma.email_report_page (filtered and not) and
--      email_per_person_page as the application equal to the reads they replace; every report read of
--      October as the application (row-level security on) under verify.max_ms, the best of three runs;
--      the email report, per person and the first orders pass at least five times faster than their old
--      definitions on the same data
-- verify.max_ms is 1000, the target. Dev is a shared-core db-g1-small (README, Dev database server); a run
-- there that fails B8 alone, by a little, is the tier: rerun it, and the prod timings of the morning
-- runbook decide.
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says
-- PROVOKED instead of PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every check fail
select set_config('verify.max_ms', '1000', false);     -- a month's report read, as the application

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the
-- session, so every block below stops at once and the verdict says REFUSED, also where the client
-- carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 91 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008x;
create temp table verify_0008x (ord int, check_name text, result text, detail text);
drop table if exists pg_temp.v0008x_old_cache;
drop table if exists pg_temp.v0008x_old_keys;

-- Whether two reads give the same rows (as multisets, more than none), with their counts
create or replace function pg_temp.v0008x_same(p_new text, p_old text, out same boolean, out detail text)
language plpgsql
as $$
declare
  v_new  bigint;
  v_old  bigint;
  v_only_new bigint;
  v_only_old bigint;
begin
  execute 'create temp table v0008x_new as ' || p_new;
  execute 'create temp table v0008x_old as ' || p_old;
  select count(*) into v_new from v0008x_new;
  select count(*) into v_old from v0008x_old;
  select count(*) into v_only_new from (select * from v0008x_new except all select * from v0008x_old) x;
  select count(*) into v_only_old from (select * from v0008x_old except all select * from v0008x_new) x;
  drop table v0008x_new;
  drop table v0008x_old;
  same := v_new > 0 and v_new = v_old and v_only_new = 0 and v_only_old = 0;
  detail := format('%s/%s rows, %s/%s apart', v_new, v_old, v_only_new, v_only_old);
end
$$;

-- The fastest of p_runs runs of a read, in milliseconds, every row and column fetched
create or replace function pg_temp.v0008x_best_ms(p_sql text, p_runs integer)
returns numeric
language plpgsql
as $$
declare
  v_t0   timestamptz;
  v_ms   numeric;
  v_best numeric;
  r      record;
begin
  for i in 1 .. p_runs loop
    v_t0 := clock_timestamp();
    for r in execute p_sql loop
      null;
    end loop;
    v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000);
    v_best := least(coalesce(v_best, v_ms), v_ms);
  end loop;
  return v_best;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- The generator: a tenant at prod's counts of 19 October 2026, invented values only
-- ---------------------------------------------------------------------------------------------
-- A deterministic number in [0, 1) for a salt and an index
create or replace function pg_temp.v0008x_r(p_salt text, p_i bigint)
returns double precision
language sql immutable
as $$
  select ('x' || substr(md5(p_salt || ':' || p_i), 1, 8))::bit(32)::bigint / 4294967296.0
$$;

-- An invented 64-character phone hash for a number n
create or replace function pg_temp.v0008x_h(p_n bigint)
returns text
language sql immutable
as $$
  select md5('verify-phone:' || p_n) || md5('verify-number:' || p_n)
$$;

-- The data: markets, owners, connections, pipelines and stages, contacts, deals, tickets, associations,
-- CRM and telephony calls with their links, inbox conversations with messages and events, CRM emails,
-- form submissions, store customers and orders. p_scale multiplies every count (1 = prod's)
create or replace function pg_temp.v0008x_generate(p_tenant uuid, p_scale numeric default 1)
returns void
language plpgsql
as $$
declare
  t      uuid := p_tenant;
  crm    uuid;
  tel    uuid;
  n_contacts  integer := round(5257 * p_scale);
  n_phones    integer := round(1730 * p_scale);
  n_orders    integer := round(1763 * p_scale);   -- won order deals
  n_window    integer := round(1486 * p_scale);   -- of them created in October's read window
  n_leads     integer := round(1309 * p_scale);
  n_tickets   integer := round(4120 * p_scale);
  n_calls     integer := round(4156 * p_scale);
  n_linked    integer := round(4074 * p_scale);
  n_tel       integer := round(4096 * p_scale);
  n_threads   integer := round(1362 * p_scale);
  n_inbox_in  integer := round(1762 * p_scale);
  n_inbox_out integer := round(1031 * p_scale);
  n_crm_in    integer := round(1298 * p_scale);
  n_crm_out   integer := round(1172 * p_scale);
  n_forms     integer := round(525 * p_scale);
  n_customers integer := round(11313 * p_scale);
  n_all_orders integer := round(2806 * p_scale);
  v_start timestamptz := '2026-09-29 22:00:00+00';   -- 1 October 2026 00:00 in Amsterdam, a day before
  v_now   timestamptz := '2026-10-19 09:00:00+00';   -- the data ends here, as prod's on the day of the diagnosis
begin
  -- markets (14), aliases (31), office hours
  insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, status, sort_order)
  select t, m.code, m.name, m.zone, m.lang, m.cur, 'active', m.ord
  from (values ('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 1), ('BE', 'Belgium', 'Europe/Brussels', 'nl', 'EUR', 2),
               ('DE', 'Germany', 'Europe/Berlin', 'de', 'EUR', 3), ('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 4),
               ('IE', 'Ireland', 'Europe/Dublin', 'en', 'EUR', 5), ('DK', 'Denmark', 'Europe/Copenhagen', 'da', 'DKK', 6),
               ('SE', 'Sweden', 'Europe/Stockholm', 'sv', 'SEK', 7), ('NO', 'Norway', 'Europe/Oslo', 'nb', 'NOK', 8),
               ('FI', 'Finland', 'Europe/Helsinki', 'fi', 'EUR', 9), ('FR', 'France', 'Europe/Paris', 'fr', 'EUR', 10),
               ('ES', 'Spain', 'Europe/Madrid', 'es', 'EUR', 11), ('IT', 'Italy', 'Europe/Rome', 'it', 'EUR', 12),
               ('AT', 'Austria', 'Europe/Vienna', 'de', 'EUR', 13), ('CH', 'Switzerland', 'Europe/Zurich', 'de', 'CHF', 14))
       as m(code, name, zone, lang, cur, ord);
  insert into cma.market_alias (tenant_id, alias, code)
  select t, a.alias, a.code
  from (values ('netherlands', 'NL'), ('nederland', 'NL'), ('holland', 'NL'), ('the netherlands', 'NL'), ('belgium', 'BE'),
               ('belgie', 'BE'), ('germany', 'DE'), ('deutschland', 'DE'), ('united kingdom', 'GB'), ('uk', 'GB'),
               ('great britain', 'GB'), ('england', 'GB'), ('ireland', 'IE'), ('denmark', 'DK'), ('danmark', 'DK'),
               ('sweden', 'SE'), ('sverige', 'SE'), ('norway', 'NO'), ('norge', 'NO'), ('finland', 'FI'), ('suomi', 'FI'),
               ('france', 'FR'), ('spain', 'ES'), ('espana', 'ES'), ('italy', 'IT'), ('italia', 'IT'), ('austria', 'AT'),
               ('osterreich', 'AT'), ('switzerland', 'CH'), ('schweiz', 'CH'), ('suisse', 'CH')) as a(alias, code);
  insert into cma.business_hours (tenant_id, market, weekday, opens_at, closes_at)
  select t, '*', d, time '08:30', time '17:30' from generate_series(1, 5) d
  union all
  select t, 'GB', d, time '09:00', time '17:00' from generate_series(1, 5) d;
  insert into cma.business_holiday (tenant_id, market, day, name) values (t, '*', '2026-10-12', 'Verify holiday');

  -- owners: 22 people with a CRM owner id and a telephony user; owner ids 1023 to 1030 belong to nobody
  insert into cma.app_user (tenant_id, email, display_name)
  select t, format('verify-0008x-agent%s@example.invalid', lpad(i::text, 2, '0')), format('Agent %s', lpad(i::text, 2, '0'))
  from generate_series(1, 22) i;
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
  select u.tenant_id, u.id, x.sys, x.pre || (substring(u.email from 'agent(\d+)@')::integer + x.off)::text
  from cma.app_user u
  cross join (values ('verifycrm_owner', '', 1000), ('verifytel_user', 'u', 0)) as x(sys, pre, off)
  where u.tenant_id = t and u.email like 'verify-0008x-agent%';

  -- connections: one CRM, one telephony, fourteen stores
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, settings)
  values (t, 'verifycrm', 'Verify CRM', 'portal-1', 'crm',
          jsonb_build_object('email_inbox_copy_origins', 'CONVERSATIONS', 'record_url_deal', 'https://crm.example.invalid/{account}/deal/{id}'))
  returning id into crm;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
  values (t, 'verifytel', 'Verify phones', 'company-1', 'telephony') returning id into tel;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
  select t, 'verifyshop', 'Verify shop ' || i, 'shop-' || i, 'commerce' from generate_series(1, 14) i;
  insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
  select t, c.id, 'verify-shop-' || lower(m.code), 'Verify ' || m.code, m.code, m.currency, m.time_zone
  from (select id, row_number() over (order by external_account_id) as n from cma.integration_connection where tenant_id = t and adapter = 'verifyshop') c
  join (select code, currency, time_zone, sort_order as n from cma.market where tenant_id = t) m on m.n = c.n;
  insert into cma.connection_call_outcome (tenant_id, connection_id, outcome_ref, label, is_connected)
  values (t, crm, 'connected', 'Connected', true), (t, crm, 'no_answer', 'No answer', false), (t, crm, 'busy', 'Busy', false),
         (t, crm, 'voicemail', 'Left voicemail', false);

  -- pipelines (9) and stages (52): two order pipelines, two lead pipelines, one not counted, four ticket pipelines
  insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted, is_lead, is_order)
  values (t, crm, 'deal', 'orders', 'Orders', true, false, true), (t, crm, 'deal', 'orders_b2b', 'Orders B2B', true, false, true),
         (t, crm, 'deal', 'sales', 'Sales', true, true, false), (t, crm, 'deal', 'sales_nordics', 'Sales Nordics', true, true, false),
         (t, crm, 'deal', 'partners', 'Partners', false, true, false), (t, crm, 'ticket', 'support', 'Support', true, false, false),
         (t, crm, 'ticket', 'support_nordics', 'Support Nordics', true, false, false), (t, crm, 'ticket', 'claims', 'Claims', true, false, false),
         (t, crm, 'ticket', 'returns', 'Returns', true, false, false);
  insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, display_order, is_closed,
                                    outcome, outcome_source)
  select t, crm, p.rt, p.pid, s.sid, s.sid, s.ord, s.closed, s.outcome, case when s.outcome is not null then 'source' end
  from (values ('deal', 'orders', 3), ('deal', 'orders_b2b', 3), ('deal', 'sales', 8), ('deal', 'sales_nordics', 8), ('deal', 'partners', 6),
               ('ticket', 'support', 6), ('ticket', 'support_nordics', 6), ('ticket', 'claims', 6), ('ticket', 'returns', 6)) as p(rt, pid, n)
  cross join lateral (
    select case when g = 1 and p.rt = 'deal' and p.pid like 'orders%' then 'won'
                when g = 2 and p.rt = 'deal' and p.pid like 'orders%' then 'lost'
                when g = p.n - 1 and p.rt = 'deal' then 'closedwon'
                when g = p.n and p.rt = 'deal' then 'closedlost'
                else 'stage' || g end as sid,
           g as ord,
           (p.rt = 'deal' and (g <= 2 and p.pid like 'orders%' or g >= p.n - 1)) or (p.rt = 'ticket' and g = p.n) as closed,
           case when p.rt = 'deal' and ((g = 1 and p.pid like 'orders%') or (g = p.n - 1 and p.pid not like 'orders%')) then 'won'
                when p.rt = 'deal' and ((g = 2 and p.pid like 'orders%') or (g = p.n and p.pid not like 'orders%')) then 'lost' end as outcome
    from generate_series(1, p.n) g) s;

  -- inboxes (4: two with a market, one without, one not counted) and channels (12, two not counted); forms (3)
  insert into cma.connection_inbox (tenant_id, connection_id, source_inbox_id, name, is_counted, market)
  values (t, crm, 'ib1', 'Inbox NL', true, 'NL'), (t, crm, 'ib2', 'Inbox UK', true, 'GB'), (t, crm, 'ib3', 'Inbox shared', true, null),
         (t, crm, 'ib4', 'Inbox archive', false, null);
  insert into cma.connection_inbox_channel (tenant_id, connection_id, source_channel_id, name, kind, is_counted)
  select t, crm, 'ch' || i, 'Channel ' || i, 'email', i <= 10 from generate_series(1, 12) i;
  insert into cma.connection_form (tenant_id, connection_id, source_form_id, name, is_counted, market)
  values (t, crm, 'f1', 'Form NL', true, 'NL'), (t, crm, 'f2', 'Form UK', true, 'GB'), (t, crm, 'f3', 'Form other', false, null);

  -- contacts: a country in many spellings (some no catalog market, some none), a creation time for a third, a few deleted
  insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, country_source, source_created_at,
                               source_updated_at, source_deleted_at)
  select t, crm, 'verifycrm', 'k' || i, c.country, case when c.country is not null then 1 end,
         case when pg_temp.v0008x_r('created', i) < 0.3 then timestamptz '2026-03-01' + pg_temp.v0008x_r('created_at', i) * interval '220 days' end,
         v_now, case when i % 250 = 0 then v_now end
  from generate_series(1, n_contacts) i
  cross join lateral (
    select (array['NL', 'NL', 'NL', 'nl', 'Netherlands', 'Nederland', 'GB', 'GB', 'United Kingdom', 'uk', 'DE', 'Germany', 'DK', 'Denmark',
                  'SE', 'NO', 'BE', 'FI', 'FR', 'ES', 'IT', 'AT', 'CH', 'IE', 'Atlantis', null])[1 + floor(pg_temp.v0008x_r('country', i) * 26)::integer]
           as country) c;

  -- order deals: distinct contacts (a permutation), 2% of a contact who ordered before (repeat), two without a primary contact
  -- (an association instead); n_window from 1 October, the rest from 22 August
  insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, contact_source_id,
                              market, is_closed, source_created_at, source_updated_at, amount, currency)
  select t, crm, 'verifycrm', 'deal', 'o' || j, case when j % 10 = 0 then 'orders_b2b' else 'orders' end, 'won',
         case when j % 900 = 0 then null else 'k' || o.c end,
         case when pg_temp.v0008x_r('own_market', j) < 0.25 then (array['NL', 'GB', 'DE', 'nl', 'XX'])[1 + floor(pg_temp.v0008x_r('mk', j) * 5)::integer] end,
         true, o.at, o.at, round((20 + pg_temp.v0008x_r('amount', j) * 200)::numeric, 2), 'EUR'
  from generate_series(1, n_orders) j
  cross join lateral (
    select case when pg_temp.v0008x_r('repeat', j) < 0.02 and j > 200 then ((j - 150) * 7919) % n_contacts + 1
                else (j * 7919) % n_contacts + 1 end as c,
           case when j <= n_window then v_start + interval '2 hours' + pg_temp.v0008x_r('t', j) * (v_now - v_start - interval '2 hours')
                else timestamptz '2026-08-22 06:00+00' + pg_temp.v0008x_r('t', j) * interval '38 days' end as at) o;
  -- four order deals not won, lead deals (40% on an order deal's contact, before it), six deleted lead deals
  insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref, contact_source_id,
                              market, is_closed, source_created_at, source_updated_at, source_deleted_at)
  select t, crm, 'verifycrm', 'deal', 'p' || i, 'orders', 'stage3', null, 'k' || (i * 13), null, false, v_start + i * interval '1 day', v_now, null
  from generate_series(1, 4) i
  union all
  select t, crm, 'verifycrm', 'deal', 'l' || i, case when i % 3 = 0 then 'sales_nordics' when i % 11 = 0 then 'partners' else 'sales' end,
         'stage' || (1 + i % 5), (1001 + floor(pg_temp.v0008x_r('lead_owner', i) * 30)::integer)::text,
         'k' || case when pg_temp.v0008x_r('lead_on_order', i) < 0.4 then ((i * 3 % n_orders + 1) * 7919) % n_contacts + 1
                     else 1 + floor(pg_temp.v0008x_r('lead_contact', i) * n_contacts)::integer end,
         case when i % 2 = 0 then (array['NL', 'GB', 'DE', 'DK'])[1 + i % 4] end, false,
         timestamptz '2026-07-01' + pg_temp.v0008x_r('lead_at', i) * (v_now - timestamptz '2026-07-01'), v_now,
         case when i % 218 = 0 then v_now end
  from generate_series(1, n_leads) i;
  -- tickets
  insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref, contact_source_id,
                              market, is_closed, source_created_at, source_updated_at)
  select t, crm, 'verifycrm', 'ticket', 'tk' || i, (array['support', 'support_nordics', 'claims', 'returns'])[1 + i % 4], 'stage1',
         (1001 + i % 30)::text, 'k' || (1 + floor(pg_temp.v0008x_r('ticket_contact', i) * n_contacts)::integer),
         case when i % 3 > 0 then (array['NL', 'GB', 'DE', 'SE', 'zz'])[1 + i % 5] end, false,
         timestamptz '2026-06-01' + pg_temp.v0008x_r('ticket_at', i) * (v_now - timestamptz '2026-06-01'), v_now
  from generate_series(1, n_tickets) i;
  -- every deal and ticket associated with its contact (the two without a primary contact with one), a few removed ones
  insert into cma.crm_association (tenant_id, connection_id, from_type, from_id, to_type, to_id, first_seen_at, source_changed_at, removed_at)
  select t, crm, r.record_type, r.source_id, 'contact', coalesce(r.contact_source_id, 'k' || (1 + abs(hashtext(r.source_id)) % n_contacts)),
         r.source_created_at, r.source_created_at, null
  from cma.crm_record r where r.tenant_id = t
  union all
  select t, crm, 'ticket', 'tk' || i, 'contact', 'k' || (1 + (i * 37) % n_contacts), v_start, v_start, case when i % 10 = 0 then v_now end
  from generate_series(1, round(86 * p_scale)::integer) i
  on conflict do nothing;

  -- CRM calls: each from a contact with a phone (skewed: up to about 16 calls per number), almost all in October;
  -- associated with that contact, most with a lead deal too
  insert into cma.crm_call (tenant_id, connection_id, source_system, source_id, occurred_at, direction, outcome_ref, owner_ref, counterpart_hash,
                            source_updated_at)
  select t, crm, 'verifycrm', 'c' || i, x.at, (array['inbound', 'outbound'])[1 + i % 2],
         (array['connected', 'connected', 'no_answer', 'busy', 'voicemail', null])[1 + floor(pg_temp.v0008x_r('outcome', i) * 6)::integer],
         (1001 + floor(pg_temp.v0008x_r('call_owner', i) * 30)::integer)::text,
         case when i % 300 <> 7 then pg_temp.v0008x_h(x.p) end, x.at
  from generate_series(1, n_calls) i
  cross join lateral (
    select 1 + floor(power(pg_temp.v0008x_r('phone', i), 1.25) * n_phones)::integer as p,
           case when i % 90 = 0 then timestamptz '2026-09-01' + pg_temp.v0008x_r('call_at', i) * interval '28 days'
                else v_start + interval '2 hours' + pg_temp.v0008x_r('call_at', i) * (v_now - v_start - interval '2 hours') end as at) x;
  insert into cma.crm_association (tenant_id, connection_id, from_type, from_id, to_type, to_id, first_seen_at, source_changed_at)
  select t, crm, 'crm_call', c.source_id, 'contact',
         'k' || (3 * (1 + floor(power(pg_temp.v0008x_r('phone', substr(c.source_id, 2)::bigint), 1.25) * n_phones)::integer) - 2),
         c.occurred_at, c.occurred_at
  from cma.crm_call c where c.tenant_id = t and substr(c.source_id, 2)::integer % 1300 <> 5
  union all
  select t, crm, 'crm_call', c.source_id, 'deal', 'l' || (1 + abs(hashtext(c.source_id)) % n_leads), c.occurred_at, c.occurred_at
  from cma.crm_call c where c.tenant_id = t and pg_temp.v0008x_r('call_deal', substr(c.source_id, 2)::bigint) < 0.72
  on conflict do nothing;
  -- the hash of phone number p belongs to contact 3p - 2: the calls are associated with it, its store orders carry it
  -- telephony calls: n_linked linked to a CRM call (seconds apart), the rest on their own
  insert into cma.telephony_call (tenant_id, connection_id, source_system, source_id, direction, status, started_at, answered_at, ended_at,
                                  user_ref, counterpart_hash, source_version_at)
  select t, tel, 'verifytel', 'tp' || c.n, c.direction, 'done', c.occurred_at - interval '5 seconds',
         case when pg_temp.v0008x_r('answered', c.n) < 0.7 then c.occurred_at end,
         c.occurred_at + (pg_temp.v0008x_r('talk', c.n) * interval '400 seconds'),
         'u' || (1 + c.n % 30), coalesce(c.counterpart_hash, pg_temp.v0008x_h(900000 + c.n)), c.occurred_at
  from (select cc.*, row_number() over (order by cc.source_id) as n from cma.crm_call cc where cc.tenant_id = t) c
  where c.n <= n_tel;
  insert into cma.call_link (tenant_id, telephony_call_id, crm_call_id, method, delta_seconds)
  select t, tc.id, c.id, 'hash_time', 5
  from (select cc.id, row_number() over (order by cc.source_id) as n from cma.crm_call cc where cc.tenant_id = t) c
  join cma.telephony_call tc on tc.tenant_id = t and tc.source_id = 'tp' || c.n
  where c.n <= n_linked;

  -- inbox conversations: contacts skewed (one contact with about a tenth of them), almost all in October, a few spam;
  -- messages per conversation 1 to about 20, incoming first; events: assigned, reopened (often without a close before), closed
  insert into cma.email_thread (tenant_id, connection_id, source_system, source_id, inbox_source_id, channel_source_id, status, source_created_at,
                                closed_at, contact_source_id, ticket_source_id, is_spam, category, source_updated_at)
  select t, crm, 'verifycrm', 'th' || i, 'ib' || (1 + floor(pg_temp.v0008x_r('inbox', i) * 4)::integer),
         'ch' || (1 + floor(pg_temp.v0008x_r('channel', i) * 12)::integer),
         case when x.closed then 'closed' else 'open' end, x.at, case when x.closed then x.at + interval '26 hours' end,
         'k' || x.contact, case when i % 5 = 0 then 'tk' || (1 + i % n_tickets) end, i % 30 = 0,
         (array['sales', 'service', null])[1 + i % 3], x.at
  from generate_series(1, n_threads) i
  cross join lateral (
    select case when i % 13 = 0 then timestamptz '2026-09-01' + pg_temp.v0008x_r('thread_at', i) * interval '28 days'
                else v_start + interval '2 hours' + pg_temp.v0008x_r('thread_at', i) * (v_now - v_start - interval '28 hours') end as at,
           pg_temp.v0008x_r('closed', i) < 0.55 as closed,
           case when pg_temp.v0008x_r('thread_contact', i) < 0.08 then 2001
                else 2002 + floor(power(pg_temp.v0008x_r('thread_who', i), 2.2) * 700)::integer end as contact) x;
  insert into cma.email_message (tenant_id, connection_id, source_system, source_kind, source_id, thread_source_id, inbox_source_id,
                                 channel_source_id, direction, status, occurred_at, actor_kind, owner_ref, contact_source_id, source_updated_at)
  select t, crm, 'verifycrm', 'inbox_message', 'm' || m.i, th.source_id, th.inbox_source_id, th.channel_source_id, m.dir,
         case when m.dir = 'out' and m.i % 400 = 0 then 'failed' else 'sent' end,
         th.source_created_at + m.k * interval '47 minutes', m.actor, case when m.actor = 'agent' then (1001 + m.i % 30)::text end,
         th.contact_source_id, th.source_created_at
  from (
    select i, case when i <= n_inbox_in then 'in' else 'out' end as dir,
           case when i <= n_inbox_in then 'customer' when i % 20 = 0 then 'bot' else 'agent' end as actor,
           1 + floor(power(pg_temp.v0008x_r('msg_thread', i), 1.6) * n_threads)::integer as th_n,
           case when i <= n_inbox_in then 0 else 1 end + floor(pg_temp.v0008x_r('msg_k', i) * 3)::integer as k
    from generate_series(1, n_inbox_in + n_inbox_out) i) m
  join cma.email_thread th on th.tenant_id = t and th.connection_id = crm and th.source_id = 'th' || m.th_n;
  insert into cma.email_thread_event (tenant_id, connection_id, source_id, thread_source_id, kind, occurred_at, actor_kind, owner_ref)
  select t, crm, 'ev-a' || th.n, th.source_id, 'assigned', th.source_created_at + interval '5 minutes', 'agent', (1001 + th.n % 30)::text
  from (select x.*, row_number() over (order by x.source_id) as n from cma.email_thread x where x.tenant_id = t) th
  where th.n % 100 < 53
  union all
  select t, crm, 'ev-c' || th.n || '-' || g, th.source_id, 'closed', th.closed_at - (g - 1) * interval '7 hours',
         case when g = 1 and th.n % 9 = 0 then 'system' else 'agent' end, case when not (g = 1 and th.n % 9 = 0) then (1001 + (th.n + g) % 30)::text end
  from (select x.*, row_number() over (order by x.source_id) as n from cma.email_thread x where x.tenant_id = t and x.status = 'closed') th
  cross join generate_series(1, 2) g
  where g = 1 or th.n % 15 = 0
  union all
  select t, crm, 'ev-r' || th.n || '-' || g, th.source_id, 'reopened', th.source_created_at + g * interval '3 hours', 'customer', null
  from (select x.*, row_number() over (order by x.source_id) as n from cma.email_thread x where x.tenant_id = t) th
  cross join generate_series(1, 2) g
  where g = 1 or th.n % 5 < 1;
  -- CRM emails: in and out, the same skewed contacts, an origin (a third inbox copies), engagement thread ids; associations to the
  -- contact (and to contacts of emails the CMA does not hold), to deals and tickets
  insert into cma.email_message (tenant_id, connection_id, source_system, source_kind, source_id, thread_source_id, direction, status, occurred_at,
                                 actor_kind, owner_ref, contact_source_id, origin, source_updated_at)
  select t, crm, 'verifycrm', 'crm_email', 'e' || i, 'cth' || (i / 2), x.dir,
         case when x.dir = 'out' and i % 390 = 0 then 'bounced' else 'sent' end, x.at,
         case when x.dir = 'in' then 'customer' else 'agent' end, case when x.dir = 'out' then (1001 + i % 30)::text end,
         'k' || x.contact, (array['CONVERSATIONS', 'CRM_UI', 'CRM_UI', 'SALES'])[1 + i % 4], x.at
  from generate_series(1, n_crm_in + n_crm_out) i
  cross join lateral (
    select case when i <= n_crm_in then 'in' else 'out' end as dir,
           case when i % 90 = 0 then timestamptz '2026-09-01' + pg_temp.v0008x_r('email_at', i) * interval '28 days'
                else v_start + interval '2 hours' + pg_temp.v0008x_r('email_at', i) * (v_now - v_start - interval '2 hours') end as at,
           case when pg_temp.v0008x_r('email_contact', i) < 0.15 then 2001
                when pg_temp.v0008x_r('email_contact', i) < 0.2 then 2002
                when pg_temp.v0008x_r('email_contact', i) < 0.5 then ((1 + floor(pg_temp.v0008x_r('email_order', i) * n_orders)::integer) * 7919) % n_contacts + 1
                else 2003 + floor(power(pg_temp.v0008x_r('email_who', i), 2.2) * 857)::integer end as contact) x;
  insert into cma.crm_association (tenant_id, connection_id, from_type, from_id, to_type, to_id, first_seen_at, source_changed_at)
  select t, crm, 'crm_email', em.source_id, 'contact', em.contact_source_id, em.occurred_at, em.occurred_at
  from cma.email_message em where em.tenant_id = t and em.source_kind = 'crm_email'
  union all
  select t, crm, 'crm_email', 'e-old' || i, 'contact',
         'k' || case when i % 4 = 0 then 2001 else 2002 + floor(power(pg_temp.v0008x_r('old_who', i), 2.2) * 800)::integer end,
         timestamptz '2026-02-01', timestamptz '2026-02-01'
  from generate_series(1, round(2765 * p_scale)::integer) i
  union all
  select t, crm, 'crm_email', em.source_id, x.to_type, x.to_id, em.occurred_at, em.occurred_at
  from cma.email_message em
  cross join lateral (
    select 'deal' as to_type, 'l' || (1 + abs(hashtext(em.source_id)) % n_leads) as to_id
    where pg_temp.v0008x_r('email_deal', substr(em.source_id, 2)::bigint) < 0.29
    union all
    select 'ticket', 'tk' || (1 + abs(hashtext(em.source_id || 't')) % n_tickets)
    where pg_temp.v0008x_r('email_ticket', substr(em.source_id, 2)::bigint) < 0.9) x
  where em.tenant_id = t and em.source_kind = 'crm_email'
  on conflict do nothing;

  -- form submissions
  insert into cma.form_submission (tenant_id, connection_id, source_id, source_form_id, submitted_at, contact_source_id, contact_resolution)
  select t, crm, 'fs' || i, (array['f1', 'f2', 'f3'])[1 + i % 3], timestamptz '2026-09-01' + pg_temp.v0008x_r('form_at', i) * (v_now - timestamptz '2026-09-01'),
         case when i % 33 <> 0 then 'k' || (1 + floor(pg_temp.v0008x_r('form_contact', i) * n_contacts)::integer) end,
         case when i % 33 <> 0 then 'resolved' else 'not_found' end
  from generate_series(1, n_forms) i;

  -- the stores: every order deal's contact a customer in a store (most with an order a few minutes after the deal: 86% renewals,
  -- 11% first, 1.3% repeat), more customers matched to contacts the CMA does not hold, and their orders
  insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, phone_hash, crm_connection_id, crm_contact_source_id,
                                     matched_at, source_updated_at)
  select t, s.connection_id, 'verifyshop', 'cu' || c.c,
         case when pg_temp.v0008x_r('cu_phone', c.c) < 0.33 then pg_temp.v0008x_h(case when c.c % 3 = 1 then (c.c + 2) / 3 else 700000 + c.c end) end,
         crm, 'k' || c.c, v_now, v_now
  from (select distinct substr(r.contact_source_id, 2)::integer as c from cma.crm_record r
        where r.tenant_id = t and r.pipeline_id like 'orders%' and r.contact_source_id is not null) c
  join (select connection_id, row_number() over (order by connection_id) - 1 as n from cma.commerce_store where tenant_id = t) s on s.n = c.c % 14;
  insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, phone_hash, crm_connection_id, crm_contact_source_id,
                                     matched_at, source_updated_at)
  select t, s.connection_id, 'verifyshop', 'cx' || i, case when pg_temp.v0008x_r('cx_phone', i) < 0.33 then pg_temp.v0008x_h(500000 + i) end,
         case when i % 40 <> 0 then crm end, case when i % 40 <> 0 then 'k' || (100000 + i) end, case when i % 40 <> 0 then v_now end, v_now
  from generate_series(1, greatest(0, n_customers - (select count(*) from cma.commerce_customer where tenant_id = t))) i
  join (select connection_id, row_number() over (order by connection_id) - 1 as n from cma.commerce_store where tenant_id = t) s on s.n = i % 14;
  insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, customer_source_id, source_created_at, source_updated_at,
                                  currency, total_amount, order_kind, phone_hash)
  select t, cu.connection_id, 'verifyshop', 'or' || r.source_id, cu.source_id, r.source_created_at + (2 + abs(hashtext(r.source_id)) % 30) * interval '1 minute',
         v_now, 'EUR', r.amount,
         case when x.k < 0.859 then 'renewal' when x.k < 0.972 then 'first' when x.k < 0.985 then 'repeat' else 'unknown' end,
         case when pg_temp.v0008x_r('order_phone', substr(r.source_id, 2)::bigint) < 0.44
              then pg_temp.v0008x_h(case when substr(r.contact_source_id, 2)::integer % 3 = 1 then (substr(r.contact_source_id, 2)::integer + 2) / 3
                                         else 700000 + substr(r.contact_source_id, 2)::integer end) end
  from cma.crm_record r
  join cma.commerce_customer cu on cu.tenant_id = t and cu.crm_connection_id = crm and cu.crm_contact_source_id = r.contact_source_id
  cross join lateral (select pg_temp.v0008x_r('kind', substr(r.source_id, 2)::bigint) as k) x
  where r.tenant_id = t and r.pipeline_id like 'orders%' and r.stage_id = 'won' and pg_temp.v0008x_r('has_order', substr(r.source_id, 2)::bigint) < 0.995;
  insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, customer_source_id, source_created_at, source_updated_at,
                                  currency, total_amount, order_kind, phone_hash)
  select t, cu.connection_id, 'verifyshop', 'ox' || i, cu.source_id, v_start + pg_temp.v0008x_r('ox_at', i) * (v_now - v_start), v_now, 'EUR', 49,
         case when i % 25 = 0 then 'first' else 'renewal' end, case when i % 3 = 0 then pg_temp.v0008x_h(500000 + i) end
  from generate_series(1, n_all_orders - (select count(*) from cma.commerce_order where tenant_id = t)) i
  join cma.commerce_customer cu on cu.tenant_id = t and cu.source_id = 'cx' || (1 + i * 7 % greatest(1, n_customers - n_orders));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- The definitions of 0008u and 0008t as 84_first_orders.sql and 82_email_reports.sql wrote them,
-- verbatim but in pg_temp (cma.<name> is pg_temp.v0008x_old_<name>; the list is cma.first_orders_list's
-- query for an explicit tenant): the reference the new definitions are compared with
-- ---------------------------------------------------------------------------------------------
create or replace function pg_temp.v0008x_old_first_orders_compute(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  deal_id                uuid,
  connection_id          uuid,
  source_system          text,
  deal_source_id         text,
  pipeline_id            text,
  pipeline_label         text,
  contact_source_id      text,
  created_at             timestamptz,
  market                 text,
  zone                   text,
  business_date          date,
  week_start             date,
  local_time             time,
  kind                   text,
  order_id               uuid,
  order_source_id        text,
  store_order_kind       text,
  currency               text,
  amount                 numeric,
  phone_hashed           boolean,
  lead_deal              boolean,
  conversation           boolean,
  email                  boolean,
  phone_match            boolean,
  attempt                boolean,
  known_contact          boolean,
  level                  text,
  attribution            text,
  first_touch_at         timestamptz,
  days_from_first_touch  numeric,
  credited_system        text,
  credited_owner_ref     text,
  credited_user_id       uuid
)
language sql stable
set jit = off
as $$
  with s as (
    select t.timezone as tenant_zone,
           make_interval(days => cma.setting_of(t.id, 'attribution.window_days')::integer) as win,
           string_to_array(cma.setting_of(t.id, 'attribution.level_order'), ',') as level_order,
           coalesce(string_to_array(nullif(cma.setting_of(t.id, 'attribution.assisted_levels'), ''), ','), '{}'::text[]) as assisted,
           make_interval(mins => cma.setting_of(t.id, 'attribution.known_contact_minutes')::integer) as known,
           make_interval(mins => cma.setting_of(t.id, 'attribution.order_match_minutes')::integer) as match
    from cma.tenant t where t.id = p_tenant_id
  ),
  -- the won deals of the order pipelines created in the period, with their contact
  d as materialized (
    select r.id, r.connection_id, r.source_system, r.source_id, r.pipeline_id, coalesce(p.label, r.pipeline_id) as pipeline_label,
           r.source_created_at as t, r.market as own_market, r.amount as deal_amount, r.currency as deal_currency,
           coalesce(r.contact_source_id,
                    (select a.to_id from cma.crm_association a
                     where a.tenant_id = r.tenant_id and a.connection_id = r.connection_id and a.from_type = 'deal'
                       and a.from_id = r.source_id and a.to_type = 'contact' and a.removed_at is null
                     order by a.first_seen_at, a.to_id limit 1)) as contact
    from cma.crm_record r
    join cma.connection_pipeline p
      on p.tenant_id = r.tenant_id and p.connection_id = r.connection_id and p.record_type = r.record_type
     and p.source_pipeline_id = r.pipeline_id and p.is_order and p.is_counted
    join cma.connection_stage st
      on st.tenant_id = r.tenant_id and st.connection_id = r.connection_id and st.record_type = r.record_type
     and st.source_pipeline_id = r.pipeline_id and st.source_stage_id = r.stage_id and st.outcome = 'won'
    where r.tenant_id = p_tenant_id and r.record_type = 'deal' and r.source_deleted_at is null
      and r.source_created_at >= p_from and r.source_created_at < p_to
  ),
  -- the market, the linked order and the kind
  k as materialized (
    select d.*, rm.code as market, coalesce(mk.time_zone, s.tenant_zone) as zone,
           o.order_id, o.order_source_id, o.order_kind as store_order_kind, o.currency as order_currency, o.amount as order_amount,
           o.hashes,
           case when d.contact is null then 'no_contact'
                when o.order_kind = 'renewal' then 'renewal'
                when exists (select 1
                             from cma.crm_record r2
                             join cma.connection_pipeline p2
                               on p2.tenant_id = r2.tenant_id and p2.connection_id = r2.connection_id and p2.record_type = r2.record_type
                              and p2.source_pipeline_id = r2.pipeline_id and p2.is_order and p2.is_counted
                             join cma.connection_stage st2
                               on st2.tenant_id = r2.tenant_id and st2.connection_id = r2.connection_id and st2.record_type = r2.record_type
                              and st2.source_pipeline_id = r2.pipeline_id and st2.source_stage_id = r2.stage_id and st2.outcome = 'won'
                             where r2.tenant_id = p_tenant_id and r2.connection_id = d.connection_id and r2.record_type = 'deal'
                               and r2.contact_source_id = d.contact and r2.source_deleted_at is null
                               and (r2.source_created_at < d.t or (r2.source_created_at = d.t and r2.id < d.id)))
                  or exists (select 1
                             from cma.crm_association a2
                             join cma.crm_record r2
                               on r2.tenant_id = a2.tenant_id and r2.connection_id = a2.connection_id and r2.record_type = 'deal'
                              and r2.source_id = a2.from_id and r2.source_deleted_at is null
                             join cma.connection_pipeline p2
                               on p2.tenant_id = r2.tenant_id and p2.connection_id = r2.connection_id and p2.record_type = r2.record_type
                              and p2.source_pipeline_id = r2.pipeline_id and p2.is_order and p2.is_counted
                             join cma.connection_stage st2
                               on st2.tenant_id = r2.tenant_id and st2.connection_id = r2.connection_id and st2.record_type = r2.record_type
                              and st2.source_pipeline_id = r2.pipeline_id and st2.source_stage_id = r2.stage_id and st2.outcome = 'won'
                             where a2.tenant_id = p_tenant_id and a2.connection_id = d.connection_id and a2.from_type = 'deal'
                               and a2.to_type = 'contact' and a2.to_id = d.contact and a2.removed_at is null
                               and (r2.source_created_at < d.t or (r2.source_created_at = d.t and r2.id < d.id)))
                  then 'repeat'
                when o.order_kind = 'repeat' then 'not_first'
                else 'first' end as kind
    from d
    cross join s
    cross join lateral cma.record_market_of(p_tenant_id, d.connection_id, d.own_market, d.contact) rm
    left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = rm.code
    left join lateral (
      select co.id as order_id, co.source_id as order_source_id, co.order_kind, co.currency, co.total_amount as amount,
             array_remove(array[co.phone_hash, cu.phone_hash], null) as hashes
      from cma.commerce_customer cu
      join cma.commerce_order co
        on co.tenant_id = cu.tenant_id and co.connection_id = cu.connection_id and co.customer_source_id = cu.source_id
      where cu.tenant_id = p_tenant_id and cu.crm_connection_id = d.connection_id and cu.crm_contact_source_id = d.contact
        and not co.is_test and co.cancelled_at is null and co.source_deleted_at is null
        and co.source_created_at >= d.t - s.match and co.source_created_at <= d.t + s.match
      order by abs(extract(epoch from co.source_created_at - d.t)), co.source_created_at, co.id
      limit 1) o on true
  ),
  -- the touches of each first order in its window
  x as (
    select k.id, tt.touch, tt.at, tt.sys, tt.owner_ref
    from k
    cross join s
    cross join lateral (
      -- lead deals of the contact: primary contact
      select 'lead_deal'::text as touch, r3.source_created_at as at, r3.source_system || '_owner' as sys, r3.owner_ref
      from cma.crm_record r3
      left join cma.connection_pipeline p3
        on p3.tenant_id = r3.tenant_id and p3.connection_id = r3.connection_id and p3.record_type = r3.record_type
       and p3.source_pipeline_id = r3.pipeline_id
      where r3.tenant_id = p_tenant_id and r3.connection_id = k.connection_id and r3.record_type = 'deal'
        and r3.contact_source_id = k.contact and r3.source_deleted_at is null and r3.id <> k.id
        and coalesce(p3.is_counted, true) and coalesce(p3.is_lead, true) and not coalesce(p3.is_order, false)
        and r3.source_created_at >= k.t - s.win and r3.source_created_at < k.t
      union all
      -- lead deals of the contact: a current association
      select 'lead_deal', r3.source_created_at, r3.source_system || '_owner', r3.owner_ref
      from cma.crm_association a3
      join cma.crm_record r3
        on r3.tenant_id = a3.tenant_id and r3.connection_id = a3.connection_id and r3.record_type = 'deal' and r3.source_id = a3.from_id
      left join cma.connection_pipeline p3
        on p3.tenant_id = r3.tenant_id and p3.connection_id = r3.connection_id and p3.record_type = r3.record_type
       and p3.source_pipeline_id = r3.pipeline_id
      where a3.tenant_id = p_tenant_id and a3.connection_id = k.connection_id and a3.from_type = 'deal' and a3.to_type = 'contact'
        and a3.to_id = k.contact and a3.removed_at is null
        and r3.contact_source_id is distinct from k.contact and r3.source_deleted_at is null and r3.id <> k.id
        and coalesce(p3.is_counted, true) and coalesce(p3.is_lead, true) and not coalesce(p3.is_order, false)
        and r3.source_created_at >= k.t - s.win and r3.source_created_at < k.t
      union all
      -- calls with the contact: a conversation, else an attempt
      select case when cc.is_connected then 'conversation' else 'attempt' end, cc.effective_at, c.source_system || '_owner', c.owner_ref
      from cma.crm_association a4
      join cma.crm_call c
        on c.tenant_id = a4.tenant_id and c.connection_id = a4.connection_id and c.source_id = a4.from_id and c.source_deleted_at is null
      cross join lateral cma.crm_call_connected_of(p_tenant_id, c.id) cc
      where a4.tenant_id = p_tenant_id and a4.connection_id = k.connection_id and a4.from_type = 'crm_call' and a4.to_type = 'contact'
        and a4.to_id = k.contact and a4.removed_at is null
        and cc.effective_at >= k.t - s.win and cc.effective_at < k.t
      union all
      -- agent emails to the contact: the message's own contact, its conversation's, or an engagement's association
      select 'email', em.occurred_at, em.source_system || '_owner', em.owner_ref
      from (select em1.id from cma.email_message em1
            where em1.tenant_id = p_tenant_id and em1.connection_id = k.connection_id and em1.contact_source_id = k.contact
            union
            select em2.id from cma.email_thread th2
            join cma.email_message em2
              on em2.tenant_id = th2.tenant_id and em2.connection_id = th2.connection_id and em2.thread_source_id = th2.source_id
            where th2.tenant_id = p_tenant_id and th2.connection_id = k.connection_id and th2.contact_source_id = k.contact
            union
            select em3.id from cma.crm_association a5
            join cma.email_message em3
              on em3.tenant_id = a5.tenant_id and em3.connection_id = a5.connection_id and em3.source_kind = 'crm_email'
             and em3.source_id = a5.from_id
            where a5.tenant_id = p_tenant_id and a5.connection_id = k.connection_id and a5.from_type = 'crm_email'
              and a5.to_type = 'contact' and a5.to_id = k.contact and a5.removed_at is null) ids
      join cma.email_message em on em.tenant_id = p_tenant_id and em.id = ids.id
      join cma.integration_connection ic on ic.tenant_id = em.tenant_id and ic.id = em.connection_id
      left join cma.email_thread th
        on th.tenant_id = em.tenant_id and th.connection_id = em.connection_id and th.source_id = em.thread_source_id
      where em.direction = 'out' and em.status = 'sent' and em.source_deleted_at is null
        and em.occurred_at >= k.t - s.win and em.occurred_at < k.t
        and case when em.source_kind = 'inbox_message'
                 then em.actor_kind not in ('bot', 'ai', 'system', 'integration') and not coalesce(th.is_spam, false)
                 else not (lower(coalesce(em.origin, '')) = any (cma.setting_codes(ic.settings, 'email_inbox_copy_origins')))
                      and not (lower(coalesce(em.origin, '')) = any (cma.setting_codes(ic.settings, 'email_automated_origins'))) end
      union all
      -- a CRM call from the order's phone number, any contact
      select 'phone_match', cc.effective_at, c.source_system || '_owner', c.owner_ref
      from cma.crm_call c
      cross join lateral cma.crm_call_connected_of(p_tenant_id, c.id) cc
      where cardinality(k.hashes) > 0 and c.tenant_id = p_tenant_id and c.counterpart_hash = any (k.hashes)
        and c.source_deleted_at is null and cc.effective_at >= k.t - s.win and cc.effective_at < k.t
      union all
      -- a telephony call from the order's phone number, any contact
      select 'phone_match', tc.started_at, tc.source_system || '_user', tc.user_ref
      from cma.telephony_call tc
      where cardinality(k.hashes) > 0 and tc.tenant_id = p_tenant_id and tc.counterpart_hash = any (k.hashes)
        and tc.source_deleted_at is null and tc.started_at >= k.t - s.win and tc.started_at < k.t
    ) tt
    where k.kind = 'first'
  ),
  f as (
    select k.id,
           coalesce(bool_or(x.touch = 'lead_deal'), false) as f_lead,
           coalesce(bool_or(x.touch = 'conversation'), false) as f_conv,
           coalesce(bool_or(x.touch = 'email'), false) as f_email,
           coalesce(bool_or(x.touch = 'phone_match'), false) as f_phone,
           coalesce(bool_or(x.touch = 'attempt'), false) as f_attempt,
           coalesce((select kc.source_created_at <= k.t - s.known
                     from cma.crm_contact kc
                     where kc.tenant_id = p_tenant_id and kc.connection_id = k.connection_id and kc.source_id = k.contact), false) as f_known,
           min(x.at) as first_at,
           (array_agg(x.sys order by x.at desc, x.touch, x.owner_ref) filter (where x.touch = any (s.assisted)))[1] as c_sys,
           (array_agg(x.owner_ref order by x.at desc, x.touch, x.owner_ref) filter (where x.touch = any (s.assisted)))[1] as c_owner
    from k
    cross join s
    left join x on x.id = k.id
    where k.kind = 'first'
    group by k.id, k.t, k.connection_id, k.contact, s.known
  ),
  l as (
    select f.*,
           coalesce((select u.lv
                     from unnest(s.level_order) with ordinality as u(lv, i)
                     where case u.lv when 'lead_deal' then f.f_lead when 'conversation' then f.f_conv when 'email' then f.f_email
                                     when 'phone_match' then f.f_phone when 'attempt' then f.f_attempt when 'known_contact' then f.f_known
                                     else false end
                     order by u.i limit 1), 'self_service') as lv,
           s.assisted
    from f cross join s
  )
  select k.id, k.connection_id, k.source_system, k.source_id, k.pipeline_id, k.pipeline_label, k.contact, k.t, k.market, k.zone,
         (k.t at time zone k.zone)::date,
         date_trunc('week', (k.t at time zone k.zone)::date::timestamp)::date,
         (k.t at time zone k.zone)::time,
         k.kind, k.order_id, k.order_source_id, k.store_order_kind,
         case when k.order_id is not null then k.order_currency else k.deal_currency end,
         case when k.order_id is not null then k.order_amount else k.deal_amount end,
         cardinality(k.hashes) > 0,
         l.f_lead, l.f_conv, l.f_email, l.f_phone, l.f_attempt, l.f_known,
         l.lv,
         case when l.id is null then null when l.lv = any (l.assisted) then 'call_center' else 'self_service' end,
         l.first_at,
         case when l.first_at is not null then round((extract(epoch from k.t - l.first_at) / 86400)::numeric, 2) end,
         l.c_sys, l.c_owner,
         (select xi.user_id from cma.app_user_external_id xi
          where xi.tenant_id = p_tenant_id and xi.system = l.c_sys and xi.external_id = l.c_owner)
  from k
  left join l on l.id = k.id
$$;

-- The old first orders pass, once per tenant and window: the old reads below call it by this name, so the
-- slow pass of 0008u runs once for October's window however many old reads need it
create temp table v0008x_old_cache as
  select null::uuid as tenant_key, null::timestamptz as from_key, null::timestamptz as to_key, x.*
  from pg_temp.v0008x_old_first_orders_compute(null, null, null) x where false;
create temp table v0008x_old_keys (tenant_key uuid, from_key timestamptz, to_key timestamptz);

create or replace function pg_temp.v0008x_old_first_orders_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  deal_id                uuid,
  connection_id          uuid,
  source_system          text,
  deal_source_id         text,
  pipeline_id            text,
  pipeline_label         text,
  contact_source_id      text,
  created_at             timestamptz,
  market                 text,
  zone                   text,
  business_date          date,
  week_start             date,
  local_time             time,
  kind                   text,
  order_id               uuid,
  order_source_id        text,
  store_order_kind       text,
  currency               text,
  amount                 numeric,
  phone_hashed           boolean,
  lead_deal              boolean,
  conversation           boolean,
  email                  boolean,
  phone_match            boolean,
  attempt                boolean,
  known_contact          boolean,
  level                  text,
  attribution            text,
  first_touch_at         timestamptz,
  days_from_first_touch  numeric,
  credited_system        text,
  credited_owner_ref     text,
  credited_user_id       uuid
)
language plpgsql
as $f$
begin
  if not exists (select 1 from v0008x_old_keys k where k.tenant_key = p_tenant_id and k.from_key = p_from and k.to_key = p_to) then
    insert into v0008x_old_cache select p_tenant_id, p_from, p_to, x.* from pg_temp.v0008x_old_first_orders_compute(p_tenant_id, p_from, p_to) x;
    insert into v0008x_old_keys values (p_tenant_id, p_from, p_to);
  end if;
  return query
    select c.deal_id, c.connection_id, c.source_system, c.deal_source_id, c.pipeline_id, c.pipeline_label, c.contact_source_id, c.created_at, c.market, c.zone, c.business_date, c.week_start, c.local_time, c.kind, c.order_id, c.order_source_id, c.store_order_kind, c.currency, c.amount, c.phone_hashed, c.lead_deal, c.conversation, c.email, c.phone_match, c.attempt, c.known_contact, c.level, c.attribution, c.first_touch_at, c.days_from_first_touch, c.credited_system, c.credited_owner_ref, c.credited_user_id
    from v0008x_old_cache c
    where c.tenant_key = p_tenant_id and c.from_key = p_from and c.to_key = p_to;
end
$f$;

create or replace function pg_temp.v0008x_old_first_orders_figures_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_level text,
                                                       p_dimensions text[], p_until timestamptz default null)
returns table (
  dimension          text,
  group_key          text,
  first_orders       integer,
  call_center        integer,
  self_service       integer,
  repeats            integer,
  renewals           integer,
  not_first          integer,
  no_contact         integer,
  with_touch         integer,
  days_median        numeric
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  b as (select (p_from - 1)::timestamp at time zone s.zone as from_at, (p_to + 2)::timestamp at time zone s.zone as to_at from s),
  o as materialized (
    select x.* from b cross join lateral pg_temp.v0008x_old_first_orders_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to
      and (p_until is null or x.business_date < p_to or x.local_time <= (p_until at time zone x.zone)::time)
      and (p_market is null or x.market = p_market)
      and (p_level is null or x.level = p_level)
  ),
  g as (
    select dd.dim, dd.k, o.*
    from o
    cross join lateral (
      values ('total', null::text),
             ('day', o.business_date::text),
             ('week', o.week_start::text),
             ('market', o.market),
             ('level', o.level)) as dd(dim, k)
    where dd.dim = 'total' or (dd.dim = any (p_dimensions) and (dd.dim <> 'level' or o.kind = 'first'))
  ),
  agg as (
    select g.dim, g.k,
           (count(*) filter (where g.kind = 'first'))::integer as first_orders,
           (count(*) filter (where g.attribution = 'call_center'))::integer as call_center,
           (count(*) filter (where g.attribution = 'self_service'))::integer as self_service,
           (count(*) filter (where g.kind = 'repeat'))::integer as repeats,
           (count(*) filter (where g.kind = 'renewal'))::integer as renewals,
           (count(*) filter (where g.kind = 'not_first'))::integer as not_first,
           (count(*) filter (where g.kind = 'no_contact'))::integer as no_contact,
           (count(*) filter (where g.kind = 'first' and g.first_touch_at is not null))::integer as with_touch,
           percentile_cont(0.5) within group (order by g.days_from_first_touch)
             filter (where g.kind = 'first' and g.days_from_first_touch is not null) as dm
    from g
    group by g.dim, g.k
  )
  select a.dim, a.k, a.first_orders, a.call_center, a.self_service, a.repeats, a.renewals, a.not_first, a.no_contact, a.with_touch,
         round(a.dm::numeric, 1)
  from agg a
  union all
  -- the total is there even for a period without anything
  select 'total', null, 0, 0, 0, 0, 0, 0, 0, 0, null
  where not exists (select 1 from agg where agg.dim = 'total')
  order by 1, 2
$$;

create or replace function pg_temp.v0008x_old_first_orders_report_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_market text, p_level text,
                                                      p_now timestamptz default now())
returns table (
  period             text,
  dimension          text,
  group_key          text,
  first_orders       integer,
  call_center        integer,
  self_service       integer,
  repeats            integer,
  renewals           integer,
  not_first          integer,
  no_contact         integer,
  with_touch         integer,
  days_median        numeric
)
language sql stable
as $$
  select x.period, x.dimension, x.group_key, x.first_orders, x.call_center, x.self_service, x.repeats, x.renewals, x.not_first,
         x.no_contact, x.with_touch, x.days_median
  from (
    select 'current'::text as period, 1 as part, f.*
    from pg_temp.v0008x_old_first_orders_figures_of(p_tenant_id, p_from, p_to, p_market, p_level, array[p_group, 'market', 'level']) f
    union all
    select 'previous', 2, f.*
    from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now) v
    cross join lateral pg_temp.v0008x_old_first_orders_figures_of(p_tenant_id, v.prev_from, v.prev_to, p_market, p_level, '{}'::text[], v.until) f
  ) x
  order by x.part, x.dimension, x.group_key
$$;

create or replace function pg_temp.v0008x_old_first_orders_amounts_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_level text)
returns table (
  dimension              text,
  group_key              text,
  currency               text,
  orders                 integer,
  amount                 numeric,
  call_center_amount     numeric,
  self_service_amount    numeric
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  b as (select (p_from - 1)::timestamp at time zone s.zone as from_at, (p_to + 2)::timestamp at time zone s.zone as to_at from s),
  o as (
    select x.* from b cross join lateral pg_temp.v0008x_old_first_orders_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to and x.kind = 'first'
      and (p_market is null or x.market = p_market)
      and (p_level is null or x.level = p_level)
  )
  select dd.dim, dd.k, coalesce(o.currency, 'none'), count(*)::integer, sum(o.amount),
         coalesce(sum(o.amount) filter (where o.attribution = 'call_center'), 0),
         coalesce(sum(o.amount) filter (where o.attribution = 'self_service'), 0)
  from o
  cross join lateral (values ('total', null::text), ('market', o.market)) as dd(dim, k)
  group by dd.dim, dd.k, coalesce(o.currency, 'none')
  order by 1, 2, 3
$$;

create or replace function pg_temp.v0008x_old_first_orders_per_person_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_level text)
returns table (
  row_kind           text,
  user_id            uuid,
  display_name       text,
  unlinked_owners    integer,
  orders             integer,
  lead_deal          integer,
  conversation       integer,
  email              integer,
  phone_match        integer,
  other_levels       integer,
  days_median        numeric
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  b as (select (p_from - 1)::timestamp at time zone s.zone as from_at, (p_to + 2)::timestamp at time zone s.zone as to_at from s),
  o as (
    select x.*, case when u.id is null then 'not_linked' else 'person' end as rk, u.id as uid, u.display_name as uname
    from b cross join lateral pg_temp.v0008x_old_first_orders_of(p_tenant_id, b.from_at, b.to_at) x
    left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = x.credited_user_id
    where x.business_date between p_from and p_to and x.kind = 'first' and x.attribution = 'call_center'
      and (p_market is null or x.market = p_market)
      and (p_level is null or x.level = p_level)
  )
  select coalesce(o.rk, 'total'), o.uid, o.uname,
         case when o.rk = 'not_linked' then (count(distinct o.credited_owner_ref))::integer end,
         count(*)::integer,
         (count(*) filter (where o.level = 'lead_deal'))::integer,
         (count(*) filter (where o.level = 'conversation'))::integer,
         (count(*) filter (where o.level = 'email'))::integer,
         (count(*) filter (where o.level = 'phone_match'))::integer,
         (count(*) filter (where o.level not in ('lead_deal', 'conversation', 'email', 'phone_match')))::integer,
         round((percentile_cont(0.5) within group (order by o.days_from_first_touch) filter (where o.days_from_first_touch is not null))::numeric, 1)
  from o
  group by grouping sets ((o.rk, o.uid, o.uname), ())
  order by grouping(o.rk), o.rk = 'not_linked', o.uname, o.uid
$$;

create or replace function pg_temp.v0008x_old_email_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
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

create or replace function pg_temp.v0008x_old_email_threads_counted_of(p_tenant_id uuid, p_thread_ids uuid[])
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

create or replace function pg_temp.v0008x_old_email_openings_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
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
    select x.* from pg_temp.v0008x_old_email_threads_counted_of(p_tenant_id, (select coalesce(array_agg(distinct o.thread_id), '{}') from o)) x
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

create or replace function pg_temp.v0008x_old_email_closes_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
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
    select x.* from pg_temp.v0008x_old_email_threads_counted_of(p_tenant_id, (select coalesce(array_agg(distinct c.thread_id), '{}') from c)) x
  )
  select t.connection_id, t.source_system, t.source_id, t.inbox_key, t.inbox_name, t.account_key, t.account_name, t.category,
         c.occurred_at, c.actor_kind, c.owner_ref, t.market, t.zone,
         (c.occurred_at at time zone t.zone)::date,
         date_trunc('week', (c.occurred_at at time zone t.zone)::date::timestamp)::date,
         extract(hour from (c.occurred_at at time zone t.zone))::integer
  from c
  join t on t.id = c.thread_id
$$;

create or replace function pg_temp.v0008x_old_email_figures_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_inbox text, p_account text,
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
    select x.* from b cross join lateral pg_temp.v0008x_old_email_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to
      and (p_until is null or x.business_date < p_to or x.local_time <= (p_until at time zone x.zone)::time)
      and (p_market is null or x.market = p_market)
      and (p_inbox is null or x.inbox_key = p_inbox)
      and (p_account is null or x.account_key = p_account)
  ),
  o as materialized (
    select x.* from b cross join lateral pg_temp.v0008x_old_email_openings_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to
      and (p_until is null or x.business_date < p_to or (x.opened_at at time zone x.zone)::time <= (p_until at time zone x.zone)::time)
      and (p_market is null or x.market = p_market)
      and (p_inbox is null or x.inbox_key = p_inbox)
      and (p_account is null or x.account_key = p_account)
  ),
  c as materialized (
    select x.* from b cross join lateral pg_temp.v0008x_old_email_closes_of(p_tenant_id, b.from_at, b.to_at) x
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

create or replace function pg_temp.v0008x_old_email_overview_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_market text, p_inbox text,
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
    from pg_temp.v0008x_old_email_figures_of(p_tenant_id, p_from, p_to, p_market, p_inbox, p_account, array[p_group]) f
    union all
    select 'previous', 2, true, f.*
    from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now) v
    cross join lateral pg_temp.v0008x_old_email_figures_of(p_tenant_id, v.prev_from, v.prev_to, p_market, p_inbox, p_account, '{}'::text[], v.until) f
  ) x
  order by x.part, x.is_total, case when p_group in ('day', 'week') then x.group_key end, x.group_label, x.group_key
$$;

create or replace function pg_temp.v0008x_old_email_by_dimension_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_inbox text,
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
  select f.* from pg_temp.v0008x_old_email_figures_of(p_tenant_id, p_from, p_to, p_market, p_inbox, p_account,
                                       array['inbox', 'account', 'category', 'market']) f
  where f.dimension <> 'total'
  order by array_position(array['inbox', 'account', 'category', 'market'], f.dimension), f.group_key = 'none', f.group_label, f.group_key
$$;

create or replace function pg_temp.v0008x_old_email_report_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_market text, p_inbox text,
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
    from pg_temp.v0008x_old_email_figures_of(p_tenant_id, p_from, p_to, p_market, p_inbox, p_account,
                              array[p_group, 'market', 'inbox', 'account', 'category', p_group || '_inbox', p_group || '_account']) f
    union all
    select 'previous', 2, f.*
    from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now) v
    cross join lateral pg_temp.v0008x_old_email_figures_of(p_tenant_id, v.prev_from, v.prev_to, p_market, p_inbox, p_account, '{}'::text[], v.until) f
  ) x
  order by x.part, x.dimension, x.group_key
$$;

create or replace function pg_temp.v0008x_old_email_received_series_of(p_tenant_id uuid, p_from date, p_to date, p_group text, p_split text,
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
  cross join lateral pg_temp.v0008x_old_email_of(p_tenant_id, (p_from - 1)::timestamp at time zone s.zone, (p_to + 2)::timestamp at time zone s.zone) x
  where x.business_date between p_from and p_to and x.is_received
    and (p_market is null or x.market = p_market)
    and (p_inbox is null or x.inbox_key = p_inbox)
    and (p_account is null or x.account_key = p_account)
  group by 1, 2
  order by 1, 3, 2
$$;

create or replace function pg_temp.v0008x_old_email_per_person_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_inbox text, p_account text)
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
    from b cross join lateral pg_temp.v0008x_old_email_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to and x.is_agent_send
      and (p_market is null or x.market = p_market) and (p_inbox is null or x.inbox_key = p_inbox)
      and (p_account is null or x.account_key = p_account)
    union all
    select 'reply', x.source_system, x.reply_owner_ref, null, x.reply_seconds, x.reply_business_seconds, x.reply_within_target
    from b cross join lateral pg_temp.v0008x_old_email_openings_of(p_tenant_id, b.from_at, b.to_at) x
    where x.business_date between p_from and p_to and x.first_reply_at is not null
      and (p_market is null or x.market = p_market) and (p_inbox is null or x.inbox_key = p_inbox)
      and (p_account is null or x.account_key = p_account)
    union all
    select 'close', x.source_system, x.owner_ref, null, null, null, null
    from b cross join lateral pg_temp.v0008x_old_email_closes_of(p_tenant_id, b.from_at, b.to_at) x
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

create or replace function pg_temp.v0008x_old_first_orders_list_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_level text,
                                                             p_rows integer)
returns table (
  connection_id          uuid,
  deal_source_id         text,
  market                 text,
  created_at             timestamptz,
  business_date          date,
  level                  text,
  attribution            text,
  lead_deal              boolean,
  conversation           boolean,
  email                  boolean,
  phone_match            boolean,
  attempt                boolean,
  known_contact          boolean,
  phone_hashed           boolean,
  has_order              boolean,
  currency               text,
  amount                 numeric,
  days_from_first_touch  numeric,
  record_url             text,
  total_rows             integer
)
language sql stable
as $$
    with o as (
      select x.* from pg_temp.v0008x_old_first_orders_of(p_tenant_id, (p_from - 1)::timestamp at time zone (select t.timezone from cma.tenant t where t.id = p_tenant_id), (p_to + 2)::timestamp at time zone (select t.timezone from cma.tenant t where t.id = p_tenant_id)) x
      where x.business_date between p_from and p_to and x.kind = 'first'
        and (p_market is null or x.market = p_market)
        and (p_level is null or x.level = p_level)
    )
    select o.connection_id, o.deal_source_id, o.market, o.created_at, o.business_date, o.level, o.attribution, o.lead_deal, o.conversation,
           o.email, o.phone_match, o.attempt, o.known_contact, o.phone_hashed, o.order_id is not null, o.currency, o.amount,
           o.days_from_first_touch, cma.record_url(o.connection_id, 'deal', o.deal_source_id), (count(*) over ())::integer
    from o
    order by o.created_at desc, o.deal_source_id
    limit p_rows
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008w
  insert into verify_0008x values (1, 'A1 addition 0008x recorded, after 0008w',
    case when exists (select 1 from cma.schema_migration where version = '0008x')
              and exists (select 1 from cma.schema_migration where version = '0008w') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the row types: cma.first_order has exactly cma.first_orders_of's columns, cma.email_fact the facts' columns
  v_bad := '';
  if (select string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum)
      from pg_attribute a where a.attrelid = 'cma.first_order'::regclass and a.attnum > 0 and not a.attisdropped)
     is distinct from
     (select string_agg(n || ' ' || format_type(t, null), ',' order by i)
      from pg_proc p
      cross join lateral unnest(p.proargnames, p.proallargtypes::oid[], p.proargmodes::text[]) with ordinality as x(n, t, m, i)
      where p.oid = 'cma.first_orders_of(uuid,timestamptz,timestamptz)'::regprocedure and x.m = 't') then
    v_bad := v_bad || 'cma.first_order differs from cma.first_orders_of; ';
  end if;
  if (select count(*) from pg_attribute a where a.attrelid = 'cma.email_fact'::regclass and a.attnum > 0 and not a.attisdropped) <> 28 then
    v_bad := v_bad || 'cma.email_fact has not 28 columns; ';
  end if;
  insert into verify_0008x values (2, 'A2 cma.first_order is cma.first_orders_of''s row; cma.email_fact holds the 28 fact columns',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(nullif(v_bad, ''), 'ok'));

  -- A3. every function of 0008x the application's only and in the caller's rights
  v_bad := '';
  foreach v_fn in array array[
    'cma.first_orders_of(uuid,timestamptz,timestamptz)', 'cma.first_orders_rows_of(uuid,date,date)',
    'cma.first_orders_figures_from(cma.first_order[],date,date,text,text,text[],timestamptz)',
    'cma.first_orders_figures_of(uuid,date,date,text,text,text[],timestamptz)',
    'cma.first_orders_report_from(uuid,cma.first_order[],date,date,text,text,text,timestamptz)',
    'cma.first_orders_report_of(uuid,date,date,text,text,text,timestamptz)',
    'cma.first_orders_amounts_from(cma.first_order[],date,date,text,text)', 'cma.first_orders_amounts_of(uuid,date,date,text,text)',
    'cma.first_orders_list_from(cma.first_order[],date,date,text,text,integer)', 'cma.first_orders_list(date,date,text,text,integer)',
    'cma.first_orders_page(date,date,text,text,text,integer)',
    'cma.email_of(uuid,timestamptz,timestamptz)', 'cma.email_threads_counted_of(uuid,uuid[])',
    'cma.email_openings_of(uuid,timestamptz,timestamptz)', 'cma.email_facts_of(uuid,date,date)',
    'cma.email_figures_from(cma.email_fact[],date,date,text,text,text,text[],timestamptz)',
    'cma.email_figures_of(uuid,date,date,text,text,text,text[],timestamptz)',
    'cma.email_overview_of(uuid,date,date,text,text,text,text,timestamptz)',
    'cma.email_by_dimension_from(cma.email_fact[],date,date,text,text,text)', 'cma.email_by_dimension_of(uuid,date,date,text,text,text)',
    'cma.email_report_from(uuid,cma.email_fact[],date,date,text,text,text,text,timestamptz)',
    'cma.email_report_of(uuid,date,date,text,text,text,text,timestamptz)',
    'cma.email_per_person_from(uuid,cma.email_fact[],date,date,text,text,text)', 'cma.email_per_person_of(uuid,date,date,text,text,text)',
    'cma.email_report_page(date,date,text,text,text,text)', 'cma.email_per_person_page(date,date,text,text,text)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(v_fn))
          or has_function_privilege('public', v_fn, 'execute')
          or not has_function_privilege('cma_app', v_fn, 'execute')
          or has_function_privilege('cma_readonly', v_fn, 'execute') then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  insert into verify_0008x values (3, 'A3 every function of 0008x: the application''s only, in the caller''s rights',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(nullif(v_bad, ''), '26 functions'));

  -- A4. the three catalogs autovacuum had never analyzed carry statistics
  select string_agg(s.relname, ', ' order by s.relname) into v_bad
  from pg_stat_user_tables s
  where s.schemaname = 'cma' and s.relname in ('market', 'market_alias', 'app_user_external_id')
    and greatest(s.last_analyze, s.last_autoanalyze) is null;
  insert into verify_0008x values (4, 'A4 cma.market, market_alias and app_user_external_id analyzed',
    case when v_bad is null and not v_provoke then 'PASS' else 'FAIL' end, coalesce('never analyzed: ' || v_bad, 'ok'));
end
$$;

-- B. Behaviour and speed at prod's volume, on a throwaway tenant (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_max     integer := current_setting('verify.max_ms')::integer;
  v_rows    text[] := '{}';
  t         uuid;
  v_user    uuid;
  v_txt     text;
  v_ok      boolean;
  v_detail  text;
  v_ms      numeric;
  v_slow    text;
  v_times   text;
  v_q       text;
  v_name    text;
  v_old_ms  numeric;
  v_new_ms  numeric;
  v_ratio   text;
  -- October 2026, the month prod was measured on; the reads' window of it in Amsterdam
  v_from    date := '2026-10-01';
  v_to      date := '2026-10-31';
  w_from    timestamptz := '2026-09-30 00:00+02';
  w_to      timestamptz := '2026-11-02 00:00+01';
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- B1. the tenant at prod's counts of 19 October 2026 (prod-output.txt, sections 2 and 3)
    t := cma.create_tenant('verify-0008x', 'Verify 0008x', 'Europe/Amsterdam');
    perform pg_temp.v0008x_generate(t, 1);
    insert into cma.app_user (tenant_id, email, display_name) values (t, 'verify-0008x-analyst@example.invalid', 'analyst') returning id into v_user;
    insert into cma.user_role (tenant_id, user_id, role_id) select t, v_user, r.id from cma.app_role r where r.tenant_id = t and r.key = 'analytics';
    insert into cma.tenant_setting (tenant_id, key, value) values (t, 'reports.per_person', 'email,orders');
    analyze cma.crm_record, cma.crm_contact, cma.crm_association, cma.crm_call, cma.telephony_call, cma.call_link, cma.email_message,
            cma.email_thread, cma.email_thread_event, cma.commerce_order, cma.commerce_customer, cma.form_submission, cma.market,
            cma.market_alias, cma.app_user_external_id;
    select format('contacts %s, order deals won in the window %s, calls %s/%s, emails %s, threads %s, events %s, orders %s, customers %s, associations %s',
                  (select count(*) from cma.crm_contact where tenant_id = t),
                  (select count(*) from cma.crm_record where tenant_id = t and pipeline_id like 'orders%' and stage_id = 'won'
                                                         and source_created_at >= w_from and source_created_at < w_to),
                  (select count(*) from cma.crm_call where tenant_id = t), (select count(*) from cma.telephony_call where tenant_id = t),
                  (select count(*) from cma.email_message where tenant_id = t), (select count(*) from cma.email_thread where tenant_id = t),
                  (select count(*) from cma.email_thread_event where tenant_id = t), (select count(*) from cma.commerce_order where tenant_id = t),
                  (select count(*) from cma.commerce_customer where tenant_id = t), (select count(*) from cma.crm_association where tenant_id = t))
      into v_txt;
    v_rows := v_rows || array['10', 'B1 a throwaway tenant at prod''s counts of 19 October 2026',
      case when v_txt like 'contacts 5257, order deals won in the window 1486, calls 4156/4096, emails 5263, threads 1362, %, orders 2806, customers 11313, %'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. first orders: the new definition gives the rows of 0008u's, over October's read window and over the previous span's
    select x.same, x.detail into v_ok, v_detail from pg_temp.v0008x_same(
      format('select * from cma.first_orders_of(%L, %L, %L)', t, w_from, w_to),
      format('select * from pg_temp.v0008x_old_first_orders_of(%L, %L, %L)', t, w_from, w_to)) x;
    v_txt := 'October ' || v_detail;
    select x.same and v_ok, v_txt || '; previous span ' || x.detail into v_ok, v_txt from pg_temp.v0008x_same(
      format('select * from cma.first_orders_of(%L, %L, %L)', t, timestamptz '2026-08-30 00:00+02', timestamptz '2026-09-21 00:00+02'),
      format('select * from pg_temp.v0008x_old_first_orders_of(%L, %L, %L)', t, timestamptz '2026-08-30 00:00+02', timestamptz '2026-09-21 00:00+02')) x;
    v_rows := v_rows || array['11', 'B2 cma.first_orders_of gives 0008u''s rows (October''s window, the previous span''s)',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. the reads: the report (per day; per week for one market), the amounts, the list and per person equal 0008u's
    v_txt := '';
    v_ok := true;
    foreach v_q in array array[
      format('select * from cma.first_orders_report_of(%L, %L, %L, %L, null, null, now())', t, v_from, v_to, 'day') || '|' ||
      format('select * from pg_temp.v0008x_old_first_orders_report_of(%L, %L, %L, %L, null, null, now())', t, v_from, v_to, 'day'),
      format('select * from cma.first_orders_report_of(%L, %L, %L, %L, %L, null, now())', t, v_from, v_to, 'week', 'NL') || '|' ||
      format('select * from pg_temp.v0008x_old_first_orders_report_of(%L, %L, %L, %L, %L, null, now())', t, v_from, v_to, 'week', 'NL'),
      format('select * from cma.first_orders_amounts_of(%L, %L, %L, null, null)', t, v_from, v_to) || '|' ||
      format('select * from pg_temp.v0008x_old_first_orders_amounts_of(%L, %L, %L, null, null)', t, v_from, v_to),
      format('select * from cma.first_orders_per_person_of(%L, %L, %L, null, null)', t, v_from, v_to) || '|' ||
      format('select * from pg_temp.v0008x_old_first_orders_per_person_of(%L, %L, %L, null, null)', t, v_from, v_to)] loop
      select x.same and v_ok, v_txt || x.detail || '; ' into v_ok, v_txt
      from pg_temp.v0008x_same(split_part(v_q, '|', 1), split_part(v_q, '|', 2)) x;
    end loop;
    v_rows := v_rows || array['12', 'B3 first orders: report per day and per week for NL, amounts, per person equal 0008u''s',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. the page as the application reads it (an analyst: reports.view): its report, amounts and list are 0008u's three reads
    perform set_config('app.tenant_id', t::text, true);
    perform set_config('app.user_id', v_user::text, true);
    create temp table v0008x_page as select * from cma.first_orders_page(v_from, v_to, 'day', null, null) where false;
    grant insert on v0008x_page to cma_app;
    perform set_config('role', 'cma_app', true);
    insert into v0008x_page select * from cma.first_orders_page(v_from, v_to, 'day', null, null);
    perform set_config('role', 'cma_owner', true);
    v_txt := '';
    select x.same, 'report ' || x.detail into v_ok, v_txt from pg_temp.v0008x_same(
      'select period, dimension, group_key, first_orders, call_center, self_service, repeats, renewals, not_first, no_contact, with_touch, days_median from v0008x_page where part = ''report''',
      format('select * from pg_temp.v0008x_old_first_orders_report_of(%L, %L, %L, %L, null, null, now())', t, v_from, v_to, 'day')) x;
    select x.same and v_ok, v_txt || '; amounts ' || x.detail into v_ok, v_txt from pg_temp.v0008x_same(
      'select dimension, group_key, currency, orders, amount, call_center_amount, self_service_amount from v0008x_page where part = ''amounts''',
      format('select * from pg_temp.v0008x_old_first_orders_amounts_of(%L, %L, %L, null, null)', t, v_from, v_to)) x;
    select x.same and v_ok, v_txt || '; list ' || x.detail into v_ok, v_txt from pg_temp.v0008x_same(
      'select connection_id, deal_source_id, market, created_at, business_date, level, attribution, lead_deal, conversation, email, phone_match, attempt, known_contact, phone_hashed, has_order, currency, amount, days_from_first_touch, record_url, total_rows from v0008x_page where part = ''list''',
      format('select * from pg_temp.v0008x_old_first_orders_list_of(%L, %L, %L, null, null, 100)', t, v_from, v_to)) x;
    drop table v0008x_page;
    v_rows := v_rows || array['13', 'B4 cma.first_orders_page as the application: report, amounts and list equal 0008u''s reads',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. email: the definitions give 0008t's rows over October's read window (emails, counted conversations, openings, closes)
    v_txt := '';
    v_ok := true;
    foreach v_q in array array[
      format('select * from cma.email_of(%L, %L, %L)', t, w_from, w_to) || '|' ||
      format('select * from pg_temp.v0008x_old_email_of(%L, %L, %L)', t, w_from, w_to),
      format('select * from cma.email_threads_counted_of(%L, array(select id from cma.email_thread where tenant_id = %L))', t, t) || '|' ||
      format('select * from pg_temp.v0008x_old_email_threads_counted_of(%L, array(select id from cma.email_thread where tenant_id = %L))', t, t),
      format('select * from cma.email_openings_of(%L, %L, %L)', t, w_from, w_to) || '|' ||
      format('select * from pg_temp.v0008x_old_email_openings_of(%L, %L, %L)', t, w_from, w_to),
      format('select * from cma.email_closes_of(%L, %L, %L)', t, w_from, w_to) || '|' ||
      format('select * from pg_temp.v0008x_old_email_closes_of(%L, %L, %L)', t, w_from, w_to)] loop
      select x.same and v_ok, v_txt || x.detail || '; ' into v_ok, v_txt
      from pg_temp.v0008x_same(split_part(v_q, '|', 1), split_part(v_q, '|', 2)) x;
    end loop;
    v_rows := v_rows || array['14', 'B5 email: emails, counted conversations, openings and closes equal 0008t''s',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. the email reads equal 0008t's: the report (per day; per week for NL), the overview, per dimension, the received series,
    --     per person (all; NL)
    v_txt := '';
    v_ok := true;
    foreach v_q in array array[
      format('select * from cma.email_report_of(%L, %L, %L, %L, null, null, null, now())', t, v_from, v_to, 'day') || '|' ||
      format('select * from pg_temp.v0008x_old_email_report_of(%L, %L, %L, %L, null, null, null, now())', t, v_from, v_to, 'day'),
      format('select * from cma.email_report_of(%L, %L, %L, %L, %L, null, null, now())', t, v_from, v_to, 'week', 'NL') || '|' ||
      format('select * from pg_temp.v0008x_old_email_report_of(%L, %L, %L, %L, %L, null, null, now())', t, v_from, v_to, 'week', 'NL'),
      format('select * from cma.email_overview_of(%L, %L, %L, %L, null, null, null, now())', t, v_from, v_to, 'inbox') || '|' ||
      format('select * from pg_temp.v0008x_old_email_overview_of(%L, %L, %L, %L, null, null, null, now())', t, v_from, v_to, 'inbox'),
      format('select * from cma.email_by_dimension_of(%L, %L, %L, null, null, null)', t, v_from, v_to) || '|' ||
      format('select * from pg_temp.v0008x_old_email_by_dimension_of(%L, %L, %L, null, null, null)', t, v_from, v_to),
      format('select * from cma.email_received_series_of(%L, %L, %L, %L, %L, null, null, null)', t, v_from, v_to, 'day', 'inbox') || '|' ||
      format('select * from pg_temp.v0008x_old_email_received_series_of(%L, %L, %L, %L, %L, null, null, null)', t, v_from, v_to, 'day', 'inbox'),
      format('select * from cma.email_per_person_of(%L, %L, %L, null, null, null)', t, v_from, v_to) || '|' ||
      format('select * from pg_temp.v0008x_old_email_per_person_of(%L, %L, %L, null, null, null)', t, v_from, v_to),
      format('select * from cma.email_per_person_of(%L, %L, %L, %L, null, null)', t, v_from, v_to, 'NL') || '|' ||
      format('select * from pg_temp.v0008x_old_email_per_person_of(%L, %L, %L, %L, null, null)', t, v_from, v_to, 'NL')] loop
      select x.same and v_ok, v_txt || x.detail || '; ' into v_ok, v_txt
      from pg_temp.v0008x_same(split_part(v_q, '|', 1), split_part(v_q, '|', 2)) x;
    end loop;
    v_rows := v_rows || array['15', 'B6 email: report, overview, per dimension, received series, per person equal 0008t''s',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. the two email pages as the application reads them: the report filtered to NL with the unfiltered figures for the
    --     filter lists, unfiltered without them; Email per agent with the unfiltered figures
    create temp table v0008x_page as select * from cma.email_report_page(v_from, v_to, 'day', 'NL', null, null) where false;
    create temp table v0008x_page2 as select * from cma.email_report_page(v_from, v_to, 'day', null, null, null) where false;
    create temp table v0008x_page3 as select * from cma.email_per_person_page(v_from, v_to, null, null, null) where false;
    grant insert on v0008x_page, v0008x_page2, v0008x_page3 to cma_app;
    perform set_config('role', 'cma_app', true);
    insert into v0008x_page select * from cma.email_report_page(v_from, v_to, 'day', 'NL', null, null);
    insert into v0008x_page2 select * from cma.email_report_page(v_from, v_to, 'day', null, null, null);
    insert into v0008x_page3 select * from cma.email_per_person_page(v_from, v_to, null, null, null);
    perform set_config('role', 'cma_owner', true);
    select x.same, 'report NL ' || x.detail into v_ok, v_txt from pg_temp.v0008x_same(
      'select * from v0008x_page where period <> ''unfiltered''',
      format('select * from pg_temp.v0008x_old_email_report_of(%L, %L, %L, %L, %L, null, null, now())', t, v_from, v_to, 'day', 'NL')) x;
    select x.same and v_ok, v_txt || '; unfiltered ' || x.detail into v_ok, v_txt from pg_temp.v0008x_same(
      'select dimension, group_key, group_label, received, logged_replies, sent_agent, sent_automated, bounced_failed, threads_opened, threads_closed, replied, reply_median_seconds, reply_median_business_seconds, within_target, target_known, no_hours, close_median_seconds, close_median_business_seconds from v0008x_page where period = ''unfiltered''',
      format('select * from pg_temp.v0008x_old_email_by_dimension_of(%L, %L, %L, null, null, null)', t, v_from, v_to)) x;
    select x.same and v_ok, v_txt || '; report ' || x.detail into v_ok, v_txt from pg_temp.v0008x_same(
      'select * from v0008x_page2',
      format('select * from pg_temp.v0008x_old_email_report_of(%L, %L, %L, %L, null, null, null, now())', t, v_from, v_to, 'day')) x;
    select x.same and v_ok, v_txt || '; per person ' || x.detail into v_ok, v_txt from pg_temp.v0008x_same(
      'select row_kind, user_id, display_name, unlinked_owners, sent, replies, threads_closed, reply_median_seconds, reply_median_business_seconds, within_target, target_known, sent_by_hour from v0008x_page3 where part = ''person''',
      format('select * from pg_temp.v0008x_old_email_per_person_of(%L, %L, %L, null, null, null)', t, v_from, v_to)) x;
    select x.same and v_ok, v_txt || '; per dimension ' || x.detail into v_ok, v_txt from pg_temp.v0008x_same(
      'select dimension, group_key, group_label, received, logged_replies, sent_agent, sent_automated, bounced_failed, threads_opened, threads_closed, replied, reply_median_seconds, reply_median_business_seconds, within_target, target_known, no_hours, close_median_seconds, close_median_business_seconds from v0008x_page3 where part = ''dimension''',
      format('select * from pg_temp.v0008x_old_email_by_dimension_of(%L, %L, %L, null, null, null)', t, v_from, v_to)) x;
    drop table v0008x_page;
    drop table v0008x_page2;
    drop table v0008x_page3;
    v_rows := v_rows || array['16', 'B7 cma.email_report_page and email_per_person_page as the application equal 0008t''s reads',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. every report read of a month, as the application (row-level security on): under verify.max_ms each, the best of
    --     three runs
    grant select, insert on v0008x_old_cache, v0008x_old_keys to cma_app;
    perform set_config('role', 'cma_app', true);
    v_slow := '';
    v_times := '';
    foreach v_q in array array[
      'first_orders_page|select * from cma.first_orders_page(''2026-10-01'', ''2026-10-31'', ''day'', null, null)',
      'first_orders_report_of|select * from cma.first_orders_report_of(current_setting(''app.tenant_id'')::uuid, ''2026-10-01'', ''2026-10-31'', ''day'', null, null)',
      'first_orders_amounts_of|select * from cma.first_orders_amounts_of(current_setting(''app.tenant_id'')::uuid, ''2026-10-01'', ''2026-10-31'', null, null)',
      'first_orders_list|select * from cma.first_orders_list(''2026-10-01'', ''2026-10-31'', null, null)',
      'first_orders_per_person_of|select * from cma.first_orders_per_person_of(current_setting(''app.tenant_id'')::uuid, ''2026-10-01'', ''2026-10-31'', null, null)',
      'first_orders_history_start_of|select * from cma.first_orders_history_start_of(current_setting(''app.tenant_id'')::uuid)',
      'email_report_page NL|select * from cma.email_report_page(''2026-10-01'', ''2026-10-31'', ''day'', ''NL'', null, null)',
      'email_report_of|select * from cma.email_report_of(current_setting(''app.tenant_id'')::uuid, ''2026-10-01'', ''2026-10-31'', ''day'', null, null, null)',
      'email_overview_of|select * from cma.email_overview_of(current_setting(''app.tenant_id'')::uuid, ''2026-10-01'', ''2026-10-31'', ''day'', null, null, null)',
      'email_by_dimension_of|select * from cma.email_by_dimension_of(current_setting(''app.tenant_id'')::uuid, ''2026-10-01'', ''2026-10-31'', null, null, null)',
      'email_received_series_of|select * from cma.email_received_series_of(current_setting(''app.tenant_id'')::uuid, ''2026-10-01'', ''2026-10-31'', ''day'', ''inbox'', null, null, null)',
      'email_per_person_page|select * from cma.email_per_person_page(''2026-10-01'', ''2026-10-31'', null, null, null)',
      'email_per_person_of|select * from cma.email_per_person_of(current_setting(''app.tenant_id'')::uuid, ''2026-10-01'', ''2026-10-31'', null, null, null)',
      'email_waiting_of|select * from cma.email_waiting_of(current_setting(''app.tenant_id'')::uuid)',
      'email_not_responding_of|select * from cma.email_not_responding_of(current_setting(''app.tenant_id'')::uuid)',
      'email_history_start_of|select count(*) from (select cma.email_history_start_of(current_setting(''app.tenant_id'')::uuid)) x'] loop
      v_name := split_part(v_q, '|', 1);
      v_ms := pg_temp.v0008x_best_ms(split_part(v_q, '|', 2), 3);
      v_times := v_times || v_name || ' ' || v_ms || ' ms; ';
      if v_ms >= v_max then
        v_slow := v_slow || v_name || ' ' || v_ms || ' ms; ';
      end if;
    end loop;
    v_rows := v_rows || array['17', format('B8 every report read of a month as the application under %s ms (best of three)', v_max),
      case when v_slow = '' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(nullif('too slow: ' || v_slow, 'too slow: '), v_times)];

    -- B9. the email report, per person and the first orders pass against their 0008t and 0008u definitions, as the application
    --     (one run each: the old ones are slow), at least five times faster
    v_ratio := '';
    v_ok := true;
    foreach v_q in array array[
      'email_report_of|select * from cma.email_report_of(current_setting(''app.tenant_id'')::uuid, ''2026-10-01'', ''2026-10-31'', ''day'', null, null, null)|select * from pg_temp.v0008x_old_email_report_of(current_setting(''app.tenant_id'')::uuid, ''2026-10-01'', ''2026-10-31'', ''day'', null, null, null)',
      'email_per_person_of|select * from cma.email_per_person_of(current_setting(''app.tenant_id'')::uuid, ''2026-10-01'', ''2026-10-31'', null, null, null)|select * from pg_temp.v0008x_old_email_per_person_of(current_setting(''app.tenant_id'')::uuid, ''2026-10-01'', ''2026-10-31'', null, null, null)'] loop
      v_new_ms := pg_temp.v0008x_best_ms(split_part(v_q, '|', 2), 1);
      v_old_ms := pg_temp.v0008x_best_ms(split_part(v_q, '|', 3), 1);
      v_ratio := v_ratio || format('%s %s ms (0008t/u %s ms); ', split_part(v_q, '|', 1), v_new_ms, v_old_ms);
      v_ok := v_ok and v_new_ms * 5 <= v_old_ms;
    end loop;
    -- the first orders pass itself (the old reads take it from the cache filled in B2)
    v_new_ms := pg_temp.v0008x_best_ms(format('select * from cma.first_orders_of(%L, %L, %L)', t, w_from, w_to), 1);
    v_old_ms := pg_temp.v0008x_best_ms(format('select * from pg_temp.v0008x_old_first_orders_compute(%L, %L, %L)', t, w_from, w_to), 1);
    v_ratio := v_ratio || format('first_orders_of %s ms (0008u %s ms)', v_new_ms, v_old_ms);
    v_ok := v_ok and v_new_ms * 5 <= v_old_ms;
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['18', 'B9 at least five times faster than the 0008t and 0008u definitions, as the application',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, v_ratio];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['19', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008x (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008x values (19, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008x
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008x where result = 'PASS') = 13
                       and not exists (select 1 from verify_0008x where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008x where result = 'PASS'),
                                        (select count(*) from verify_0008x where result <> 'PASS'))) x
order by ord;
reset role;
