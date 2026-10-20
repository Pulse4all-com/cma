-- Local only: a throwaway tenant at twice prod's lead volume of 19 October 2026 (prod: 1,309 lead deals in all,
-- 4,156 CRM calls), September and October 2026: 3,000 lead deals, 1,500 order deals, 3,300 contacts, about
-- 9,600 CRM calls with their associations, 6,000 telephony calls half of them linked. Times both page reads of
-- October as cma_app (best of three), then rolls back.
-- Never for dev or prod: it refuses a database where the role cloudsqladmin exists (every Cloud SQL instance has it).
--   psql -h /var/run/postgresql -d <local database at 92> -f docs/attempts-2026-10/local-records/db/volume-timing.sql
\set ON_ERROR_STOP on
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'cloudsqladmin') then
    raise exception 'local only: this is a Cloud SQL instance';
  end if;
end
$$;
set role cma_owner;
begin;
select cma.create_tenant('volume-0008y', 'Volume 0008y', 'Europe/Amsterdam') as t \gset
select set_config('app.tenant_id', :'t', true);
insert into cma.app_user (tenant_id, email, display_name) values (:'t', 'volume-analyst@example.invalid', 'analyst') returning id as u \gset
insert into cma.user_role (tenant_id, user_id, role_id) select :'t', :'u', r.id from cma.app_role r where r.tenant_id = :'t' and r.key = 'manager';
select set_config('app.user_id', :'u', true);
insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, settings)
values (:'t', 'volcrm', 'Volume CRM', 'portal-v', '{"record_url_deal": "https://crm.example.invalid/{account}/deal/{id}"}') returning id as c \gset
insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (:'t', 'voltel', 'Volume telephony', 'tel-v') returning id as tel \gset
insert into cma.market (tenant_id, code, name, time_zone, language_code, currency)
values (:'t', 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR'), (:'t', 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP'),
       (:'t', 'DE', 'Germany', 'Europe/Berlin', 'de', 'EUR');
insert into cma.business_hours (tenant_id, market, weekday, opens_at, closes_at)
select :'t', '*', d, time '09:00', time '17:00' from generate_series(1, 5) d;
insert into cma.business_holiday (tenant_id, market, day, name) values (:'t', 'NL', date '2026-10-13', 'h'), (:'t', '*', date '2026-09-21', 'h');
insert into cma.tenant_setting (tenant_id, key, value) values (:'t', 'intake.start_date', '2026-08-01'), (:'t', 'speed_to_lead.pre_window_minutes', '10'), (:'t', 'reports.per_person', 'attempts');
insert into cma.app_user_external_id (tenant_id, user_id, system, external_id) values (:'t', :'u', 'volcrm_owner', 'o-1');
insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted, is_lead, is_order)
values (:'t', :'c', 'deal', 'sales', 'Sales', true, true, false), (:'t', :'c', 'deal', 'orders', 'Orders', true, true, true),
       (:'t', :'c', 'deal', 'renew', 'Renewals', true, false, false);
insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, display_order, is_closed, outcome, outcome_source)
values (:'t', :'c', 'deal', 'sales', 's1', 'Open', 1, false, null, null), (:'t', :'c', 'deal', 'sales', 'sw', 'Won', 2, true, 'won', 'source'),
       (:'t', :'c', 'deal', 'sales', 'sl', 'Lost', 3, true, 'lost', 'source'), (:'t', :'c', 'deal', 'orders', 'o1', 'Won', 1, true, 'won', 'source'),
       (:'t', :'c', 'deal', 'renew', 'r1', 'Open', 1, false, null, null);
insert into cma.connection_call_outcome (tenant_id, connection_id, outcome_ref, label, is_connected)
values (:'t', :'c', 'connected', 'Connected', true), (:'t', :'c', 'no_answer', 'No answer', false);
-- contacts
insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country)
select :'t', :'c', 'volcrm', 'k' || g, (array['NL', 'GB', 'DE', null])[1 + g % 4] from generate_series(1, 3300) g;
-- lead deals (3,000 over 1 September to 31 October), order deals (1,500), renewals (300)
insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref, contact_source_id,
                            market, is_closed, closed_at, source_created_at)
select :'t', :'c', 'volcrm', 'deal', 'd' || g, 'sales', case when g % 4 = 0 then 'sw' when g % 4 = 1 then 'sl' else 's1' end,
       case when g % 3 = 0 then 'o-1' when g % 3 = 1 then 'o-2' end, 'k' || (1 + g % 3300),
       case when g % 5 = 0 then null else (array['NL', 'GB', 'DE'])[1 + g % 3] end,
       g % 4 in (0, 1), case when g % 4 in (0, 1) then timestamptz '2026-09-01 08:00+00' + (g * interval '29 minutes') + interval '3 days' end,
       timestamptz '2026-09-01 08:00+00' + (g * interval '29 minutes')
from generate_series(1, 3000) g;
insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, contact_source_id,
                            market, is_closed, closed_at, source_created_at)
select :'t', :'c', 'volcrm', 'deal', 'o' || g, 'orders', 'o1', 'k' || (1 + (g * 7) % 3300), 'NL', true,
       timestamptz '2026-09-01 08:00+00' + (g * interval '58 minutes'), timestamptz '2026-09-01 08:00+00' + (g * interval '58 minutes')
from generate_series(1, 1500) g;
insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, contact_source_id,
                            market, is_closed, source_created_at)
select :'t', :'c', 'volcrm', 'deal', 'r' || g, 'renew', 'r1', 'k' || (1 + (g * 11) % 3300), 'NL', false,
       timestamptz '2026-09-01 08:00+00' + (g * interval '290 minutes')
from generate_series(1, 300) g;
-- deal -> contact associations: the primary contact, and a second contact for every tenth deal
insert into cma.crm_association (tenant_id, connection_id, from_type, from_id, to_type, to_id, source_changed_at)
select :'t', :'c', 'deal', r.source_id, 'contact', r.contact_source_id, r.source_created_at
from cma.crm_record r where r.tenant_id = :'t';
insert into cma.crm_association (tenant_id, connection_id, from_type, from_id, to_type, to_id, source_changed_at)
select :'t', :'c', 'deal', 'd' || g, 'contact', 'k' || (1 + (g + 1700) % 3300), now() from generate_series(10, 3000, 10) g
on conflict do nothing;
-- CRM calls: 0 to 6 per lead deal on its contact (a few on the deal), 90 % outbound, a third connected, from 2 minutes to
-- 4 days after the creation; and 600 calls on the order deals' contacts
insert into cma.crm_call (tenant_id, connection_id, source_system, source_id, occurred_at, direction, outcome_ref, counterpart_hash)
select :'t', :'c', 'volcrm', 'c' || g || '-' || n, timestamptz '2026-09-01 08:00+00' + (g * interval '29 minutes') + (n * n * interval '137 minutes') + interval '2 minutes',
       case when (g + n) % 10 = 0 then 'inbound' else 'outbound' end, case when (g * n) % 3 = 0 then 'connected' else 'no_answer' end,
       md5('h' || g || '-' || n) || md5('x' || g || '-' || n)
from generate_series(1, 3000) g cross join lateral generate_series(1, g % 7) n;
insert into cma.crm_association (tenant_id, connection_id, from_type, from_id, to_type, to_id, source_changed_at)
select :'t', :'c', 'crm_call', cc.source_id,
       case when cc.source_id like '%-1' and split_part(substr(cc.source_id, 2), '-', 1)::int % 5 = 0 then 'deal' else 'contact' end,
       case when cc.source_id like '%-1' and split_part(substr(cc.source_id, 2), '-', 1)::int % 5 = 0 then 'd' || split_part(substr(cc.source_id, 2), '-', 1)
            else 'k' || (1 + split_part(substr(cc.source_id, 2), '-', 1)::int % 3300) end, cc.occurred_at
from cma.crm_call cc where cc.tenant_id = :'t';
insert into cma.crm_call (tenant_id, connection_id, source_system, source_id, occurred_at, direction, outcome_ref)
select :'t', :'c', 'volcrm', 'co' || g, timestamptz '2026-09-01 08:00+00' + (g * interval '115 minutes'), 'outbound', 'no_answer' from generate_series(1, 600) g;
insert into cma.crm_association (tenant_id, connection_id, from_type, from_id, to_type, to_id, source_changed_at)
select :'t', :'c', 'crm_call', 'co' || g, 'contact', 'k' || (1 + (g * 7) % 3300), now() from generate_series(1, 600) g;
-- telephony calls: one per CRM call for half of them, linked, 20 seconds earlier; and 1,500 inbound calls of their own
insert into cma.telephony_number (tenant_id, connection_id, number_ref, name, market) values (:'t', :'tel', 'n1', 'line', 'NL');
insert into cma.telephony_call (tenant_id, connection_id, source_system, source_id, direction, started_at, answered_at, ended_at, number_ref,
                                counterpart_hash, source_version_at)
select :'t', :'tel', 'voltel', 't' || cc.source_id, cc.direction, cc.occurred_at - interval '20 seconds',
       case when cc.outcome_ref = 'connected' then cc.occurred_at end, cc.occurred_at + interval '3 minutes', 'n1', cc.counterpart_hash, now()
from cma.crm_call cc where cc.tenant_id = :'t' and cc.counterpart_hash is not null and abs(hashtext(cc.source_id)) % 2 = 0;
insert into cma.call_link (tenant_id, telephony_call_id, crm_call_id, method, delta_seconds)
select :'t', tc.id, cc.id, 'hash_time', -20
from cma.telephony_call tc join cma.crm_call cc on cc.tenant_id = tc.tenant_id and cc.source_id = substr(tc.source_id, 2)
where tc.tenant_id = :'t';
insert into cma.telephony_call (tenant_id, connection_id, source_system, source_id, direction, started_at, answered_at, ended_at, number_ref, source_version_at)
select :'t', :'tel', 'voltel', 'ti' || g, 'inbound', timestamptz '2026-09-01 08:00+00' + (g * interval '58 minutes'),
       timestamptz '2026-09-01 08:00+00' + (g * interval '58 minutes') + interval '10 seconds',
       timestamptz '2026-09-01 08:00+00' + (g * interval '58 minutes') + interval '4 minutes', 'n1', now() from generate_series(1, 1500) g;
analyze cma.crm_record; analyze cma.crm_contact; analyze cma.crm_call; analyze cma.crm_association; analyze cma.telephony_call;
analyze cma.call_link; analyze cma.connection_pipeline; analyze cma.connection_stage; analyze cma.market; analyze cma.app_user_external_id;
select (select count(*) from cma.crm_record where tenant_id = :'t') as deals, (select count(*) from cma.crm_call where tenant_id = :'t') as crm_calls,
       (select count(*) from cma.crm_association where tenant_id = :'t') as associations, (select count(*) from cma.telephony_call where tenant_id = :'t') as telephony,
       (select count(*) from cma.call_link where tenant_id = :'t') as links,
       (select count(*) from cma.crm_record where tenant_id = :'t' and pipeline_id = 'sales' and source_created_at >= '2026-09-30 22:00+00' and source_created_at < '2026-10-31 23:00+00') as october_lead_deals;
set role cma_app;
create temp table if not exists timing (read text, ms numeric, n integer);
do $$
declare
  v_t0 timestamptz; v_best numeric; v_ms numeric; v_q text; j jsonb;
begin
  foreach v_q in array array[
    'attempts_per_deal_page day|select cma.attempts_per_deal_page(''2026-10-01'', ''2026-10-31'', ''day'', null, null, ''lead'')',
    'attempts_per_deal_page pipeline counted|select cma.attempts_per_deal_page(''2026-10-01'', ''2026-10-31'', ''pipeline'', null, null, ''counted'')',
    'attempts_per_deal_page market NL|select cma.attempts_per_deal_page(''2026-10-01'', ''2026-10-31'', ''market'', ''NL'', null, ''lead'')',
    'attempts_per_person_page|select cma.attempts_per_person_page(''2026-10-01'', ''2026-10-31'', null, null, ''lead'')'] loop
    v_best := null;
    for i in 1 .. 3 loop
      v_t0 := clock_timestamp();
      execute split_part(v_q, '|', 2) into j;
      v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
      v_best := least(coalesce(v_best, v_ms), v_ms);
    end loop;
    insert into timing values (split_part(v_q, '|', 1), v_best,
      coalesce((j -> 'current' ->> 'deals')::int, (j -> 'total' ->> 'deals')::int));
  end loop;
end
$$;
select * from timing;
rollback;
