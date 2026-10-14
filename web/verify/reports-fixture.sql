-- =============================================================================================
-- verify/reports-fixture.sql: a small intake fixture for running verify/api.mjs --reports (and the
-- full API verifier) against a LOCAL database built from db/00 to db/51 (B11, 12 October 2026); since
-- addition 0008i also --inbound, on a database at db/61 (the inbound part needs 0008i); since addition
-- 0008j also --calls, on a database at db/63 (the calls part needs 0008j)
-- =============================================================================================
-- Never for dev or prod: it refuses to run unless the session sets the local switch first, and it
-- refuses a database without the dev seed. All ids are invented; nothing personal is written (ids,
-- times, codes and counts only, as the ingest path allows). Dates are relative to today, so the
-- verifier's last 30 days always hold data. Rerunnable: a second run finds its connections and
-- stops.
--
--   psql -h /tmp -p 5433 -d cma -c "set cma.local_fixture = 'on'" -f verify/reports-fixture.sql
--   (or put  set cma.local_fixture = 'on';  in the same session before \i)
--
-- What it writes
--   pulse4all-subscriptions  a CRM, a telephony and a shop connection (so telephony and the shop are
--                            connected), markets NL and GB with office hours, lead deals called,
--                            not called open and closed, one owner mapped to Agent Two and one not,
--                            a deal of an unknown market, form submissions, telephony calls with a
--                            tag, shop customers and orders, and the record link template; since
--                            0008i inbound calls on the NL line for Inbound and the Live board: every
--                            reason of Pulse4all's seed and a code nobody saved, answered calls, a
--                            caller missed twice and then called back, a caller missed twice and not,
--                            a caller missed, called back and missed again (times missed 1),
--                            an anonymous caller, a call older than the lookback, a call waiting now,
--                            the connection's catalog rows and its record_url_call template (callers
--                            as invented 64-hex hashes, never made from a number); since 0008j calls
--                            for Calls and Calls per agent: a GB line and a line that does not count,
--                            a counted and an uncounted tag, telephony users linked to Agent Two and
--                            the test supervisor and one linked to nobody, connected, not connected
--                            and unanswered outbound calls and one at exactly the threshold, tagged,
--                            untagged and only-uncounted-tag conversations, a call on the line that
--                            does not count (skipped), calls of the previous period, and the mock
--                            identity reader (reports.view without performance.team)
--   pulse4all-invest         a CRM connection only, two deals and a form submission, and the mock
--                            identity invest-analyst (analytics), so a tenant without telephony or
--                            a shop can be read
do $$
begin
  if coalesce(current_setting('cma.local_fixture', true), '') <> 'on' then
    raise exception 'local fixture only: run  set cma.local_fixture = ''on''  in this session first';
  end if;
  if not exists (select 1 from cma.app_user where email = 'agent.two@example.com') then
    raise exception 'the dev seed is missing: this fixture needs db/03 and db/06';
  end if;
end
$$;
set role cma_owner;

do $$
declare
  v_subs uuid; v_inv uuid;
  v_admin uuid; v_agent2 uuid; v_ing uuid; v_admin_inv uuid; v_ing_inv uuid; v_inv_analyst uuid;
  v_crm uuid; v_tel uuid; v_shop uuid; v_crm_inv uuid;
  d date := current_date;
  ts text;
begin
  select id into v_subs from cma.tenant where slug = 'pulse4all-subscriptions';
  select id into v_inv from cma.tenant where slug = 'pulse4all-invest';
  if exists (select 1 from cma.integration_connection where tenant_id = v_subs and adapter = 'fixturecrm') then
    raise notice 'fixture already present';
    return;
  end if;
  select id into v_admin from cma.app_user where tenant_id = v_subs and email = 'admin@example.com';
  select id into v_agent2 from cma.app_user where tenant_id = v_subs and email = 'agent.two@example.com';
  select id into v_ing from cma.app_user where tenant_id = v_subs and email = 'ingest@system.invalid';
  select id into v_ing_inv from cma.app_user where tenant_id = v_inv and email = 'ingest@system.invalid';

  -- the invest tenant's analyst (mock identity invest-analyst) and an admin to configure it
  insert into cma.app_user (tenant_id, email, display_name) values (v_inv, 'invest.analyst@example.com', 'Test invest analyst') returning id into v_inv_analyst;
  insert into cma.app_user (tenant_id, email, display_name) values (v_inv, 'invest.admin@example.com', 'Test invest admin') returning id into v_admin_inv;
  insert into cma.user_role (tenant_id, user_id, role_id)
  select v_inv, x.uid, ar.id from (values (v_inv_analyst, 'analytics'), (v_admin_inv, 'admin')) x(uid, role_key)
  join cma.app_role ar on ar.tenant_id = v_inv and ar.key = x.role_key;
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id) values (v_inv, v_inv_analyst, 'mock', 'invest-analyst');

  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_subs, 'fixturecrm', 'Fixture CRM', 'portal-1') returning id into v_crm;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_subs, 'fixturetel', 'Fixture telephony', 'tel-1') returning id into v_tel;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_subs, 'fixtureshop', 'Fixture shop', 'shop.example.com') returning id into v_shop;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_inv, 'fixturecrm', 'Fixture CRM invest', 'portal-2') returning id into v_crm_inv;

  -- ---- pulse4all-subscriptions --------------------------------------------------------------
  perform set_config('role', 'cma_app', true);
  perform set_config('app.tenant_id', v_subs::text, true);
  perform set_config('app.user_id', v_admin::text, true);
  perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
  perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
  perform cma.set_business_hours('*', w::smallint, '09:00-17:00') from generate_series(1, 5) w;
  perform cma.set_tenant_setting('intake.start_date', (d - 60)::text);
  perform cma.set_user_external_id(v_agent2, 'fixturecrm_owner', 'o-1');
  perform cma.set_connection_settings(v_crm, '{"record_url_deal": "https://example.com/fixture/{account}/deal/{id}"}');
  perform cma.upsert_commerce_store(v_shop, 'fixture-nl', 'Fixture NL', 'NL', 'EUR', 'Europe/Amsterdam');

  perform set_config('app.user_id', v_ing::text, true);
  perform cma.ingest_upsert_pipelines(v_crm, '[
    {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
       {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false}, {"stageId": "s9", "label": "Lost", "order": 9, "isClosed": true}]},
    {"recordType": "ticket", "pipelineId": "support", "label": "Support", "stages": [{"stageId": "t1", "label": "New", "order": 1, "isClosed": false}]}]');
  perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Fixture NL line", "digits": "+31000000001"}]');
  perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg1", "name": "Fixture sale"}]');
  perform cma.ingest_upsert_forms(v_crm, '[{"formId": "f1", "name": "Fixture form NL"}]');

  perform set_config('app.user_id', v_admin::text, true);
  perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);
  perform cma.set_form(v_crm, 'f1', true, 'Fixture', 'NL', '{}');

  -- deals: two days back (09:00 Amsterdam is 07:00 UTC in October before the change, 08:00 after;
  -- the exact office minutes do not matter to the verifier), each with its own contact
  perform set_config('app.user_id', v_ing::text, true);
  perform cma.ingest_upsert_records(v_crm, (
    select jsonb_agg(jsonb_build_object('recordType', 'deal', 'sourceId', x.id, 'pipelineId', 'sales', 'stageId', x.stage,
                                        'ownerRef', x.owner, 'contactId', 'k' || x.id, 'market', x.market,
                                        'createdAt', to_char(x.at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'updatedAt', to_char(x.at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                         || case when x.stage = 's9' then jsonb_build_object('closedAt', to_char(x.at + interval '2 hours', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')) else '{}' end)
    from (values
      ('9100001', 's1', 'o-1', 'NL',    (d - 2)::timestamp + time '08:00'),
      ('9100002', 's1', 'o-9', 'NL',    (d - 2)::timestamp + time '09:00'),
      ('9100003', 's1', 'o-1', 'GB',    (d - 3)::timestamp + time '10:00'),
      ('9100004', 's1', null,  'NL',    (d - 2)::timestamp + time '11:00'),
      ('9100005', 's9', null,  'NL',    (d - 5)::timestamp + time '12:00'),
      ('9100006', 's1', 'o-9', 'Mars',  (d - 4)::timestamp + time '09:30')) x(id, stage, owner, market, at)));
  perform cma.ingest_upsert_records(v_crm, (
    select jsonb_build_array(jsonb_build_object('recordType', 'ticket', 'sourceId', '9200001', 'pipelineId', 'support', 'stageId', 't1', 'market', 'NL',
      'createdAt', to_char((d - 2)::timestamp + time '10:00', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'updatedAt', to_char((d - 2)::timestamp + time '10:00', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))));
  perform cma.ingest_upsert_calls(v_crm, (
    select jsonb_agg(jsonb_build_object('sourceId', c.id, 'occurredAt', to_char(c.at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'direction', 'outbound',
                                        'ownerRef', c.owner, 'updatedAt', to_char(c.at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))
    from (values ('8100001', 'o-1', (d - 2)::timestamp + time '08:07'),
                 ('8100002', 'o-9', (d - 2)::timestamp + time '10:30'),
                 ('8100003', 'o-1', (d - 3)::timestamp + time '13:00'),
                 ('8100006', 'o-9', (d - 4)::timestamp + time '09:40')) c(id, owner, at)));
  perform cma.ingest_upsert_associations(v_crm, (
    select jsonb_agg(jsonb_build_object('fromType', 'crm_call', 'fromId', a.call, 'toType', 'contact', 'toId', a.contact, 'removed', false,
                                        'changedAt', to_char((d - 1)::timestamp, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))
    from (values ('8100001', 'k9100001'), ('8100002', 'k9100002'), ('8100003', 'k9100003'), ('8100006', 'k9100006')) a(call, contact)));
  perform cma.ingest_upsert_telephony_calls(v_tel, (
    select jsonb_agg(jsonb_build_object('sourceId', t.id, 'direction', t.dir, 'startedAt', to_char(t.at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                                        'endedAt', to_char(t.at + interval '3 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'numberRef', 'n-nl',
                                        'versionAt', to_char(t.at + interval '3 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'tags', t.tags))
    from (values ('7100001', 'inbound',  (d - 2)::timestamp + time '09:00', '["tg1"]'::jsonb),
                 ('7100002', 'outbound', (d - 2)::timestamp + time '09:30', '[]'::jsonb)) t(id, dir, at, tags)));
  perform cma.ingest_upsert_commerce_customers(v_shop, (
    select jsonb_build_array(jsonb_build_object('sourceId', '6100001', 'createdAt', to_char((d - 2)::timestamp + time '12:00', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                                                'updatedAt', to_char((d - 2)::timestamp + time '12:00', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))));
  perform cma.ingest_upsert_commerce_orders(v_shop, (
    select jsonb_build_array(jsonb_build_object('sourceId', '5100001', 'customerId', '6100001', 'priorOrdersCount', 0, 'currency', 'EUR', 'totalAmount', '10.00',
                                                'createdAt', to_char((d - 2)::timestamp + time '12:05', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                                                'updatedAt', to_char((d - 2)::timestamp + time '12:05', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))));
  perform cma.ingest_upsert_form_submissions(v_crm, (
    select jsonb_agg(jsonb_build_object('sourceId', s.id, 'formId', 'f1', 'submittedAt', to_char(s.at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))
    from (values ('4100001', (d - 2)::timestamp + time '07:55'), ('4100002', (d - 3)::timestamp + time '09:55')) s(id, at)));

  -- ---- pulse4all-subscriptions, inbound (addition 0008i) ----------------------------------------
  if to_regclass('cma.telephony_missed_reason') is not null then
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_connection_settings(v_tel, '{"record_url_call": "https://example.com/fixture/{account}/call/{id}"}');
    perform cma.set_telephony_missed_reason(v_tel, x.code, x.label, x.sl, true)
    from (values ('out_of_opening_hours', 'Outside opening hours', false), ('short_abandoned', 'Hung up within 10 s', false),
                 ('abandoned_in_ivr', 'Hung up in the menu', true), ('no_available_agent', 'No agent available', true),
                 ('agents_did_not_answer', 'Agents did not answer', true), ('unknown', 'Unknown', true)) x(code, label, sl);
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'sourceId', c.id, 'direction', c.dir, 'startedAt', to_char(c.at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
               'answeredAt', to_char(c.at + make_interval(secs => c.answer), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
               'endedAt', case when c.ended then to_char(c.at + interval '2 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') end,
               'missedReason', c.reason, 'numberRef', 'n-nl', 'counterpartHash', c.hash,
               'versionAt', to_char(c.at + interval '2 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))))
      from (values
        -- answered after 12, 25 and 8 seconds
        ('7200001', 'inbound',  (now() - interval '2 days') at time zone 'UTC',               12,   true,  null,                    repeat('e1', 32)),
        ('7200002', 'inbound',  (now() - interval '2 days 10 minutes') at time zone 'UTC',    25,   true,  null,                    repeat('e2', 32)),
        ('7200003', 'inbound',  (now() - interval '1 day') at time zone 'UTC',                8,    true,  null,                    repeat('e3', 32)),
        -- caller a1 missed twice, then called back (an attempt that did not connect)
        ('7200011', 'inbound',  (now() - interval '1 day 2 hours') at time zone 'UTC',        null, true,  'no_available_agent',    repeat('a1', 32)),
        ('7200012', 'inbound',  (now() - interval '1 day 1 hour') at time zone 'UTC',         null, true,  'agents_did_not_answer', repeat('a1', 32)),
        ('7200013', 'outbound', (now() - interval '1 day') at time zone 'UTC',                null, true,  null,                    repeat('a1', 32)),
        -- caller a2 missed once, caller a3 missed twice: both listed
        ('7200021', 'inbound',  (now() - interval '2 hours') at time zone 'UTC',              null, true,  'abandoned_in_ivr',      repeat('a2', 32)),
        ('7200031', 'inbound',  (now() - interval '3 hours') at time zone 'UTC',              null, true,  'short_abandoned',       repeat('a3', 32)),
        ('7200032', 'inbound',  (now() - interval '1 hour') at time zone 'UTC',               null, true,  'no_available_agent',    repeat('a3', 32)),
        -- caller a4 missed five days ago: outside the lookback
        ('7200041', 'inbound',  (now() - interval '5 days') at time zone 'UTC',               null, true,  'no_available_agent',    repeat('a4', 32)),
        -- caller a5 outside opening hours, caller a6 with a code nobody saved
        ('7200051', 'inbound',  (now() - interval '14 hours') at time zone 'UTC',             null, true,  'out_of_opening_hours',  repeat('a5', 32)),
        ('7200061', 'inbound',  (now() - interval '50 minutes') at time zone 'UTC',           null, true,  'abandoned_in_classic',  repeat('a6', 32)),
        -- caller a9 missed a day ago, called back an hour later, missed again: listed, missed 1 time
        -- (the missed calls since the latest callback)
        ('7200091', 'inbound',  (now() - interval '26 hours') at time zone 'UTC',             null, true,  'no_available_agent',    repeat('a9', 32)),
        ('7200092', 'outbound', (now() - interval '25 hours') at time zone 'UTC',             7,    true,  null,                    repeat('a9', 32)),
        ('7200093', 'inbound',  (now() - interval '40 minutes') at time zone 'UTC',           null, true,  'agents_did_not_answer', repeat('a9', 32)),
        -- an anonymous caller (no hash): counted, never listed
        ('7200071', 'inbound',  (now() - interval '70 minutes') at time zone 'UTC',           null, true,  'no_available_agent',    null),
        -- waiting now: not answered, not ended
        ('7200081', 'inbound',  (now() - interval '2 minutes') at time zone 'UTC',            null, false, null,                    repeat('a8', 32))
      ) c(id, dir, at, answer, ended, reason, hash)));
  else
    raise notice 'addition 0008i is not there: the inbound part of the fixture is left out';
  end if;

  -- ---- pulse4all-subscriptions, calls (addition 0008j) ------------------------------------------
  if exists (select 1 from cma.setting where key = 'telephony.connected_min_seconds') then
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Fixture NL line", "digits": "+31000000001"},
      {"numberRef": "n-gb", "name": "Fixture GB line", "digits": "+44000000002"}, {"numberRef": "n-off", "name": "Fixture line not counted", "digits": "+31000000003"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg1", "name": "Fixture sale"}, {"tagRef": "tg2", "name": "Fixture info"},
      {"tagRef": "tg3", "name": "Fixture internal"}]');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_telephony_number(v_tel, 'n-gb', 'GB', true);
    perform cma.set_telephony_number(v_tel, 'n-off', 'NL', false);
    perform cma.set_telephony_tag(v_tel, 'tg3', false);
    perform cma.set_user_external_id(v_agent2, 'fixturetel_user', 'tu-1');
    perform cma.set_user_external_id((select id from cma.app_user where tenant_id = v_subs and email = 'supervisor@example.com'), 'fixturetel_user', 'tu-2');
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'sourceId', c.id, 'direction', c.dir, 'startedAt', to_char(c.at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
               'answeredAt', to_char(c.at + make_interval(secs => c.ring), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
               'endedAt', to_char(c.at + make_interval(secs => coalesce(c.ring, 0) + c.talk), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
               'numberRef', c.line, 'userRef', c.usr, 'tags', c.tags,
               'versionAt', to_char(c.at + make_interval(secs => coalesce(c.ring, 0) + c.talk), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))))
      from (values
        -- outbound on NL: connected (60 s after 9 s of ringing), not connected (5 s), at exactly 10 s, unanswered
        ('7300001', 'outbound', (now() - interval '3 days') at time zone 'UTC',             9,    60, 'n-nl', 'tu-1', '["tg1"]'::jsonb),
        ('7300002', 'outbound', (now() - interval '3 days 1 hour') at time zone 'UTC',      7,    5,  'n-nl', 'tu-1', '[]'::jsonb),
        ('7300003', 'outbound', (now() - interval '4 days') at time zone 'UTC',             12,   10, 'n-nl', 'tu-2', '["tg2"]'::jsonb),
        ('7300004', 'outbound', (now() - interval '4 days 2 hours') at time zone 'UTC',     null, 30, 'n-nl', 'tu-2', null),
        -- inbound on NL: an untagged conversation, one tagged only with the tag that does not count
        ('7300005', 'inbound',  (now() - interval '5 days') at time zone 'UTC',             6,    240, 'n-nl', 'tu-2', '[]'::jsonb),
        ('7300006', 'inbound',  (now() - interval '6 days') at time zone 'UTC',             4,    180, 'n-nl', 'tu-1', '["tg3"]'::jsonb),
        -- GB, a telephony user linked to nobody: an inbound and an outbound conversation
        ('7300007', 'inbound',  (now() - interval '2 days 3 hours') at time zone 'UTC',     5,    90,  'n-gb', 'tu-9', '["tg2"]'::jsonb),
        ('7300008', 'outbound', (now() - interval '2 days 4 hours') at time zone 'UTC',     6,    45,  'n-gb', 'tu-9', '["tg1", "tg3"]'::jsonb),
        -- the line that does not count: skipped by the write
        ('7300009', 'outbound', (now() - interval '2 days') at time zone 'UTC',             5,    120, 'n-off', 'tu-1', '["tg1"]'::jsonb),
        -- the previous period (the verifier reads the last 28 days)
        ('7300010', 'outbound', (now() - interval '35 days') at time zone 'UTC',            8,    30,  'n-nl', 'tu-1', '[]'::jsonb),
        ('7300011', 'inbound',  (now() - interval '40 days') at time zone 'UTC',            5,    60,  'n-gb', 'tu-2', '["tg2"]'::jsonb)
      ) c(id, dir, at, ring, talk, line, usr, tags)));
    -- a reports reader: reports.view without performance.team (mock identity reader)
    perform set_config('role', 'cma_owner', true);
    insert into cma.app_role (tenant_id, key, name) values (v_subs, 'reports_reader', 'Reports reader') on conflict (tenant_id, key) do nothing;
    insert into cma.role_permission (tenant_id, role_id, permission_key)
    select v_subs, ar.id, 'reports.view' from cma.app_role ar where ar.tenant_id = v_subs and ar.key = 'reports_reader' on conflict do nothing;
    with u as (insert into cma.app_user (tenant_id, email, display_name) values (v_subs, 'reader@example.com', 'Test reader') returning id)
    insert into cma.user_role (tenant_id, user_id, role_id) select v_subs, u.id, ar.id from u join cma.app_role ar on ar.tenant_id = v_subs and ar.key = 'reports_reader';
    insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
    select v_subs, id, 'mock', 'reader' from cma.app_user where tenant_id = v_subs and email = 'reader@example.com';
    perform set_config('role', 'cma_app', true);
  else
    raise notice 'addition 0008j is not there: the calls part of the fixture is left out';
  end if;

  -- ---- pulse4all-invest: a CRM only ------------------------------------------------------------
  perform set_config('app.tenant_id', v_inv::text, true);
  perform set_config('app.user_id', v_admin_inv::text, true);
  perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
  perform cma.set_tenant_setting('intake.start_date', (d - 60)::text);
  perform set_config('app.user_id', v_ing_inv::text, true);
  perform cma.ingest_upsert_pipelines(v_crm_inv, '[{"recordType": "deal", "pipelineId": "invest", "label": "Invest", "stages": [{"stageId": "i1", "label": "Open", "order": 1, "isClosed": false}]}]');
  perform cma.ingest_upsert_records(v_crm_inv, (
    select jsonb_agg(jsonb_build_object('recordType', 'deal', 'sourceId', x.id, 'pipelineId', 'invest', 'stageId', 'i1', 'market', 'NL',
                                        'createdAt', to_char(x.at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'updatedAt', to_char(x.at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))
    from (values ('9300001', (d - 2)::timestamp + time '10:00'), ('9300002', (d - 1)::timestamp + time '10:00')) x(id, at)));

  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  raise notice 'fixture written';
end
$$;
