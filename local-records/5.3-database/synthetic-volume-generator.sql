-- Synthetic volume for the Pulse4all Subscriptions tenant in cma_perf (a throwaway copy). Fictional values only.
-- Roughly a year of prod scale: 13 agents x 250 workdays x ~40 status events, 60k telephony calls, 30k CRM calls,
-- 85k CRM records, 40k contacts, 100k tasks, 50k emails, 10k form submissions, 100k ingest events, 20k alerts.
\timing on
set role cma_owner;
set statement_timeout = 0;
begin;
select set_config('app.tenant_id', '01a14ac1-8b06-7f8a-ac30-8849132389aa', true),
       set_config('app.user_id', '01a14ac1-8b63-750c-82eb-28e08a97472b', true),
       set_config('app.actor_label', 'audit:synthetic-volume', true);

-- 0. configuration through the functions, as the admin of the tenant (cma_app rights)
create temp table cfg (k text primary key, v text);
grant all on cfg to cma_app;
select set_config('role', 'cma_app', true);
insert into cfg select 'tel', (select connection_id::text from cma.upsert_connection('aircall', 'Aircall (synthetic)', 'company-1', null, null));
insert into cfg select 'crm', (select connection_id::text from cma.upsert_connection('hubspot', 'HubSpot (synthetic)', 'portal-1', null, null));
select cma.set_connection_kind((select v::uuid from cfg where k='tel'), 'telephony');
select cma.set_connection_kind((select v::uuid from cfg where k='crm'), 'crm');
select cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', null, null, 10);
select cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', null, null, 20);
select cma.set_telephony_number((select v::uuid from cfg where k='tel'), 'line-nl', 'NL', true);
select cma.set_telephony_number((select v::uuid from cfg where k='tel'), 'line-gb', 'GB', true);
select cma.set_telephony_tag((select v::uuid from cfg where k='tel'), 'sale', true);
select cma.set_telephony_tag((select v::uuid from cfg where k='tel'), 'callback', true);
select cma.set_telephony_tag((select v::uuid from cfg where k='tel'), 'internal', false);
select set_config('role', 'cma_owner', true);

insert into cma.business_hours (tenant_id, market, weekday, opens_at, closes_at)
select cma.current_tenant_id(), m, d, time '09:00', time '17:30' from unnest(array['NL','GB']) m, generate_series(1,5) d;

insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted, is_lead, sla_minutes, refreshed_at)
values (cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'deal', 'sales', 'Sales', true, true, null, now()),
       (cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'ticket', 'support', 'Support', true, false, 240, now());
insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, display_order, is_closed)
values (cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'deal', 'sales', 'new', 'New', 1, false),
       (cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'deal', 'sales', 'won', 'Won', 2, true),
       (cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'deal', 'sales', 'lost', 'Lost', 3, true),
       (cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'ticket', 'support', 'open', 'Open', 1, false),
       (cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'ticket', 'support', 'closed', 'Closed', 2, true);
insert into cma.connection_form (tenant_id, connection_id, source_form_id, name, is_counted, market, is_polled, refreshed_at)
values (cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'form-contact', 'Contact form (synthetic)', true, 'NL', true, now());

-- 1. people: 11 more agents so the tenant has 13, each with a CRM owner id and a telephony user id
create temp table agents (n int, user_id uuid, hs text, ac text);
insert into cma.app_user (tenant_id, email, display_name, timezone)
select cma.current_tenant_id(), format('synthetic.agent%s@example.invalid', n), format('Synthetic Agent %s', n), 'Europe/Amsterdam'
from generate_series(3, 13) n;
insert into agents select row_number() over (order by u.email), u.id, null, null from cma.app_user u
where u.tenant_id = cma.current_tenant_id() and (u.email like 'synthetic.agent%' or u.email in ('agent.one@example.com','agent.two@example.com'));
update agents set hs = (2000 + n)::text, ac = (3000 + n)::text;
insert into cma.user_role (tenant_id, user_id, role_id)
select cma.current_tenant_id(), a.user_id, r.id from agents a join cma.app_role r on r.tenant_id = cma.current_tenant_id() and r.key = 'agent'
where not exists (select 1 from cma.user_role ur where ur.user_id = a.user_id and ur.role_id = r.id);
insert into cma.team_member (tenant_id, user_id, team_id)
select cma.current_tenant_id(), a.user_id, t.id from agents a join cma.team t on t.tenant_id = cma.current_tenant_id() and t.key = 'nl'
where not exists (select 1 from cma.team_member m where m.user_id = a.user_id and m.team_id = t.id and m.valid_to is null);
insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
select cma.current_tenant_id(), a.user_id, 'hubspot_user', a.hs from agents a on conflict do nothing;
insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
select cma.current_tenant_id(), a.user_id, 'aircall_user', a.ac from agents a on conflict do nothing;
-- the manager owns deals too
insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
values (cma.current_tenant_id(), '01a14ac1-8b63-7af0-87ba-8e70178a5517', 'aircall_user', '3999') on conflict do nothing;

-- 2. workdays and time events: 13 agents x weekdays of the last 365 days (ended), today open for 8 of them
create temp table days as
select d::date as d from generate_series(current_date - 365, current_date - 1, interval '1 day') d where extract(isodow from d) <= 5;
create temp table wd (workday_id uuid, user_id uuid, d date, started_at timestamptz, ended_at timestamptz);
with ins as (
  insert into cma.workday (tenant_id, user_id, business_date, timezone, status, started_at, ended_at)
  select cma.current_tenant_id(), a.user_id, x.d, 'Europe/Amsterdam', 'ended',
         (x.d + time '08:30') at time zone 'Europe/Amsterdam' + ((a.n * 7 + extract(doy from x.d)::int) % 40) * interval '1 minute',
         (x.d + time '17:00') at time zone 'Europe/Amsterdam' + ((a.n * 3 + extract(doy from x.d)::int) % 50) * interval '1 minute'
  from agents a cross join days x
  where not exists (select 1 from cma.workday w where w.tenant_id = cma.current_tenant_id() and w.user_id = a.user_id and w.business_date = x.d)
  returning id, user_id, business_date, started_at, ended_at)
insert into wd select * from ins;
-- statuses by flag: working statuses cycle, pauses in between
create temp table st as select id, key, is_working, row_number() over (order by key) as rn, count(*) over () as cnt
from cma.work_status where tenant_id = cma.current_tenant_id() and status = 'active';
insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source)
select cma.current_tenant_id(), w.workday_id, w.user_id, 'start', (select id from st where key = 'available_sales'), w.started_at, w.started_at, 'user' from wd w;
insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source)
select cma.current_tenant_id(), w.workday_id, w.user_id, 'status',
       (select id from st where rn = 1 + ((k + (extract(doy from w.d)::int)) % (select cnt from st limit 1))),
       w.started_at + k * interval '13 minutes', w.started_at + k * interval '13 minutes', 'user'
from wd w cross join generate_series(1, 38) k
where w.started_at + k * interval '13 minutes' < w.ended_at;
insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source)
select cma.current_tenant_id(), w.workday_id, w.user_id, 'end', null, w.ended_at, w.ended_at, 'user' from wd w;
-- today: open days for 8 agents, started 08:30 local, a few status events up to now
with t as (
  insert into cma.workday (tenant_id, user_id, business_date, timezone, status, started_at)
  select cma.current_tenant_id(), a.user_id, current_date, 'Europe/Amsterdam', 'open',
         least((current_date + time '08:30') at time zone 'Europe/Amsterdam' + a.n * interval '2 minutes', now() - interval '1 minute')
  from agents a where a.n <= 8
    and not exists (select 1 from cma.workday w where w.tenant_id = cma.current_tenant_id() and w.user_id = a.user_id and w.business_date = current_date)
  returning id, user_id, started_at)
insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source)
select cma.current_tenant_id(), t.id, t.user_id, 'start', (select id from st where key = 'available_sales'), t.started_at, t.started_at, 'user' from t;

-- 3. telephony calls: 60k over the year, on the two counted lines, by the agents
analyze cma.workday; analyze cma.time_event; analyze cma.app_user; analyze cma.app_user_external_id;
create temp table calls as
select n,
       'c' || n as source_id,
       (current_date - 365 + (n % 365)) as d,
       ((current_date - 365 + (n % 365)) + time '08:00') at time zone 'Europe/Amsterdam' + ((n * 7919) % 720) * interval '1 minute' as started_at,
       case when n % 100 < 55 then 'inbound' else 'outbound' end as direction,
       (n % 100) < 80 as answered,
       60 + (n * 31) % 900 as dur,
       case when n % 10 < 7 then 'line-nl' else 'line-gb' end as line,
       (select ac from agents where agents.n = 1 + (calls_n.n % 13)) as ac,
       (select hs from agents where agents.n = 1 + (calls_n.n % 13)) as hs,
       md5(n::text || 'a') || md5(n::text || 'b') as hash
from generate_series(1, 60000) as calls_n(n);
insert into cma.telephony_call (tenant_id, connection_id, source_system, source_id, direction, status, missed_reason, started_at, answered_at, ended_at,
                                duration_seconds, user_ref, number_ref, counterpart_hash, source_version_at, synced_at, raw)
select cma.current_tenant_id(), (select v::uuid from cfg where k='tel'), 'aircall', c.source_id, c.direction,
       case when c.answered then 'done' else 'missed' end,
       case when not c.answered and c.direction = 'inbound' then (array['no_available_agent','out_of_opening_hours','abandoned_in_ivr'])[1 + c.n % 3] end,
       c.started_at, case when c.answered then c.started_at + ((c.n % 40) + 3) * interval '1 second' end,
       c.started_at + c.dur * interval '1 second', c.dur,
       case when c.answered or c.direction = 'outbound' then c.ac end, c.line, c.hash, c.started_at + interval '2 minutes', c.started_at + interval '3 minutes',
       jsonb_build_object('id', c.n, 'direction', c.direction, 'status', case when c.answered then 'done' else 'missed' end, 'duration', c.dur,
                          'number', jsonb_build_object('id', c.line, 'name', 'Line'), 'user', jsonb_build_object('id', c.ac),
                          'raw_digits', '[redacted]', 'tags', '[]'::jsonb, 'comments', '[]'::jsonb, 'recording', null,
                          'started_at', extract(epoch from c.started_at)::bigint, 'answered_at', null, 'ended_at', extract(epoch from c.started_at + c.dur * interval '1 second')::bigint,
                          'cost', '0.00', 'country_code_a2', 'NL', 'asset', null, 'archived', false, 'teams', '[]'::jsonb)
from calls c;
analyze cma.telephony_call;
insert into cma.telephony_call_tag (tenant_id, connection_id, call_source_id, tag_ref, tagged_at)

select cma.current_tenant_id(), (select v::uuid from cfg where k='tel'), c.source_id, case when c.n % 3 = 0 then 'sale' else 'callback' end, c.started_at + c.dur * interval '1 second'
from calls c where c.n % 10 < 3;

analyze cma.telephony_call_tag;
-- 4. CRM: contacts, deals, tickets, calls linked to half of the telephony calls, tasks, emails, forms
insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, country_source, source_updated_at, raw)
select cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'hubspot', 'ct' || n, case when n % 10 < 7 then 'NL' else 'GB' end, 1,
       (current_date - 365 + (n % 365))::timestamptz, jsonb_build_object('id', 'ct' || n, 'properties', jsonb_build_object('country', 'NL', 'hs_object_id', n))
from generate_series(1, 40000) n;
analyze cma.crm_contact;
insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref, contact_source_id, market, is_closed, closed_at, source_created_at, source_updated_at, raw, amount, currency)
select cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'hubspot', 'deal', 'd' || n, 'sales',
       case when n % 10 < 3 then 'new' when n % 10 < 7 then 'won' else 'lost' end,
       (select hs from agents where agents.n = 1 + (g.n % 13)), 'ct' || (1 + (n * 7) % 40000), case when n % 10 < 7 then 'NL' else 'GB' end,
       n % 10 >= 3, case when n % 10 >= 3 then ((current_date - 365 + (n % 365)) + time '14:00') at time zone 'Europe/Amsterdam' + interval '3 days' end,
       ((current_date - 365 + (n % 365)) + time '10:00') at time zone 'Europe/Amsterdam' + ((n * 131) % 480) * interval '1 minute',
       ((current_date - 365 + (n % 365)) + time '10:00') at time zone 'Europe/Amsterdam' + interval '1 day',
       jsonb_build_object('id', 'd' || n, 'properties', jsonb_build_object('dealstage', 'new', 'pipeline', 'sales', 'amount', '99', 'deal_country', 'NL', 'hs_object_id', n, 'createdate', '2026-01-01T00:00:00Z')),
       99, 'EUR'
from generate_series(1, 40000) g(n);
insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref, contact_source_id, market, is_closed, closed_at, source_created_at, source_updated_at, raw)
select cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'hubspot', 'ticket', 't' || n, 'support',
       case when n % 10 < 2 then 'open' else 'closed' end,
       case when n % 20 = 0 then null else (select hs from agents where agents.n = 1 + (g.n % 13)) end, 'ct' || (1 + (n * 11) % 40000), case when n % 10 < 7 then 'NL' else 'GB' end,
       n % 10 >= 2, case when n % 10 >= 2 then ((current_date - 365 + (n % 365)) + time '11:00') at time zone 'Europe/Amsterdam' + interval '5 hours' end,
       ((current_date - 365 + (n % 365)) + time '09:00') at time zone 'Europe/Amsterdam' + ((n * 97) % 540) * interval '1 minute',
       ((current_date - 365 + (n % 365)) + time '09:00') at time zone 'Europe/Amsterdam' + interval '6 hours',
       jsonb_build_object('id', 't' || n, 'properties', jsonb_build_object('hs_pipeline_stage', 'open', 'hs_pipeline', 'support', 'hs_object_id', n))
from generate_series(1, 45000) g(n);
insert into cma.crm_call (tenant_id, connection_id, source_system, source_id, occurred_at, direction, status, outcome_ref, duration_seconds, owner_ref, source_app, counterpart_hash, source_created_at, raw)
select cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'hubspot', 'hc' || c.n, c.started_at + interval '20 seconds', c.direction, 'COMPLETED',
       case when c.answered then 'CONNECTED' else 'NO_ANSWER' end, c.dur, c.hs, 'aircall', c.hash, c.started_at + interval '1 minute',
       jsonb_build_object('id', 'hc' || c.n, 'properties', jsonb_build_object('hs_call_direction', upper(c.direction), 'hs_call_duration', c.dur * 1000, 'hubspot_owner_id', c.hs))
from calls c where c.n % 2 = 0;
analyze cma.crm_record; analyze cma.crm_call;
insert into cma.call_link (tenant_id, telephony_call_id, crm_call_id, method, delta_seconds, linked_at, linked_by)
select cma.current_tenant_id(), t.id, h.id, 'hash_time', 20, h.occurred_at + interval '5 minutes', '01a14ac1-928c-7915-bfe1-9145ba34606c'
from cma.crm_call h join cma.telephony_call t on t.tenant_id = h.tenant_id and t.counterpart_hash = h.counterpart_hash
where h.tenant_id = cma.current_tenant_id() and h.source_system = 'hubspot' and h.source_id like 'hc%';
insert into cma.crm_association (tenant_id, connection_id, from_type, from_id, to_type, to_id, first_seen_at, source_changed_at)
select cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'crm_call', 'hc' || c.n, 'deal', 'd' || (1 + (c.n % 40000)), c.started_at + interval '1 minute', c.started_at + interval '1 minute'
from calls c where c.n % 2 = 0;
insert into cma.crm_task (tenant_id, connection_id, source_system, source_id, owner_ref, status_ref, type_ref, priority_ref, due_at, completed_at, contact_source_id, deal_source_id, source_created_at, source_updated_at, raw)
select cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'hubspot', 'task' || n, (select hs from agents where agents.n = 1 + (g.n % 13)),
       case when n % 10 < 8 then 'COMPLETED' else 'NOT_STARTED' end, 'CALL', 'MEDIUM',
       ((current_date - 365 + (n % 365)) + time '12:00') at time zone 'Europe/Amsterdam' + interval '1 day',
       case when n % 10 < 8 then ((current_date - 365 + (n % 365)) + time '12:00') at time zone 'Europe/Amsterdam' + interval '20 hours' end,
       'ct' || (1 + (n * 13) % 40000), 'd' || (1 + (n % 40000)),
       ((current_date - 365 + (n % 365)) + time '12:00') at time zone 'Europe/Amsterdam', ((current_date - 365 + (n % 365)) + time '12:00') at time zone 'Europe/Amsterdam', '{}'::jsonb
from generate_series(1, 100000) g(n);
insert into cma.email_message (tenant_id, connection_id, source_system, source_kind, source_id, direction, status, occurred_at, actor_kind, owner_ref, contact_source_id, source_created_at, raw)
select cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'hubspot', 'crm_email', 'em' || n, case when n % 2 = 0 then 'out' else 'in' end, 'sent',
       ((current_date - 365 + (n % 365)) + time '09:00') at time zone 'Europe/Amsterdam' + ((n * 37) % 600) * interval '1 minute',
       case when n % 2 = 0 then 'agent' else 'customer' end, case when n % 2 = 0 then (select hs from agents where agents.n = 1 + (g.n % 13)) end,
       'ct' || (1 + (n * 17) % 40000), ((current_date - 365 + (n % 365)) + time '09:00') at time zone 'Europe/Amsterdam',
       jsonb_build_object('id', 'em' || n, 'properties', jsonb_build_object('hs_email_direction', 'EMAIL', 'hs_email_status', 'SENT', 'hs_timestamp', '2026-01-01T00:00:00Z'))
from generate_series(1, 50000) g(n);
insert into cma.form_submission (tenant_id, connection_id, source_id, source_form_id, submitted_at, page_host, page_path, contact_source_id, contact_resolution, kept_values)
select cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'fs' || n, 'form-contact',
       ((current_date - 365 + (n % 365)) + time '10:00') at time zone 'Europe/Amsterdam' + ((n * 53) % 600) * interval '1 minute',
       'www.example.invalid', '/contact', 'ct' || (1 + (n * 19) % 40000), 'resolved', '{}'::jsonb
from generate_series(1, 10000) n;

analyze cma.call_link; analyze cma.crm_association; analyze cma.crm_task; analyze cma.email_message; analyze cma.form_submission;
-- 5. ingest events: 100k processed webhooks over the year, each with a ~1 KB payload
insert into cma.ingest_event (tenant_id, connection_id, event_key, source_type, kind, object_type, object_id, property_name, occurred_at, recorded_at, raw, status, attempts, next_attempt_at, processed_at)
select cma.current_tenant_id(), (select v::uuid from cfg where k='crm'), 'evt-' || n, 'webhook', (array['created','changed','changed','changed','deleted'])[1 + n % 5],
       (array['deal','ticket','contact','task'])[1 + n % 4], 'd' || (1 + n % 40000), case when n % 5 in (1,2,3) then 'dealstage' end,
       ((current_date - 365 + (n % 365)) + time '08:00') at time zone 'Europe/Amsterdam' + ((n * 43) % 720) * interval '1 minute',
       ((current_date - 365 + (n % 365)) + time '08:00') at time zone 'Europe/Amsterdam' + ((n * 43) % 720) * interval '1 minute' + interval '2 seconds',
       jsonb_build_object('eventId', n, 'subscriptionId', 1234, 'portalId', 1, 'appId', 1, 'occurredAt', 1700000000000 + n, 'subscriptionType', 'deal.propertyChange',
                          'attemptNumber', 0, 'objectId', 1 + n % 40000, 'propertyName', 'dealstage', 'propertyValue', 'won', 'changeSource', 'CRM_UI',
                          'sourceId', 'userId:1001', 'changeFlag', 'NEW', 'padding', repeat('x', 600)),
       (array['processed','processed','processed','processed','processed','processed','processed','processed','ignored','failed'])[1 + n % 10], 1,
       ((current_date - 365 + (n % 365)) + time '08:00') at time zone 'Europe/Amsterdam' + ((n * 43) % 720) * interval '1 minute' + interval '1 minute',
       case when n % 10 <> 9 then ((current_date - 365 + (n % 365)) + time '08:00') at time zone 'Europe/Amsterdam' + ((n * 43) % 720) * interval '1 minute' + interval '5 seconds' end
from generate_series(1, 100000) n;

analyze cma.ingest_event;
-- 6. alerts: 20k messages, delivered to 3 agents each; most read
create temp table msgs (id uuid, created_at timestamptz, n int);
with ins as (
  insert into cma.message (tenant_id, kind, urgency, title, body, ref_system, ref_type, ref_id, ref_url, target, created_at)
  select cma.current_tenant_id(), 'alert', case when n % 5 = 0 then 'urgent' else 'normal' end, 'New deal ' || n, 'A deal was created in pipeline Sales.',
         'hubspot', 'deal', 'd' || (1 + n % 40000), 'https://app.example.invalid/contacts/1/record/0-3/' || n, '{}'::jsonb,
         ((current_date - 365 + (n % 365)) + time '09:00') at time zone 'Europe/Amsterdam' + ((n * 29) % 600) * interval '1 minute'
  from generate_series(1, 20000) n returning id, created_at)
insert into msgs select id, created_at, row_number() over (order by created_at) from ins;
analyze cma.message;
insert into cma.message_delivery (tenant_id, message_id, user_id, created_at, delivered_at, read_at, acknowledged_at)
select cma.current_tenant_id(), m.id, a.user_id, m.created_at,
       case when m.n % 50 <> 0 then m.created_at + interval '10 seconds' end,
       case when m.n % 50 <> 0 and m.n % 7 <> 0 then m.created_at + interval '3 minutes' end,
       null
from msgs m join agents a on a.n in (1 + m.n % 13, 1 + (m.n + 4) % 13, 1 + (m.n + 8) % 13);
-- the manager gets every urgent alert, 40 of them unread
insert into cma.message_delivery (tenant_id, message_id, user_id, created_at, delivered_at, read_at)
select cma.current_tenant_id(), m.id, '01a14ac1-8b63-7af0-87ba-8e70178a5517', m.created_at,
       case when m.n % 100 <> 0 then m.created_at + interval '10 seconds' end,
       case when m.n % 100 <> 0 and m.n <= 19800 then m.created_at + interval '1 hour' end
from msgs m where m.n % 5 = 0;

-- 7. roster: 52 published weeks for team nl, shifts Mon-Fri for the 13 agents
create temp table weeks as
select (date_trunc('week', current_date)::date - 7 * k) as ws from generate_series(-1, 51) k;
insert into cma.roster_week (tenant_id, team_id, week_start, status, version, published_at, published_by, created_by)
select cma.current_tenant_id(), t.id, w.ws, 'published', 1, w.ws::timestamptz - interval '3 days', '01a14ac1-8b63-7af0-87ba-8e70178a5517', '01a14ac1-8b63-7af0-87ba-8e70178a5517'
from weeks w join cma.team t on t.tenant_id = cma.current_tenant_id() and t.key = 'nl'
where not exists (select 1 from cma.roster_week rw where rw.tenant_id = cma.current_tenant_id() and rw.team_id = t.id and rw.week_start = w.ws);
analyze cma.roster_week;
insert into cma.roster_entry (tenant_id, roster_week_id, user_id, business_date, kind, start_time, end_time, recorded_at, recorded_by)
select cma.current_tenant_id(), rw.id, a.user_id, rw.week_start + d, 'shift', time '08:30', time '17:00', coalesce(rw.published_at, now()) - interval '1 hour', '01a14ac1-8b63-7af0-87ba-8e70178a5517'
from cma.roster_week rw join cma.team t on t.id = rw.team_id and t.key = 'nl' cross join agents a cross join generate_series(0, 4) d
where rw.tenant_id = cma.current_tenant_id() and rw.week_start in (select ws from weeks)
  and not exists (select 1 from cma.roster_entry e where e.roster_week_id = rw.id and e.user_id = a.user_id and e.business_date = rw.week_start + d);
insert into cma.roster_publication (tenant_id, roster_week_id, version, published_at, published_by)
select cma.current_tenant_id(), rw.id, 1, rw.published_at, rw.published_by from cma.roster_week rw
where rw.tenant_id = cma.current_tenant_id() and rw.week_start in (select ws from weeks)
  and not exists (select 1 from cma.roster_publication p where p.roster_week_id = rw.id);

-- 8. the audit's two update rows per ingest event (claim and finish), as the trigger would have written them
insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, changed_at, actor_user_id, actor_label, actor_db_role, actor_login)
select e.tenant_id, 'ingest_event', 'update', to_jsonb(e) - 'attempts' || '{"attempts": 0, "status": "received"}'::jsonb, to_jsonb(e) || '{"status": "received"}'::jsonb,
       e.recorded_at + interval '1 second', '01a14ac1-928c-7915-bfe1-9145ba34606c', 'ingest-api:synthetic', 'cma_app', 'cma-ingest@local.iam'
from cma.ingest_event e where e.tenant_id = cma.current_tenant_id() and e.event_key like 'evt-%';
insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, changed_at, actor_user_id, actor_label, actor_db_role, actor_login)
select e.tenant_id, 'ingest_event', 'update', to_jsonb(e) || '{"status": "received"}'::jsonb, to_jsonb(e),
       e.recorded_at + interval '4 seconds', '01a14ac1-928c-7915-bfe1-9145ba34606c', 'ingest-api:synthetic', 'cma_app', 'cma-ingest@local.iam'
from cma.ingest_event e where e.tenant_id = cma.current_tenant_id() and e.event_key like 'evt-%';
commit;
analyze;
select relname, n_live_tup from pg_stat_user_tables where schemaname='cma' order by 2 desc limit 25;
select pg_size_pretty(pg_database_size('cma_perf')) as db_size, pg_size_pretty(pg_total_relation_size('cma.audit_log')) as audit_log, pg_size_pretty(pg_total_relation_size('cma.ingest_event')) as ingest_event;
