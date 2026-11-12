-- =============================================================================================
-- verify/perf-volume-fixture.sql: a prod-scale volume for the speed work on a LOCAL database built from db/00 with the
-- dev seed (night N06, 5 November 2026): every busy table of the CMA at a multiple of prod's volume as of the morning of
-- 5 November 2026, so the time scripts (db/131_time_all.sql, db/124_time_flash.sql), verify/perf.mjs and
-- verify/round-trips.mjs measure the reads on something like prod, three times over; since addition 0009j also the
-- pledge lists (a block of its own at the end, once 168 has run); since addition 0009l the active customer base (a block
-- of its own after it, once 172 has run: the subscriptions linked to their store's customers over 60 months, segments,
-- a year of first orders with their deals, and most failed renewals closed, then the stored take of Customers → Active
-- refreshed once)
-- =============================================================================================
-- Never for dev or prod: it refuses to run unless the session sets the local switch first, refuses a database without
-- the dev seed, and refuses a Cloud SQL instance (the role cloudsqladmin exists there). Every id is invented (perf-…,
-- pd…, pt…, pk…, pc…, ps…, po-…), the hashes are sha256 of invented strings, no row carries a name, an address, an email
-- or a phone number: ids, codes, counts, amounts and times only. Rerunnable: a second run finds its CRM connection and
-- stops. The audit triggers of the loaded tables are disabled inside the block (as db/123's block C does) and enabled
-- again at its end, so the load takes minutes, not an hour of audit images.
--
--   psql -h 127.0.0.1 -d cma -v ON_ERROR_STOP=1 -c "set cma.local_fixture = 'on'" -c "set cma.perf_multiplier = '3'" -f verify/perf-volume-fixture.sql
--   (or put both  set  lines in the same session before \i; the multiplier defaults to 3)
--   The local database is created with Cloud SQL's collation (en_US.UTF8), not C: verify/README.md, A local database
--
-- The base figures (prod, 5 November 2026, from the brief; the census, db/130, gives the exact ones) and the generous
-- estimates where the brief has none, each times cma.perf_multiplier (3 by default; "× m" below):
--   connections       14 stores (commerce) with their commerce_store rows, 12 subscriptions connections mapped to a
--                     store by its handle, 1 CRM, 1 telephony, 1 asset register, 1 reviews platform: 30 (prod has 19
--                     today; a connection costs nothing, the rows do)
--   ingest_event      360,000 × m over the last 30 days: the CRM's share 76 % (about 13,000 a day), the stores' 18 %
--                     (3,000 a day), telephony's 6 % (1,100 a day); 97 % processed, 1 % ignored, 1 % received (the newest
--                     hours), 0.5 % failed, 0.5 % needs_review
--   sync_run          120,000 × m over the last 30 days: the CRM's forms and email polls every minute and its nightly
--                     reconcile (about 4,300 a day), the subscriptions poll every 5 minutes per store (288 a day each),
--                     the reviews poll hourly, the asset poll every 5 minutes, the reconciles nightly; 1 % failed
--   subscription      7,380 × m across the 12 stores, 70 % active; subscription_event 100,000 × m over the last 365 days
--   device            6,800 × m with two components each (the seed's models, statuses and component kinds)
--   crm_record        deals 3,500 × m (700 × m open, in the lead pipeline; the rest closed over 90 days), tickets 3,600 × m
--                     (1,200 × m open) in two pipelines; crm_task 7,500 × m (2,500 × m open, due within ±30 days)
--   crm_contact       20,000 × m (a country each, a quarter with a store reference); crm_association contact ↔ deal
--   commerce_customer 40,000 × m across the stores, a third linked to a contact; commerce_order 20,000 × m over 60 days
--                     with 1.5 lines each
--   telephony_call    66,000 × m over 60 days (1,100 a day), two thirds linked to a crm_call; crm_call 50,000 × m, each
--                     associated with a contact; a tag on a tenth
--   review            5,000 × m over 60 days on 14 channels
--   message           300 × m to each person of the seed with a delivery row (the inbox and its unread count at volume)
-- Owners: perfcrm_owner po-1 to po-6 are linked to six people of the seed, po-7 and po-8 to nobody; telephony users
-- perftel_user pu-1 to pu-6 alike. Markets: the 14 of the stores with office hours Monday to Friday 09:00-17:00 when the
-- tenant has none; intake.start_date 60 days back (as verify/follow-up-volume-fixture.sql).
set role cma_owner;
do $$
begin
  if coalesce(current_setting('cma.local_fixture', true), '') <> 'on' then
    raise exception 'local fixture only: run  set cma.local_fixture = ''on''  in this session first';
  end if;
  if exists (select 1 from pg_roles where rolname = 'cloudsqladmin') then
    raise exception 'this is a Cloud SQL instance (the role cloudsqladmin exists): the volume fixture is for a local database only';
  end if;
  if not exists (select 1 from cma.app_user where email = 'agent.two@example.com') then
    raise exception 'the dev seed is missing: this fixture needs db/03 and db/06';
  end if;
end
$$;

do $$
declare
  m numeric := coalesce(nullif(current_setting('cma.perf_multiplier', true), ''), '3')::numeric;
  v_subs uuid; v_admin uuid; v_ing uuid; v_crm uuid; v_tel uuid; v_reg uuid; v_rev uuid;
  v_shops uuid[] := '{}'; v_subc uuid[] := '{}'; v_chan uuid[] := '{}';
  v_codes text[] := array['AT', 'BE', 'CH', 'DE', 'DK', 'ES', 'FI', 'FR', 'GB', 'IE', 'IT', 'NL', 'NO', 'SE'];
  v_zones text[] := array['Europe/Vienna', 'Europe/Brussels', 'Europe/Zurich', 'Europe/Berlin', 'Europe/Copenhagen', 'Europe/Madrid', 'Europe/Helsinki',
                          'Europe/Paris', 'Europe/London', 'Europe/Dublin', 'Europe/Rome', 'Europe/Amsterdam', 'Europe/Oslo', 'Europe/Stockholm'];
  v_langs text[] := array['de', 'nl', 'de', 'de', 'da', 'es', 'fi', 'fr', 'en', 'en', 'it', 'nl', 'no', 'sv'];
  v_curr text[] := array['EUR', 'EUR', 'CHF', 'EUR', 'DKK', 'EUR', 'EUR', 'EUR', 'GBP', 'EUR', 'EUR', 'EUR', 'NOK', 'SEK'];
  v_people text[] := array['agent.two@example.com', 'agent.one@example.com', 'supervisor@example.com', 'manager@example.com',
                           'admin@example.com', 'analyst@example.com'];
  d date := current_date;
  t0 timestamptz := clock_timestamp();
  i integer; c uuid;
  n_ev integer := (360000 * m)::integer; n_run integer := (120000 * m)::integer; n_sub integer := (7380 * m)::integer;
  n_sev integer := (100000 * m)::integer; n_dev integer := (6800 * m)::integer; n_deal integer := (3500 * m)::integer;
  n_open_deal integer := (700 * m)::integer; n_tick integer := (3600 * m)::integer; n_open_tick integer := (1200 * m)::integer;
  n_task integer := (7500 * m)::integer; n_open_task integer := (2500 * m)::integer; n_con integer := (20000 * m)::integer;
  n_cust integer := (40000 * m)::integer; n_ord integer := (20000 * m)::integer; n_tc integer := (66000 * m)::integer;
  n_cc integer := (50000 * m)::integer; n_rev integer := (5000 * m)::integer; n_msg integer := (300 * m)::integer;
begin
  select id into v_subs from cma.tenant where slug = 'pulse4all-subscriptions';
  if exists (select 1 from cma.integration_connection where tenant_id = v_subs and adapter = 'perfcrm') then
    raise notice 'perf volume fixture already present';
    return;
  end if;
  select id into v_admin from cma.app_user where tenant_id = v_subs and email = 'admin@example.com';
  select id into v_ing from cma.app_user where tenant_id = v_subs and email = 'ingest@system.invalid';
  raise notice 'perf volume fixture: multiplier %', m;

  -- ---- configuration, through the functions, as the admin ------------------------------------------------
  perform set_config('role', 'cma_app', true);
  perform set_config('app.tenant_id', v_subs::text, true);
  perform set_config('app.user_id', v_admin::text, true);
  for i in 1 .. 14 loop
    if not exists (select 1 from cma.market x where x.tenant_id = v_subs and x.code = v_codes[i]) then
      perform cma.upsert_market(v_codes[i], v_codes[i], v_zones[i], v_langs[i], v_curr[i]);
    end if;
  end loop;
  if not exists (select 1 from cma.business_hours h where h.tenant_id = v_subs) then
    perform cma.set_business_hours('*', w::smallint, '09:00-17:00') from generate_series(1, 5) w;
  end if;
  perform cma.set_tenant_setting('intake.start_date', (d - 60)::text);
  for i in 1 .. array_length(v_people, 1) loop
    perform cma.set_user_external_id(u.id, 'perfcrm_owner', 'po-' || i) from cma.app_user u where u.tenant_id = v_subs and u.email = v_people[i];
    perform cma.set_user_external_id(u.id, 'perftel_user', 'pu-' || i) from cma.app_user u where u.tenant_id = v_subs and u.email = v_people[i];
  end loop;
  perform set_config('role', 'cma_owner', true);

  -- ---- the connections and the catalogs, as the owner (a local fixture) -----------------------------------
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_subs, 'perfcrm', 'Perf CRM', 'perf-portal', 'crm') returning id into v_crm;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_subs, 'perftel', 'Perf Phone', 'perf-phone', 'telephony') returning id into v_tel;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_subs, 'perfreg', 'Perf Register', 'perf-base', 'assets') returning id into v_reg;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_subs, 'perfrev', 'Perf Reviews', 'perf-rev', 'reviews') returning id into v_rev;
  for i in 1 .. 14 loop
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_subs, 'perfshop', 'Perf Shop ' || v_codes[i], 'perf-' || lower(v_codes[i]) || '.shop.example', 'commerce') returning id into c;
    v_shops := v_shops || c;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
    values (v_subs, c, 'perf-' || lower(v_codes[i]), 'Perf ' || v_codes[i], v_codes[i], v_curr[i], v_zones[i]);
    if i <= 12 then
      insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
      values (v_subs, 'perfsubs', 'Perf Subs ' || v_codes[i], 'perf-' || lower(v_codes[i]) || '.shop.example', 'subscriptions') returning id into c;
      v_subc := v_subc || c;
    end if;
    insert into cma.review_channel (tenant_id, connection_id, source_id, name, market, is_counted)
    values (v_subs, v_rev, 'perf-ch-' || lower(v_codes[i]), 'Perf channel ' || v_codes[i], v_codes[i], true) returning id into c;
    v_chan := v_chan || c;
  end loop;
  insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted, is_lead) values
    (v_subs, v_crm, 'deal', 'perf-sales', 'Perf sales', true, true), (v_subs, v_crm, 'deal', 'perf-renewal', 'Perf renewals', true, false),
    (v_subs, v_crm, 'ticket', 'perf-support', 'Perf support', true, true), (v_subs, v_crm, 'ticket', 'perf-billing', 'Perf billing', true, true);
  insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, display_order, is_closed) values
    (v_subs, v_crm, 'deal', 'perf-sales', 'ps1', 'New', 1, false), (v_subs, v_crm, 'deal', 'perf-sales', 'ps2', 'Contacted', 2, false),
    (v_subs, v_crm, 'deal', 'perf-sales', 'ps8', 'Won', 8, true), (v_subs, v_crm, 'deal', 'perf-sales', 'ps9', 'Lost', 9, true),
    (v_subs, v_crm, 'deal', 'perf-renewal', 'pr1', 'Due', 1, false), (v_subs, v_crm, 'deal', 'perf-renewal', 'pr9', 'Renewed', 9, true),
    (v_subs, v_crm, 'ticket', 'perf-support', 'pt1', 'New', 1, false), (v_subs, v_crm, 'ticket', 'perf-support', 'pt2', 'Waiting', 2, false),
    (v_subs, v_crm, 'ticket', 'perf-support', 'pt9', 'Closed', 9, true),
    (v_subs, v_crm, 'ticket', 'perf-billing', 'pb1', 'New', 1, false), (v_subs, v_crm, 'ticket', 'perf-billing', 'pb9', 'Closed', 9, true);
  insert into cma.connection_task_status (tenant_id, connection_id, status_ref, label, is_done) values
    (v_subs, v_crm, 'NOT_STARTED', 'Not started', false), (v_subs, v_crm, 'IN_PROGRESS', 'In progress', false), (v_subs, v_crm, 'COMPLETED', 'Completed', true);
  insert into cma.connection_task_type (tenant_id, connection_id, type_ref, label, is_callback, is_counted) values
    (v_subs, v_crm, 'CALL', 'Call', true, true), (v_subs, v_crm, 'EMAIL', 'Email', false, true), (v_subs, v_crm, 'TODO', 'To do', false, true);
  insert into cma.connection_call_outcome (tenant_id, connection_id, outcome_ref, label, is_connected) values
    (v_subs, v_crm, 'CONNECTED', 'Connected', true), (v_subs, v_crm, 'NO_ANSWER', 'No answer', false), (v_subs, v_crm, 'BUSY', 'Busy', false);
  insert into cma.telephony_tag (tenant_id, connection_id, tag_ref, name, is_counted) values
    (v_subs, v_tel, 'sales', 'Sales', true), (v_subs, v_tel, 'support', 'Support', true), (v_subs, v_tel, 'callback', 'Callback', true);
  insert into cma.telephony_number (tenant_id, connection_id, number_ref, name, market, is_counted)
  select v_subs, v_tel, 'perf-line-' || lower(v_codes[n]), 'Perf line ' || v_codes[n], v_codes[n], true from generate_series(1, 14) n;
  perform set_config('role', 'cma_app', true);
  perform cma.set_connection_settings(v_crm, '{"record_url_deal": "https://example.com/perf/{account}/deal/{id}", "record_url_ticket": "https://example.com/perf/{account}/ticket/{id}", "record_url_task": "https://example.com/perf/{account}/task/{id}"}');
  perform set_config('role', 'cma_owner', true);

  -- ---- the rows, written as the owner, the audit triggers off for the load ---------------------------------
  perform set_config('lock_timeout', '10s', true);
  alter table cma.ingest_event disable trigger audit;
  alter table cma.sync_run disable trigger audit;
  alter table cma.subscription disable trigger audit;
  alter table cma.subscription_event disable trigger audit;
  alter table cma.device disable trigger audit;
  alter table cma.device_component disable trigger audit;
  alter table cma.crm_record disable trigger audit;
  alter table cma.crm_task disable trigger audit;
  alter table cma.crm_contact disable trigger audit;
  alter table cma.crm_contact_ref disable trigger audit;
  alter table cma.crm_association disable trigger audit;
  alter table cma.crm_call disable trigger audit;
  alter table cma.commerce_customer disable trigger audit;
  alter table cma.commerce_order disable trigger audit;
  alter table cma.commerce_order_line disable trigger audit;
  alter table cma.telephony_call disable trigger audit;
  alter table cma.telephony_call_tag disable trigger audit;
  alter table cma.call_link disable trigger audit;
  alter table cma.review disable trigger audit;
  alter table cma.message disable trigger audit;
  alter table cma.message_delivery disable trigger audit;
  perform set_config('lock_timeout', '0', true);

  -- contacts: a country each (two of a hundred a code that is no market), a quarter with a store reference
  insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, language, source_created_at, source_updated_at)
  select v_subs, v_crm, 'perfcrm', 'pc' || g, case when g % 100 = 0 then 'XX' else v_codes[1 + g % 14] end, v_langs[1 + g % 14],
         now() - make_interval(days => g % 700), now() - make_interval(days => g % 30)
  from generate_series(1, n_con) g;
  analyze cma.crm_contact;
  insert into cma.crm_contact_ref (tenant_id, contact_id, system, slot, external_id)
  select v_subs, k.id, 'perfshop', 1, 'pcu' || substr(k.source_id, 3) from cma.crm_contact k where k.tenant_id = v_subs and k.connection_id = v_crm and (substr(k.source_id, 3)::integer % 4) = 0;
  analyze cma.crm_contact_ref;

  -- store customers across the 14 stores, a third linked to a contact (the matched ones), orders over 60 days
  insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, state, orders_count, amount_spent, amount_currency,
                                     source_created_at, crm_connection_id, crm_contact_source_id, matched_at)
  select v_subs, v_shops[1 + g % 14], 'perfshop', 'pcu' || g, 'enabled', g % 5, (g % 400) + 0.5, v_curr[1 + g % 14],
         now() - make_interval(days => g % 900),
         case when g % 3 = 0 then v_crm end, case when g % 3 = 0 then 'pc' || (1 + g % n_con) end, case when g % 3 = 0 then now() end
  from generate_series(1, n_cust) g;
  analyze cma.commerce_customer;
  insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, order_name, customer_source_id, source_created_at, processed_at,
                                  is_test, currency, total_amount, refunded_amount, financial_status, fulfillment_status, order_kind)
  select v_subs, v_shops[1 + g % 14], 'perfshop', 'pord' || g, '#P' || g, 'pcu' || (1 + g % n_cust),
         now() - make_interval(mins => (g * 433) % (60 * 1440)), now() - make_interval(mins => (g * 433) % (60 * 1440)),
         g % 500 = 0, v_curr[1 + g % 14], 20 + g % 80, case when g % 50 = 0 then 5 end,
         (array['paid', 'paid', 'paid', 'pending', 'refunded'])[1 + g % 5], 'fulfilled', (array['first', 'repeat', 'renewal'])[1 + g % 3]
  from generate_series(1, n_ord) g;
  analyze cma.commerce_order;
  insert into cma.commerce_order_line (tenant_id, connection_id, order_source_id, line_source_id, sku, quantity, unit_price, currency)
  select co.tenant_id, co.connection_id, co.source_id, 'pl-' || k || '-' || co.source_id, 'SKU-' || ((hashtext(co.source_id) & 7) + k), k, 10, co.currency
  from cma.commerce_order co cross join generate_series(1, 2) k
  where co.tenant_id = v_subs and co.source_system = 'perfshop' and (k = 1 or (hashtext(co.source_id) & 1) = 0);
  analyze cma.commerce_order_line;

  -- subscriptions across the 12 stores with Juo, 70 % active; events over the last 365 days
  insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, current_cycle, next_billing_at,
                                billing_interval, billing_interval_count, amount_per_cycle, currency, source_created_at, paused_at, canceled_at)
  select v_subs, v_subc[1 + g % 12], 'perfsubs', 'psub' || g, 'pcu' || (1 + g % n_cust),
         (array['active', 'active', 'active', 'active', 'active', 'active', 'active', 'paused', 'canceled', 'expired'])[1 + g % 10], g % 24,
         case when g % 10 < 7 then now() + make_interval(days => g % 30) end, 'month', 1, 10 + g % 30, v_curr[1 + g % 12],
         now() - make_interval(days => 30 + g % 700), case when g % 10 = 7 then now() - make_interval(days => g % 60) end,
         case when g % 10 = 8 then now() - make_interval(days => g % 300) end
  from generate_series(1, n_sub) g;
  analyze cma.subscription;
  insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, cycle_index,
                                      status_from, status_to, reason_code)
  select v_subs, v_subc[1 + s % 12], 'perfsubs', 'pse' || g, 'psub' || s,
         case g % 20 when 0 then 'renew_failed' when 1 then 'canceled' when 2 then 'status_changed' when 3 then 'paused' when 4 then 'resumed' else 'renewed' end,
         now() - make_interval(mins => ((g::bigint * 7919) % (365 * 1440))::integer), g % 24,
         case when g % 20 = 2 then 'active' end, case when g % 20 = 2 then 'canceled' when g % 20 = 1 then 'canceled' end,
         case when g % 20 = 1 then 'too-expensive' end
  from generate_series(1, n_sev) g cross join lateral (select 1 + g % n_sub as s) x;
  analyze cma.subscription_event;

  -- the asset register: devices with two components, in the field with a subscription reference or in storage
  insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, warehouse_ref, customer_ref,
                          subscription_ref, order_ref, first_shipped_on, warranty_until, external_refs)
  select v_subs, v_reg, 'perfreg', 'prec' || g, case when g % 200 = 0 then null else 'PSN-' || g end, case when g % 3 = 0 then 'frx' else 'hs1' end,
         v_codes[1 + g % 14], case when g % 5 = 0 then 'in_storage' else 'active_customer' end, 'WH-' || (g % 4), 'pcu' || (1 + g % n_cust),
         case when g % 5 <> 0 then 'psub' || (1 + g % n_sub) end, 'pord' || (1 + g % n_ord), date '2023-01-01' + (g % 1000), date '2025-01-01' + (g % 1500),
         jsonb_build_object('ns_internal_id', (100000 + g)::text)
  from generate_series(1, n_dev) g;
  analyze cma.device;
  insert into cma.device_component (tenant_id, device_id, component_key, serial, expires_on)
  select dv.tenant_id, dv.id, k.key, k.key || '-' || dv.source_id, case when (hashtext(dv.source_id || k.key) % 3) <> 0 then date '2026-06-01' + (abs(hashtext(dv.source_id || k.key)) % 1400) end
  from cma.device dv cross join (values ('pads'), ('battery')) k(key) where dv.tenant_id = v_subs and dv.source_system = 'perfreg';
  analyze cma.device_component;

  -- deals: the open ones in the lead pipeline over the last 30 days, the closed ones over 90 days (a tenth renewals)
  insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref, contact_source_id, market,
                              is_closed, closed_at, source_created_at, source_updated_at, amount, currency)
  select v_subs, v_crm, 'perfcrm', 'deal', 'pd' || g,
         case when g % 10 = 0 then 'perf-renewal' else 'perf-sales' end,
         case when g <= n_open_deal then case when g % 10 = 0 then 'pr1' when g % 2 = 0 then 'ps1' else 'ps2' end
              else case when g % 10 = 0 then 'pr9' when g % 3 = 0 then 'ps9' else 'ps8' end end,
         case when g % 9 = 0 then null else 'po-' || (1 + g % 8) end, 'pc' || (1 + g % n_con),
         case when g % 25 = 0 then null else v_codes[1 + g % 14] end,
         g > n_open_deal, case when g > n_open_deal then now() - make_interval(hours => (g * 37) % (89 * 24)) end,
         case when g <= n_open_deal then now() - make_interval(mins => (g * 271) % (30 * 1440)) else now() - make_interval(hours => (g * 37) % (89 * 24)) - interval '2 days' end,
         now() - make_interval(hours => g % 48), 100 + g % 900, 'EUR'
  from generate_series(1, n_deal) g;
  -- tickets: the open ones over the last 14 days, the closed ones over 60
  insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref, contact_source_id, market,
                              is_closed, closed_at, source_created_at, source_updated_at)
  select v_subs, v_crm, 'perfcrm', 'ticket', 'pt' || g, case when g % 3 = 0 then 'perf-billing' else 'perf-support' end,
         case when g <= n_open_tick then case when g % 3 = 0 then 'pb1' when g % 2 = 0 then 'pt2' else 'pt1' end else case when g % 3 = 0 then 'pb9' else 'pt9' end end,
         case when g % 9 = 0 then null else 'po-' || (1 + g % 8) end, 'pc' || (1 + g % n_con),
         case when g % 25 = 0 then null else v_codes[1 + g % 14] end,
         g > n_open_tick, case when g > n_open_tick then now() - make_interval(hours => (g * 53) % (59 * 24)) end,
         case when g <= n_open_tick then now() - make_interval(mins => (g * 113) % (14 * 1440)) else now() - make_interval(hours => (g * 53) % (59 * 24)) - interval '1 day' end,
         now() - make_interval(hours => g % 48)
  from generate_series(1, n_tick) g;
  analyze cma.crm_record;
  -- contact ↔ deal associations (every deal), one more contact on every fifth deal
  insert into cma.crm_association (tenant_id, connection_id, from_type, from_id, to_type, to_id, source_changed_at)
  select v_subs, v_crm, 'deal', r.source_id, 'contact', r.contact_source_id, r.source_created_at
  from cma.crm_record r where r.tenant_id = v_subs and r.connection_id = v_crm and r.record_type = 'deal'
  union all
  select v_subs, v_crm, 'deal', r.source_id, 'contact', 'pc' || (1 + (substr(r.source_id, 3)::integer * 7) % n_con), r.source_created_at
  from cma.crm_record r where r.tenant_id = v_subs and r.connection_id = v_crm and r.record_type = 'deal' and substr(r.source_id, 3)::integer % 5 = 0
    and 'pc' || (1 + (substr(r.source_id, 3)::integer * 7) % n_con) <> r.contact_source_id;
  -- tasks: open ones due within ±30 days (every tenth without a due time), done ones over 60 days; on a deal or a ticket
  insert into cma.crm_task (tenant_id, connection_id, source_system, source_id, owner_ref, status_ref, type_ref, priority_ref, due_at, completed_at,
                            deal_source_id, ticket_source_id, contact_source_id, source_created_at, source_updated_at)
  select v_subs, v_crm, 'perfcrm', 'pk' || g,
         case when g % 9 = 0 then null else 'po-' || (1 + g % 8) end,
         case when g <= n_open_task then (array['NOT_STARTED', 'IN_PROGRESS'])[1 + g % 2] else 'COMPLETED' end,
         (array['CALL', 'EMAIL', 'TODO'])[1 + g % 3], (array['HIGH', 'MEDIUM', 'LOW', null])[1 + g % 4],
         case when g % 10 = 0 then null when g <= n_open_task then now() + make_interval(mins => (g * 433) % (60 * 1440) - 30 * 1440)
              else now() - make_interval(hours => (g * 11) % (60 * 24)) end,
         case when g > n_open_task then now() - make_interval(hours => (g * 11) % (60 * 24)) end,
         case when g % 2 = 0 then 'pd' || (1 + g % n_deal) end, case when g % 2 = 1 then 'pt' || (1 + g % n_tick) end,
         'pc' || (1 + g % n_con), now() - make_interval(days => 1 + g % 40), now() - make_interval(days => g % 40)
  from generate_series(1, n_task) g;
  analyze cma.crm_task, cma.crm_association;

  -- telephony calls over 60 days on the 14 lines, 60 % outbound, 70 % answered; a user on nine of ten
  insert into cma.telephony_call (tenant_id, connection_id, source_system, source_id, direction, status, missed_reason, started_at, answered_at, ended_at,
                                  duration_seconds, user_ref, number_ref, counterpart_hash, source_version_at)
  select v_subs, v_tel, 'perftel', 'ptc' || g, case when g % 5 < 3 then 'outbound' else 'inbound' end,
         case when g % 10 < 7 then 'done' else 'missed' end, case when g % 10 >= 7 then (array['no_answer', 'abandoned', 'closed'])[1 + g % 3] end,
         now() - make_interval(mins => (g * 1301) % (60 * 1440)),
         case when g % 10 < 7 then now() - make_interval(mins => (g * 1301) % (60 * 1440)) + interval '20 seconds' end,
         now() - make_interval(mins => (g * 1301) % (60 * 1440)) + make_interval(secs => 20 + g % 400),
         20 + g % 400, case when g % 10 = 9 then null else 'pu-' || (1 + g % 7) end, 'perf-line-' || lower(v_codes[1 + g % 14]),
         encode(sha256(('perf-caller-' || (g % 20000))::bytea), 'hex'), now() - make_interval(mins => (g * 1301) % (60 * 1440))
  from generate_series(1, n_tc) g;
  analyze cma.telephony_call;
  insert into cma.telephony_call_tag (tenant_id, connection_id, call_source_id, tag_ref, tagged_at)
  select v_subs, v_tel, 'ptc' || g, (array['sales', 'support', 'callback'])[1 + g % 3], now() - make_interval(mins => (g * 1301) % (60 * 1440)) + interval '10 minutes'
  from generate_series(10, n_tc, 10) g;
  -- CRM calls, each associated with a contact (and the open deals' contacts get calls after the deal), two thirds linked
  insert into cma.crm_call (tenant_id, connection_id, source_system, source_id, occurred_at, direction, status, outcome_ref, duration_seconds, owner_ref,
                            counterpart_hash, source_created_at)
  select v_subs, v_crm, 'perfcrm', 'pcc' || g, now() - make_interval(mins => (g * 1301) % (60 * 1440)) + interval '1 minute',
         case when g % 5 < 3 then 'outbound' else 'inbound' end, 'COMPLETED', (array['CONNECTED', 'NO_ANSWER', 'BUSY'])[1 + g % 3], 20 + g % 400,
         case when g % 9 = 0 then null else 'po-' || (1 + g % 8) end, encode(sha256(('perf-caller-' || (g % 20000))::bytea), 'hex'),
         now() - make_interval(mins => (g * 1301) % (60 * 1440))
  from generate_series(1, n_cc) g;
  analyze cma.crm_call;
  insert into cma.crm_association (tenant_id, connection_id, from_type, from_id, to_type, to_id, source_changed_at)
  select v_subs, v_crm, 'crm_call', 'pcc' || g, 'contact', 'pc' || (1 + g % n_con), now() - make_interval(mins => (g * 1301) % (60 * 1440))
  from generate_series(1, n_cc) g;
  insert into cma.call_link (tenant_id, telephony_call_id, crm_call_id, method, delta_seconds, linked_by)
  select v_subs, tc.id, cc.id, 'hash_time', 60, null
  from cma.telephony_call tc
  join cma.crm_call cc on cc.tenant_id = tc.tenant_id and cc.connection_id = v_crm and cc.source_id = 'pcc' || substr(tc.source_id, 4)
  where tc.tenant_id = v_subs and tc.connection_id = v_tel and substr(tc.source_id, 4)::integer % 3 <> 0;
  analyze cma.crm_association, cma.call_link, cma.telephony_call_tag;

  -- reviews over 60 days on the 14 channels
  insert into cma.review (tenant_id, connection_id, review_channel_id, source_system, source_id, review_type, state, is_published, rating, submitted_at, link_level)
  select v_subs, v_rev, v_chan[1 + g % 14], 'perfrev', 'prv' || g, 'SERVICE_REVIEW', 'APPROVED', true, 1 + g % 5,
         now() - make_interval(mins => (g * 17) % (60 * 1440)), 'none'
  from generate_series(1, n_rev) g;
  analyze cma.review;

  -- the ingest's events over 30 days: the CRM's 76 %, the stores' 18 %, telephony's 6 %; the statuses as the header says
  insert into cma.ingest_event (tenant_id, connection_id, event_key, source_type, kind, object_type, object_id, occurred_at, recorded_at, status, attempts,
                                next_attempt_at, processed_at, error)
  select v_subs,
         case when g % 100 < 76 then v_crm when g % 100 < 94 then v_shops[1 + g % 14] else v_tel end,
         'perf-' || g, (array['deal.propertyChange', 'contact.propertyChange', 'orders/updated', 'call.ended'])[1 + g % 4],
         (array['changed', 'changed', 'changed', 'created'])[1 + g % 4], (array['deal', 'contact', 'order', 'call'])[1 + g % 4], 'pobj' || (g % 50000),
         now() - make_interval(secs => (g * 7)::bigint % (30 * 86400)), now() - make_interval(secs => (g * 7)::bigint % (30 * 86400)),
         case g % 200 when 0 then 'failed' when 1 then 'needs_review' when 2 then 'ignored' when 3 then 'ignored'
              else case when (g * 7) % (30 * 86400) < 600 then 'received' else 'processed' end end,
         case g % 200 when 0 then 3 else 1 end,
         now() - make_interval(secs => (g * 7)::bigint % (30 * 86400)),
         case when g % 200 in (0, 1) or (g * 7) % (30 * 86400) < 600 then null else now() - make_interval(secs => (g * 7)::bigint % (30 * 86400)) + interval '2 seconds' end,
         case g % 200 when 0 then 'http_503' when 1 then 'unknown_pipeline' end
  from generate_series(1, n_ev) g;
  analyze cma.ingest_event;

  -- the runs over 30 days: the CRM's polls every minute (two of three), the stores' subscriptions polls, the rest hourly or nightly
  insert into cma.sync_run (tenant_id, connection_id, job, stream, started_at, finished_at, status, counts, error)
  select v_subs,
         case when g % 10 < 7 then v_crm when g % 10 < 9 then v_subc[1 + g % 12] when g % 10 = 9 and g % 20 = 9 then v_rev else v_reg end,
         case when g % 10 < 7 then case g % 70 when 0 then 'reconcile' when 1 then 'reconcile' else case when g % 2 = 0 then 'forms_poll' else 'email_poll' end end
              when g % 10 < 9 then case when g % 1000 = 8 then 'reconcile' else 'subscriptions_poll' end
              when g % 20 = 9 then 'reviews_poll' else 'assets_poll' end,
         case when g % 10 < 7 then case when g % 2 = 0 then 'forms' else 'email' end when g % 10 < 9 then 'subscriptions' when g % 20 = 9 then 'reviews' else 'devices' end,
         now() - make_interval(secs => (g * 21)::bigint % (30 * 86400)),
         case when g = n_run then null else now() - make_interval(secs => (g * 21)::bigint % (30 * 86400)) + make_interval(secs => 1 + g % 40) end,
         case when g = n_run then 'running' when g % 100 = 0 then 'failed' else 'succeeded' end,
         jsonb_build_object('read', g % 50, 'written', g % 10), case when g % 100 = 0 and g <> n_run then (array['rate_limited', 'http_503'])[1 + g % 2] end
  from generate_series(1, n_run) g;
  analyze cma.sync_run;

  -- messages to every person of the seed, delivered, a tenth unread
  insert into cma.message (tenant_id, kind, urgency, title, body, target, created_at)
  select v_subs, case when g % 5 = 0 then 'alert' else 'announcement' end, 'normal', 'Perf message ' || g, 'A message of the volume fixture', '{"all": true}'::jsonb,
         now() - make_interval(mins => g * 17)
  from generate_series(1, n_msg) g;
  insert into cma.message_delivery (tenant_id, message_id, user_id, created_at, delivered_at, read_at)
  select m.tenant_id, m.id, u.id, m.created_at, m.created_at + interval '1 minute',
         case when (substr(m.title, 14)::integer % 10) = 0 then null else m.created_at + interval '5 minutes' end
  from cma.message m cross join cma.app_user u
  where m.tenant_id = v_subs and m.title like 'Perf message %' and u.tenant_id = v_subs and u.kind = 'person' and u.email like '%@example.com';
  analyze cma.message, cma.message_delivery;

  alter table cma.ingest_event enable trigger audit;
  alter table cma.sync_run enable trigger audit;
  alter table cma.subscription enable trigger audit;
  alter table cma.subscription_event enable trigger audit;
  alter table cma.device enable trigger audit;
  alter table cma.device_component enable trigger audit;
  alter table cma.crm_record enable trigger audit;
  alter table cma.crm_task enable trigger audit;
  alter table cma.crm_contact enable trigger audit;
  alter table cma.crm_contact_ref enable trigger audit;
  alter table cma.crm_association enable trigger audit;
  alter table cma.crm_call enable trigger audit;
  alter table cma.commerce_customer enable trigger audit;
  alter table cma.commerce_order enable trigger audit;
  alter table cma.commerce_order_line enable trigger audit;
  alter table cma.telephony_call enable trigger audit;
  alter table cma.telephony_call_tag enable trigger audit;
  alter table cma.call_link enable trigger audit;
  alter table cma.review enable trigger audit;
  alter table cma.message enable trigger audit;
  alter table cma.message_delivery enable trigger audit;
  raise notice 'perf volume fixture written in % s: % events, % runs, % subscriptions, % subscription events, % devices, % deals, % tickets, % tasks, % contacts, % customers, % orders, % telephony calls, % crm calls, % reviews',
    round(extract(epoch from clock_timestamp() - t0)), n_ev, n_run, n_sub, n_sev, n_dev, n_deal, n_tick, n_task, n_con, n_cust, n_ord, n_tc, n_cc, n_rev;
end
$$;
reset role;

-- Addition 0009j: Assets → Pledge lists at volume, so 131's pledge rows, perf.mjs and round-trips.mjs measure something.
-- Two thirds of the fixture's devices pledged: loan 2 (active, layout 1), loan 3 (inactive: its devices left out) and the
-- unknown reference 99; a language label in raw on every pledged device, its code through one alias but on a tenth; the
-- pledge values of the seed's two models; one quarter file of the current quarter (taken as the scheduler). Lender labels
-- are fake (Lender A, Lender B). Rerunnable: a second run finds loan 2 and stops. Runs only once 168 has run.
set role cma_owner;
do $$
declare
  v_subs uuid; v_sched uuid; t0 timestamptz := clock_timestamp(); n bigint;
begin
  if coalesce(current_setting('cma.local_fixture', true), '') <> 'on' then
    raise exception 'local fixture only: run  set cma.local_fixture = ''on''  in this session first';
  end if;
  if to_regclass('cma.pledge_loan') is null then
    raise notice 'pledge lists not present (168 not run): no pledges written';
    return;
  end if;
  select id into v_subs from cma.tenant where slug = 'pulse4all-subscriptions';
  if exists (select 1 from cma.pledge_loan where tenant_id = v_subs and key = '2' and lender_label = 'Lender A'
             and exists (select 1 from cma.device d where d.tenant_id = v_subs and d.source_system = 'perfreg' and d.pledge_ref is not null)) then
    raise notice 'perf pledges already present';
    return;
  end if;
  insert into cma.pledge_loan (tenant_id, key, number, lender_label, area_label, name_suffix, layout, is_active) values
    (v_subs, '2', 2, 'Lender A', 'UK', 'EUR', 1, true), (v_subs, '3', 3, 'Lender B', 'NL', 'EUR LTD', 2, false)
  on conflict (tenant_id, key) do nothing;
  insert into cma.pledge_model_value (tenant_id, model_key, type_label, acquisition_value, depreciation_per_month, receipts) values
    (v_subs, 'hs1', 'HS1', 845.00, 5.03, 120.00), (v_subs, 'frx', 'FRx', 900.00, 7.76, 99.50)
  on conflict (tenant_id, model_key) do nothing;
  insert into cma.device_language_alias (tenant_id, alias, code) values (v_subs, 'english', 'en') on conflict (tenant_id, alias) do nothing;
  alter table cma.device disable trigger audit;
  update cma.device d
     set pledge_ref = case when x.g % 9 = 0 then '99' when x.g % 3 = 1 then '3' else '2' end,
         language = case when x.g % 10 = 0 then null else 'en' end,
         raw = d.raw || jsonb_build_object('pledge_ref', case when x.g % 9 = 0 then '99' when x.g % 3 = 1 then '3' else '2' end,
                                           'language', case when x.g % 10 = 0 then 'Klingonese' else 'English' end)
    from (select id, row_number() over (order by source_id) as g from cma.device where tenant_id = v_subs and source_system = 'perfreg') x
   where d.id = x.id and x.g % 3 <> 0;
  get diagnostics n = row_count;
  alter table cma.device enable trigger audit;
  analyze cma.device;
  -- one quarter file of the current quarter, as the scheduler takes it (the owner's writer, the scheduler's permission)
  select u.id into v_sched from cma.app_user u where u.tenant_id = v_subs and u.email = 'scheduler@system.invalid';
  perform set_config('app.tenant_id', v_subs::text, true), set_config('app.user_id', v_sched::text, true);
  perform cma.pledge_snapshot_write(v_subs, date_trunc('quarter', cma.tenant_today_of(v_subs))::date);
  raise notice 'perf pledges written in % s: % devices pledged', round(extract(epoch from clock_timestamp() - t0), 1), n;
end
$$;
reset role;

-- Addition 0009l: Customers → Active at volume, so 131's active rows, perf.mjs and round-trips.mjs measure something. The
-- fixture's subscriptions above name customers of other stores and were all created within 700 days; this block shapes
-- them into a customer base with a history (rows changed, none added to cma.subscription; events, orders and deals added):
--   subscriptions     each linked to a customer of its own store (1,500 customers per store, about a quarter of them with
--                     two subscriptions), created over 60 months (20 to 1,820 days back); the first store's subscriptions
--                     older than 730 days all carry the day 730 days back (subscriptions moved into the subscription app
--                     carry the date they moved: the dominant cohort); a canceled one's canceled_at and a paused one's
--                     paused_at between its creation and now; an expired one gets its status_changed event to expired
--                     (one in five hundred none: the subscriptions in an ended status without an Ended time); the failed
--                     renewals above all stayed open, which no store shows: fourteen of fifteen subscriptions with failed
--                     renewals get a later renewal (events added: pase…, pasr…), so about 1,000 × m / 3 failed renewals stay
--                     open on 74 × m / 3 subscriptions In retry (Flash's subscriptions overview reads the same events)
--   devices           a device with a subscription reference takes that subscription's market and customer, so a
--                     customer's devices are found (the register names no store: Flash matches within a market)
--   segments          the contacts' segment: a fifth B2B, three fifths B2C, a fifth none (crm.customer_segments B2B,B2C)
--   order deals       an order pipeline (perf-orders, won stage po8) and, for each linked customer whose first
--                     subscription is at most 365 days old, a first store order (paord…) at that moment and a won order
--                     deal (pad…) of its contact at the same moment: about 1,500 × m / 3 first orders over a year
-- The acquisition channel reads cma.first_orders_of from the attribution's history start, which is intake.start_date
-- (60 days back above) plus attribution.window_days (90): in the future on this fixture as loaded, so every customer is
-- Unknown (before_history) and the read is empty. To time the channel over a year of first orders, move the start inside a
-- transaction and roll it back:  begin; set local role cma_owner; update cma.tenant_setting set value = (current_date - 455)::text
-- where key = 'intake.start_date' and tenant_id = (select id from cma.tenant where slug = 'pulse4all-subscriptions'); … ; rollback;
-- Every id is invented; no name, address, email or phone. Rerunnable: a second run finds the pipeline perf-orders and stops.
set role cma_owner;
do $$
declare
  v_subs uuid; v_crm uuid; t0 timestamptz := clock_timestamp(); n_s bigint; n_d bigint; n_o bigint;
begin
  if coalesce(current_setting('cma.local_fixture', true), '') <> 'on' then
    raise exception 'local fixture only: run  set cma.local_fixture = ''on''  in this session first';
  end if;
  select id into v_subs from cma.tenant where slug = 'pulse4all-subscriptions';
  select id into v_crm from cma.integration_connection where tenant_id = v_subs and adapter = 'perfcrm';
  if v_crm is null then
    raise notice 'the perf volume fixture is not present: nothing shaped for the active customers';
    return;
  end if;
  if exists (select 1 from cma.connection_pipeline where tenant_id = v_subs and connection_id = v_crm and source_pipeline_id = 'perf-orders') then
    raise notice 'perf active customers already present';
    return;
  end if;
  perform set_config('lock_timeout', '0', true);
  alter table cma.subscription disable trigger audit;
  alter table cma.subscription_event disable trigger audit;
  alter table cma.device disable trigger audit;
  alter table cma.crm_contact disable trigger audit;
  alter table cma.crm_record disable trigger audit;
  alter table cma.commerce_order disable trigger audit;

  -- the subscriptions: a customer of their own store, a creation over 60 months, the times of their status
  with sm as (
    select c.id as connection_id, x.store_connection_id,
           row_number() over (order by c.name) as store_no
    from cma.integration_connection c
    cross join lateral cma.subscription_store_connection_of(v_subs, c.id) x
    where c.tenant_id = v_subs and c.adapter = 'perfsubs'
  ), cu as (
    select k.connection_id, k.source_id, row_number() over (partition by k.connection_id order by k.source_id collate "C") as rn
    from cma.commerce_customer k where k.tenant_id = v_subs and k.source_system = 'perfshop'
  ), sb as (
    select s.id, substr(s.source_id, 5)::integer as g, sm.store_connection_id, sm.store_no,
           row_number() over (partition by s.connection_id order by substr(s.source_id, 5)::integer) as rn
    from cma.subscription s join sm on sm.connection_id = s.connection_id
    where s.tenant_id = v_subs and s.source_system = 'perfsubs'
  ), x as (
    select sb.id, sb.g, cu.source_id as customer,
           now() - make_interval(days => case when sb.store_no = 1 and 20 + (sb.g * 37) % 1800 > 730 then 730 else 20 + (sb.g * 37) % 1800 end) as created
    from sb join cu on cu.connection_id = sb.store_connection_id and cu.rn = 1 + (sb.rn * 7) % 1500
  )
  update cma.subscription s
     set customer_source_id = x.customer, source_created_at = x.created,
         canceled_at = case when s.status = 'canceled' then x.created + (now() - x.created) * (((x.g * 13) % 90 + 5) / 100.0) end,
         paused_at = case when s.status = 'paused' then x.created + (now() - x.created) * 0.8 end
    from x where s.id = x.id;
  get diagnostics n_s = row_count;
  analyze cma.subscription;
  insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at,
                                      status_from, status_to)
  select s.tenant_id, s.connection_id, 'perfsubs', 'pase' || substr(s.source_id, 5), s.source_id, 'status_changed',
         s.source_created_at + (now() - s.source_created_at) * (((substr(s.source_id, 5)::integer * 17) % 90 + 5) / 100.0), 'active', 'expired'
  from cma.subscription s
  where s.tenant_id = v_subs and s.source_system = 'perfsubs' and s.status = 'expired' and substr(s.source_id, 5)::integer % 500 <> 9;
  -- a failed renewal is mostly followed by a renewal: fourteen of fifteen subscriptions with failed renewals get a renewal of
  -- their last cycle an hour ago (above, every failed renewal stayed open: 15,000 × m / 3 on 1,107 × m / 3 subscriptions)
  insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, cycle_index)
  select v_subs, f.connection_id, 'perfsubs', 'pasr' || substr(f.subscription_source_id, 5), f.subscription_source_id, 'renewed', now() - interval '1 hour', 1000
  from (select distinct e.connection_id, e.subscription_source_id from cma.subscription_event e
        where e.tenant_id = v_subs and e.source_system = 'perfsubs' and e.event_type = 'renew_failed') f
  where (substr(f.subscription_source_id, 5)::integer / 20) % 15 <> 0;
  analyze cma.subscription_event;

  -- the devices of a subscription: its market and its customer
  update cma.device d
     set market = st.market, customer_ref = s.customer_source_id
    from cma.subscription s
    join cma.integration_connection c on c.tenant_id = s.tenant_id and c.id = s.connection_id
    cross join lateral cma.subscription_store_connection_of(v_subs, c.id) x
    join cma.commerce_store st on st.tenant_id = s.tenant_id and st.id = x.store_id
   where d.tenant_id = v_subs and d.source_system = 'perfreg' and d.subscription_ref = s.source_id
     and s.tenant_id = v_subs and s.source_system = 'perfsubs';
  get diagnostics n_d = row_count;
  analyze cma.device;

  -- the contacts' segments
  update cma.crm_contact k
     set segment = case (substr(k.source_id, 3)::integer / 3) % 5 when 0 then 'B2B' when 4 then null else 'B2C' end
   where k.tenant_id = v_subs and k.connection_id = v_crm and k.source_system = 'perfcrm';
  analyze cma.crm_contact;

  -- the order pipeline, and a first order with its won order deal per linked customer of the last 365 days
  insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted, is_lead, is_order)
  values (v_subs, v_crm, 'deal', 'perf-orders', 'Perf orders', true, false, true);
  insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, display_order, is_closed,
                                    outcome, outcome_source)
  values (v_subs, v_crm, 'deal', 'perf-orders', 'po8', 'Won', 8, true, 'won', 'person');
  with f as (
    select cu.connection_id, cu.source_id, cu.crm_contact_source_id as contact, cu.amount_currency, min(s.source_created_at) as t,
           row_number() over (order by cu.source_id collate "C") as n
    from cma.subscription s
    join cma.integration_connection c on c.tenant_id = s.tenant_id and c.id = s.connection_id
    cross join lateral cma.subscription_store_connection_of(v_subs, c.id) x
    join cma.commerce_customer cu on cu.tenant_id = s.tenant_id and cu.connection_id = x.store_connection_id and cu.source_id = s.customer_source_id
    where s.tenant_id = v_subs and s.source_system = 'perfsubs' and cu.crm_contact_source_id is not null
    group by 1, 2, 3, 4
    having min(s.source_created_at) >= now() - interval '365 days'
  ), o as (
    insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, order_name, customer_source_id, source_created_at, processed_at,
                                    is_test, currency, total_amount, financial_status, fulfillment_status, order_kind)
    select v_subs, f.connection_id, 'perfshop', 'paord' || f.n, '#PA' || f.n, f.source_id, f.t, f.t, false, f.amount_currency, 40 + f.n % 60, 'paid',
           'fulfilled', 'first'
    from f
    returning 1
  )
  insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref, contact_source_id,
                              is_closed, closed_at, source_created_at, source_updated_at, amount, currency)
  select v_subs, v_crm, 'perfcrm', 'deal', 'pad' || f.n, 'perf-orders', 'po8', 'po-' || (1 + f.n % 8), f.contact, true, f.t, f.t, f.t, 40 + f.n % 60,
         f.amount_currency
  from f;
  get diagnostics n_o = row_count;
  analyze cma.commerce_order;
  analyze cma.crm_record;

  alter table cma.subscription enable trigger audit;
  alter table cma.subscription_event enable trigger audit;
  alter table cma.device enable trigger audit;
  alter table cma.crm_contact enable trigger audit;
  alter table cma.crm_record enable trigger audit;
  alter table cma.commerce_order enable trigger audit;
  raise notice 'perf active customers written in % s: % subscriptions linked to their store''s customers, % devices moved to their subscription''s market, % first orders with their order deal',
    round(extract(epoch from clock_timestamp() - t0), 1), n_s, n_d, n_o;
end
$$;
reset role;

-- The stored take of Customers → Active (decision D13 of addendum B): refreshed once here, as the scheduler's job does
-- every minute where it runs, so the page, verify/perf.mjs and verify/round-trips.mjs read a take on this local database
-- too (no job runs here; run  node jobs/refresh-active-customers.mjs  with the local CMA_DB_* to refresh it again). A
-- rerun of the fixture stops at its guard above and does not reach this block: it runs once, after 172
set role cma_owner;
do $$
declare
  t record;
  r jsonb;
begin
  if to_regprocedure('cma.active_refresh_of(uuid,boolean,timestamptz)') is null then
    raise notice 'Customers → Active''s stored take not present (172 not run): no take written';
    return;
  end if;
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug loop
    perform set_config('app.tenant_id', t.id::text, true);
    r := cma.active_refresh_of(t.id, true);
    raise notice 'perf active take of %: %', t.slug, r;
  end loop;
end
$$;
reset role;
