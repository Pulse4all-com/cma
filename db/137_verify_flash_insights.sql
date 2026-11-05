-- =============================================================================================
-- 137_verify_flash_insights.sql: verifies addition 0008zt, Flash insights (brief B29 and its amendment: device
-- reconciliation, devices per holding subscription, subscription age, customer segment, device-holding statuses, the
-- statuses' meanings)
-- =============================================================================================
-- Universal: no seed is assumed. Block A checks structure and privileges; block B works on throwaway tenants inside a
-- subtransaction that is always rolled back, so nothing stays and the script runs in dev and in prod; block D reads every
-- tenant's own data and changes nothing; block C (speed at volume) runs only where verify.volume is set to 'true' at the
-- top (local databases). Adapters, handles, ids, codes and people are invented data values; no row carries a name, an
-- address, an email or a phone number. The snapshot's checks read a fixed business date (30 October 2026) taken at fixed
-- instants; the live age checks are seeded relative to the tenant's today, so the verdict does not depend on the day it
-- runs. Every check writes one row, ok, FAIL or skip, and the last row is the verdict, because Cloud SQL Studio shows no
-- notices. Run as your own IAM login after 136_flash_insights.sql and 02_seed_pulse4all.sql (rerun after 136: its block
-- for 0008zt), dev first, then prod. Since 138_flash_totals.sql (0008zu) A4 expects the subscriptions' split set
-- [market, status] and the version 0008zu of customers and subscriptions, B4's ratio check reads the rows that carry
-- the ratio's two counts (the split rows carry holding_subscriptions alone) and B7 the stored version 0008zu (without
-- 138 they read FAIL); 139_verify_flash_totals.sql is 0008zu's own check.
-- Expected verdict in dev and in prod (block C off, the default): "0008zt verified | 137_verify_flash_insights: 24 ok,
-- 0 FAIL, 1 skip" (25 checks: A1 to A7, B1 to B13, S1, D1 to D3 ok; C1 skip, volume off). A database without Pulse4all's CRM connection (a local one) reads S1 skip as
-- well, and one whose tenants have no set-up source reads D1 to D3 skip: still "0008zt verified" with those skips. A
-- local run with verify.volume 'true': C1 ok. Provoked: "PROVOKED, NOT A PASS | 137_verify_flash_insights: 0 ok, <n>
-- FAIL, <k> skip", every check that ran a FAIL.
--   A  structure: the addition after 0008zs; the five settings with their types and defaults, the settings trigger with
--      every earlier branch and the new ones; crm_contact.segment with its checks and the trigger that clears it;
--      connection_field takes a contact's segment (slot 1); the overviews' dims, sets, measures and count measures (the
--      ratio outside them, the watch reading them), the definitions' versions; every new and remade function the
--      application's only and in the caller's rights, the take's writer the owner's, JIT off where 0008zn had it; the
--      band words (device bands 1,2,3, 1,3 and 2,4; the age bands; an age at its edges, in the tenant's zone); data
--      quality's seventh check, where it is fixed, its view, and the holding subscriptions' check on the holding statuses
--   B  behaviour, on three throwaway tenants (Europe/Amsterdam). Tenant one: two stores (GB, NL), a subscriptions connection
--      each, a register with devices in the field and in stock (one in stock with a subscription reference, one in NL
--      referring to a GB subscription's id), a failed subscription with a device (active and failed hold devices there), a
--      CRM whose contacts carry segments (in the setting, outside it, in another case, empty), crm.customer_segments
--      B2B,B2C and meanings for two statuses. Tenant two holds the same ids, handles and a contact in a segment, and
--      is never counted in tenant one's. Tenant three holds subscriptions created relative to its today (the live ages).
--      Checked: the settings' refusals (bands 0,1; 2,1; 1,,2; spaces; more than the maximum; a segment twice in two cases,
--      an @; paused, an ended status or a bogus one holding devices, and an ended status that holds; meanings not JSON,
--      not an object, an unknown status or language, empty, an @, too long); the mapping's refusals; the installed base's
--      figures and reconciliation (in_field = in_field_on_holding + the devices on non-holding, ended, not_found and none,
--      per market too; a failed subscription's device counted as holding); the subscriptions' holding ones and their
--      devices in the field, the ratio (two decimals, none at 0), the device bands (every band with its row;
--      holding_subscriptions their sum), the active subscriptions' age bands at their edges on the snapshot's own date
--      (active_subscriptions their sum); the customers' segments (active_customers their sum; an empty setting: every
--      customer unknown); a device in stock with a reference counted by none of the device measures; devices_on_holding
--      equal to in_field_on_holding; the snapshot equal to the computation as of its date and to the document as of that
--      date; the run recording the settings; the watch's jump never on the ratio; the lists' new filters and measures;
--      tenant isolation; the ingest's segment (trimmed, empty, an @, too long, a deletion, the privacy deletion); the live
--      ages in the tenant's zone and the list's age filter; data quality (a device on a paused subscription a finding, on
--      a canceled one the ended check's alone, a holding subscription without a device, a failed one too); the hints'
--      settings on the landing and an overview (the tenant's statuses and meanings, none for a tenant without, never
--      another's); seed 02's values (S1: Pulse4all Subscriptions' CRM connection maps contact segment to customer_type,
--      crm.customer_segments B2B,B2C, active and failed hold devices, five meanings; skip without that connection)
--   D  every tenant's own figures, live, read only: in_field the sum over subscription_status and in_field_on_holding the
--      in_field of its holding statuses, holding_subscriptions and devices_on_holding the sums over device_band,
--      active_subscriptions over age_band, the ratio devices_on_holding / holding_subscriptions to two decimals and none at
--      0, active_customers the sum over segment; in all and per market
--      (skip where no tenant has the source set up)
--   C  speed at volume, local databases only (verify.volume 'true'): a throwaway tenant with 100,000 store customers
--      (a third linked to a contact with a segment), 100,000 subscriptions created over six years and 50,000 devices,
--      0008zn's volume; the three overviews live, as the application, each the best of two, under verify.max_overview_ms
--      (1,500 ms, the Decision log's of 3 November 2026)
-- Provoke: set provoke below to true; every check that runs must then read FAIL, and the verdict says PROVOKED, NOT A PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every check fail
select set_config('verify.max_overview_ms', '1500', false);          -- a live overview, as the application (Decision log, 3 Nov 2026)
select set_config('verify.volume', 'false', false);                  -- 'true' to run block C, local databases only

drop table if exists pg_temp.verify_0008zt;
create temp table verify_0008zt (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zt_code(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end
$$;

-- An overview's rows as one json array (dims, measures), live or measured against a business date
create or replace function pg_temp.v0008zt_rows(p_tenant uuid, p_overview text, p_on date)
returns jsonb
language sql
as $$
  select coalesce(jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures) order by c.dims::text collate "C"), '[]'::jsonb)
  from cma.flash_compute_of(p_tenant, p_overview, null, null, p_on) c
$$;

-- The rows of one breakdown set (exactly its keys) as one line: each row's dim value and measures in a fixed order
create or replace function pg_temp.v0008zt_set(p_rows jsonb, p_keys text[], p_measures text[])
returns text
language sql
as $$
  select coalesce(string_agg(coalesce((select string_agg(r -> 'dims' ->> k, '/' order by o) from unnest(p_keys) with ordinality u(k, o)), '') || ':'
                             || (select string_agg(coalesce(r -> 'measures' ->> m, '-'), ',' order by o) from unnest(p_measures) with ordinality u(m, o)),
                             ' ' order by coalesce((select string_agg(r -> 'dims' ->> k, '/' order by o) from unnest(p_keys) with ordinality u(k, o)), '') collate "C"), '-')
  from jsonb_array_elements(p_rows) r
  where coalesce((select array_agg(k order by k collate "C") from jsonb_object_keys(r -> 'dims') k), '{}')
        = coalesce((select array_agg(k order by k collate "C") from unnest(p_keys) k), '{}')
$$;

-- Where a measure of the totals ({}) and of each [market] row differs from the sum of that measure over the rows of a
-- breakdown dim (of the same market); empty when every one adds up
create or replace function pg_temp.v0008zt_unbalanced(p_rows jsonb, p_measure text, p_dim text)
returns text
language sql
as $$
  with r as (
    select x -> 'dims' as dims, x -> 'measures' as measures from jsonb_array_elements(p_rows) x
  ), tops as (
    select coalesce(r.dims ->> 'market', '*') as market, coalesce((r.measures ->> p_measure)::numeric, 0) as v
    from r where r.dims = '{}'::jsonb or r.dims = jsonb_build_object('market', r.dims ->> 'market')
  ), parts as (
    select r.dims ->> 'market' as market, sum(coalesce((r.measures ->> p_measure)::numeric, 0)) as v from r where r.dims ? p_dim group by 1
  ), cmp as (
    select t.market, t.v,
           coalesce(case when t.market = '*' then (select sum(p.v) from parts p) else (select p.v from parts p where p.market = t.market) end, 0) as s
    from tops t
  )
  select coalesce(string_agg(p_measure || '/' || p_dim || ' ' || c.market || ' ' || c.v || '<>' || c.s, '; ' order by c.market collate "C"), '')
  from cmp c where c.v <> c.s
$$;

-- The rows whose ratio is not devices_on_holding / holding_subscriptions to two decimals, or that hold one without a
-- device-holding subscription; empty when none
create or replace function pg_temp.v0008zt_ratio_bad(p_rows jsonb)
returns text
language sql
as $$
  select coalesce(string_agg((x -> 'dims')::text || ' ' || coalesce(x -> 'measures' ->> 'devices_per_holding_subscription', 'none'), '; '), '')
  from jsonb_array_elements(p_rows) x
  -- the rows that carry the ratio's two counts (since 0008zu the split rows [market, status] carry holding_subscriptions alone)
  where x -> 'measures' ? 'holding_subscriptions' and x -> 'measures' ? 'devices_on_holding'
    and case when (x -> 'measures' ->> 'holding_subscriptions')::numeric > 0
             then (x -> 'measures' ->> 'devices_per_holding_subscription') is null
                  or (x -> 'measures' ->> 'devices_per_holding_subscription')::numeric
                     <> round((x -> 'measures' ->> 'devices_on_holding')::numeric / (x -> 'measures' ->> 'holding_subscriptions')::numeric, 2)
                  or (x -> 'measures' ->> 'devices_per_holding_subscription') !~ '^[0-9]+\.[0-9]{2}$'
             else x -> 'measures' ? 'devices_per_holding_subscription' end
$$;

-- Where in_field_on_holding of the totals and of each [market] row differs from the in_field of that market's
-- subscription_status rows whose status is one of p_holding; empty when every one adds up
create or replace function pg_temp.v0008zt_holding_bad(p_rows jsonb, p_holding text[])
returns text
language sql
as $$
  with r as (
    select x -> 'dims' as dims, x -> 'measures' as measures from jsonb_array_elements(p_rows) x
  ), tops as (
    select coalesce(r.dims ->> 'market', '*') as market, coalesce((r.measures ->> 'in_field_on_holding')::numeric, 0) as v
    from r where r.dims = '{}'::jsonb or r.dims = jsonb_build_object('market', r.dims ->> 'market')
  ), parts as (
    select r.dims ->> 'market' as market, sum((r.measures ->> 'in_field')::numeric) as v
    from r where r.dims ? 'subscription_status' and (r.dims ->> 'subscription_status') = any (p_holding) group by 1
  )
  select coalesce(string_agg('holding ' || t.market || ' ' || t.v || '<>' || coalesce(case when t.market = '*' then (select sum(p.v) from parts p)
                                                                                       else (select p.v from parts p where p.market = t.market) end, 0), '; '), '')
  from tops t
  where t.v <> coalesce(case when t.market = '*' then (select sum(p.v) from parts p) else (select p.v from parts p where p.market = t.market) end, 0)
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
  v_src     text;
  v_plan    text;
  r         record;
begin
  insert into verify_0008zt values (1, 'A1 addition 0008zt recorded, after 0008zs',
    case when exists (select 1 from cma.schema_migration where version = '0008zt')
              and exists (select 1 from cma.schema_migration where version = '0008zs') and not v_provoke then 'ok' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the settings and their trigger: the three new ones, every earlier branch kept
  v_bad := '';
  if (select string_agg(s.key || ':' || s.value_type || ':' || s.default_value, ' ' order by s.key collate "C") from cma.setting s
      where s.key in ('flash.device_bands', 'flash.subscription_age_months', 'crm.customer_segments', 'flash.device_holding_statuses',
                      'subscription.status_meanings'))
     is distinct from 'crm.customer_segments:text: flash.device_bands:text:1,2,3 flash.device_holding_statuses:text:active '
                      || 'flash.subscription_age_months:text:12,24,36,48,60 subscription.status_meanings:text:{}' then
    v_bad := v_bad || 'settings; ';
  end if;
  v_src := (select prosrc from pg_proc where oid = 'cma.check_tenant_setting()'::regprocedure);
  if v_src !~ 'flash\.device_bands' or v_src !~ 'flash\.subscription_age_months' or v_src !~ 'crm\.customer_segments'
     or v_src !~ 'flash\.device_holding_statuses' or v_src !~ 'subscription\.status_meanings'
     or v_src !~ 'flash\.watch_stale_min_minutes' or v_src !~ 'flash\.ended_subscription_statuses' or v_src !~ 'cohorts\.lead_ages_days'
     or v_src !~ 'assets\.bundle_window_days' or v_src !~ 'reviews\.negative_max_rating' or v_src !~ 'workday\.window_start'
     or v_src ~ '''(flash\.device_bands|flash\.subscription_age_months|crm\.customer_segments)''[^)]*\) then\s+new\.value := regexp_replace' then
    v_bad := v_bad || 'the trigger; ';
  end if;
  insert into verify_0008zt values (2, 'A2 the five settings with their defaults; the settings trigger with every earlier branch and theirs',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A3. the contact's segment: the column, its checks, the trigger that clears it; the mapping's field for a contact
  v_bad := '';
  if (select string_agg(column_name || ':' || udt_name || ':' || is_nullable, ',') from information_schema.columns
      where table_schema = 'cma' and table_name = 'crm_contact' and column_name = 'segment') is distinct from 'segment:text:YES' then
    v_bad := v_bad || 'column; ';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.crm_contact'::regclass and conname = 'crm_contact_segment_check' and convalidated)
     or not exists (select 1 from pg_constraint where conrelid = 'cma.crm_contact'::regclass and conname = 'crm_contact_segment_deleted_check' and convalidated)
     or not exists (select 1 from pg_trigger where tgrelid = 'cma.crm_contact'::regclass and tgname = 'clear_segment' and not tgisinternal)
     or has_function_privilege('cma_app', 'cma.crm_contact_clear_segment()', 'execute') then
    v_bad := v_bad || 'checks or trigger; ';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_entity_field_check')
       !~ 'contact.*''segment''::text'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_field_check')
       !~ '''segment''::text'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_entity_field_check')
       !~ '''created_at''::text' then
    v_bad := v_bad || 'mapping; ';
  end if;
  if (select prosrc from pg_proc where oid = 'cma.ingest_upsert_contacts(uuid,jsonb)'::regprocedure) !~ 'segment = null'
     or (select prosrc from pg_proc where oid = 'cma.ingest_upsert_contacts(uuid,jsonb)'::regprocedure) !~ 'cma\.commerce_customer cu'
     or (select prosrc from pg_proc where oid = 'cma.ingest_upsert_contacts(uuid,jsonb)'::regprocedure) !~ 'createdAts' then
    v_bad := v_bad || 'the upsert; ';
  end if;
  insert into verify_0008zt values (3, 'A3 crm_contact.segment, its checks and the trigger clearing it; a contact''s segment mappable; the upsert carries what came before',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A4. the overviews: dims, sets, measures, count measures (the ratio outside them), versions; the watch reads count measures
  v_bad := '';
  if (select string_agg(o.key || '|' || array_to_string(o.dims, ',') || '|' || o.sets::text || '|' || array_to_string(o.measures, ',') || '|'
                        || array_to_string(o.count_measures, ','), ' ' order by o.sort_order)
      from cma.flash_overviews() o where o.key in ('customers', 'subscriptions', 'installed_base'))
     is distinct from
     'customers|market,store,segment|[[], ["market"], ["market", "store"], ["market", "segment"]]|customers_held,active_customers,paused_customers,linked_to_contact,with_required_refs|customers_held,active_customers,paused_customers,linked_to_contact,with_required_refs '
     -- since 0008zu (138): the subscriptions' split set [market, status]
     || 'subscriptions|market,store,status,payment_state,device_band,age_band|[[], ["market"], ["market", "status"], ["market", "store", "status", "payment_state"], ["market", "device_band"], ["market", "age_band"]]|subscriptions,active_subscriptions,paused_subscriptions,amount_per_cycle,holding_subscriptions,devices_on_holding,devices_per_holding_subscription|subscriptions,active_subscriptions,paused_subscriptions,holding_subscriptions,devices_on_holding '
     || 'installed_base|market,status,model,warehouse,link,subscription_status|[[], ["market"], ["market", "status", "model", "warehouse", "link"], ["market", "subscription_status"]]|devices,in_field,in_stock,components_past_due,items_due_3m,in_field_on_holding|devices,in_field,in_stock,components_past_due,items_due_3m,in_field_on_holding' then
    v_bad := v_bad || 'the catalog; ';
  end if;
  if exists (select 1 from cma.flash_overviews() o where 'devices_per_holding_subscription' = any (o.count_measures))
     or (select prosrc from pg_proc where oid = 'cma.flash_watch_of(uuid,date,timestamptz)'::regprocedure) !~ 'unnest\(o\.count_measures\)' then
    v_bad := v_bad || 'the ratio among the watched; ';
  end if;
  if (select string_agg(o.key || ':' || cma.flash_definition_version(o.key), ',' order by o.sort_order) from cma.flash_overviews() o)
     -- since 0008zu (138): customers and subscriptions 0008zu
     is distinct from 'customers:0008zu,subscriptions:0008zu,installed_base:0008zt,churn:0008zn,orders:0008zn,payments:0008zn,open_deals:0008zn,'
                      || 'open_tickets:0008zn,open_tasks:0008zn,reviews:0008zn,data_quality:0008zn' then
    v_bad := v_bad || 'versions; ';
  end if;
  insert into verify_0008zt values (4, 'A4 the overviews'' new dims, sets and measures; the ratio no count measure, the watch reading the counts; the versions',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A5. privileges: the application's only, the caller's rights; the take's writer the owner's; JIT off as 0008zn
  v_bad := '';
  foreach v_fn in array array[
    'cma.flash_bounds_of(text)', 'cma.flash_count_band_of(integer,integer[])', 'cma.flash_count_bands_of(integer[])',
    'cma.flash_age_months_of(timestamptz,text,date)', 'cma.flash_age_band_of(integer,integer[])', 'cma.flash_age_bands_of(integer[])',
    'cma.flash_ratio_of(numeric,numeric)', 'cma.flash_segment_of(text,text[],text[])', 'cma.flash_overviews()', 'cma.flash_definition_version(text)',
    'cma.flash_store_customers_of(uuid)', 'cma.flash_customers_of(uuid)', 'cma.flash_subscriptions_of(uuid,date)', 'cma.flash_subscriptions_of(uuid)',
    'cma.flash_devices_of(uuid,date)',
    'cma.flash_compute_of(uuid,text,date,date,date)', 'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)',
    'cma.flash_document_of(uuid,text,text,date,date,date)', 'cma.ingest_upsert_contacts(uuid,jsonb)', 'cma.check_tenant_setting()',
    'cma.flash_holding_statuses_of(uuid)', 'cma.flash_status_meanings_ok(text)', 'cma.flash_status_settings_of(uuid)', 'cma.flash_page(text,date,date,date)',
    'cma.data_quality_flash_checks()', 'cma.data_quality_of(uuid)', 'cma.data_quality()', 'cma.data_quality_fix_in(text,text)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif (v_fn <> 'cma.check_tenant_setting()' and (not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')))
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  if has_function_privilege('cma_app', 'cma.flash_snapshot_take_at(uuid,timestamptz)', 'execute') then
    v_bad := v_bad || 'the take''s writer; ';
  end if;
  foreach v_fn in array array['cma.flash_compute_of(uuid,text,date,date,date)', 'cma.flash_document_of(uuid,text,text,date,date,date)',
                              'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)', 'cma.flash_snapshot_take_at(uuid,timestamptz)',
                              'cma.data_quality_of(uuid)'] loop
    if not coalesce((select 'jit=off' = any (proconfig) from pg_proc where oid = to_regprocedure(v_fn)), false) then
      v_bad := v_bad || v_fn || ' jit; ';
    end if;
  end loop;
  -- the immutable helpers are inlined where a row calls them (a plan names none of them): a helper called per row instead
  -- costs some 4 microseconds a row, 0.4 s over 100,000 subscriptions
  v_plan := '';
  for r in execute 'explain (verbose) select cma.flash_age_months_of(v.t, v.z, v.d), cma.flash_age_band_of(v.n, v.b), cma.flash_count_band_of(v.n, v.b), '
                   || 'cma.flash_segment_of(v.z, array[v.z], array[v.z]), cma.flash_ratio_of(v.n, v.n) '
                   || 'from (select now() as t, ''Europe/Amsterdam''::text as z, current_date as d, 3 as n, array[1, 2, 3] as b offset 0) v' loop
    v_plan := v_plan || r."QUERY PLAN" || ' ';
  end loop;
  if v_plan ~ 'flash_(age_months|age_band|count_band|segment|ratio)_of' then
    v_bad := v_bad || 'a helper not inlined; ';
  end if;
  insert into verify_0008zt values (5, 'A5 every new and remade function the application''s only, in the caller''s rights; the take''s writer the owner''s; JIT off; the helpers inlinable',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A6. the band words and an age at its edges, in the tenant's zone
  v_bad := array_to_string(cma.flash_count_bands_of(array[1, 2, 3]), ' ') || ' | ' || array_to_string(cma.flash_count_bands_of(array[1, 3]), ' ')
           || ' | ' || array_to_string(cma.flash_count_bands_of(array[2, 4]), ' ') || ' | ' || array_to_string(cma.flash_age_bands_of(array[12, 24, 36, 48, 60]), ' ')
           || ' | ' || cma.flash_count_band_of(0, array[1, 2, 3]) || ' ' || cma.flash_count_band_of(3, array[1, 2, 3]) || ' ' || cma.flash_count_band_of(9, array[1, 2, 3])
           || ' ' || cma.flash_count_band_of(2, array[1, 3]) || ' ' || cma.flash_count_band_of(1, array[2, 4])
           || ' | ' || cma.flash_age_months_of('2025-11-05 00:15 Europe/Amsterdam', 'Europe/Amsterdam', '2026-11-05')
           || ' ' || cma.flash_age_months_of('2025-11-06 00:30 Europe/Amsterdam', 'Europe/Amsterdam', '2026-11-05')
           || ' ' || cma.flash_age_months_of('2026-11-06 10:00 Europe/Amsterdam', 'Europe/Amsterdam', '2026-11-05')
           || ' ' || cma.flash_age_band_of(12, array[12, 24]) || ' ' || cma.flash_age_band_of(11, array[12, 24]) || ' ' || cma.flash_age_band_of(24, array[12, 24])
           || ' ' || cma.flash_age_band_of(-1, array[12, 24]) || ' ' || cma.flash_age_band_of(null, array[12, 24])
           || ' | ' || coalesce(cma.flash_ratio_of(7, 5)::text, 'none') || ' ' || coalesce(cma.flash_ratio_of(1, 3)::text, 'none') || ' ' || coalesce(cma.flash_ratio_of(4, 0)::text, 'none')
           || ' | ' || cma.flash_segment_of('b2c', array['B2B', 'B2C'], array['b2b', 'b2c']) || ' ' || cma.flash_segment_of('', array['B2B'], array['b2b'])
           || ' ' || cma.flash_segment_of(null, array['B2B'], array['b2b']) || ' ' || cma.flash_segment_of('B2B', '{}', '{}');
  insert into verify_0008zt values (6, 'A6 the band words (1,2,3; 1,3; 2,4; the ages), an age at its edges in the tenant''s zone, the ratio, a segment''s case',
    case when v_bad = '0 1 2 3+ | 0 1-2 3+ | 0 1 2-3 4+ | <12 12-24 24-36 36-48 48-60 60+ | 0 3+ 3+ 1-2 1 | 12 11 0 12-24 <12 24+ <12 unknown | 1.40 0.33 none | B2C unknown unknown unknown'
              and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A7. data quality: the seventh Flash check after the six, fixed in the asset register, with its reader view; the
  --     holding subscriptions' check reads the holding statuses; data_quality() lists it with the others
  v_bad := '';
  if (select string_agg(check_key || ':' || sort_order, ',' order by sort_order) from cma.data_quality_flash_checks())
     is distinct from 'customer_required_ref_missing:310,device_required_ref_missing:320,subscription_customer_unmatched:330,'
                      || 'active_subscription_without_device:340,device_subscription_ref_unknown:350,field_device_on_ended_subscription:360,'
                      || 'field_device_on_non_holding_subscription:370'
     or (select count(*) from cma.data_quality_catalog()) <> (select count(distinct check_key) from cma.data_quality_catalog())
     or cma.data_quality_fix_in('field_device_on_non_holding_subscription', 'paused') <> 'assets' then
    v_bad := v_bad || 'the catalog; ';
  end if;
  v_src := (select prosrc from pg_proc where oid = 'cma.data_quality_of(uuid)'::regprocedure);
  if v_src !~ 'field_device_on_non_holding_subscription' or v_src !~ 'flash_holding_statuses_of' or v_src !~ 'outbound_unanswered_untagged'
     or v_src !~ 'form_answer_not_in_options' or v_src !~ 'market_without_review_channel' or v_src !~ 'field_device_without_subscription_ref'
     or (select prosrc from pg_proc where oid = 'cma.data_quality()'::regprocedure) !~ 'field_device_on_non_holding_subscription'
     or (select prosrc from pg_proc where oid = 'cma.data_quality()'::regprocedure) !~ 'data_quality_snapshot_of'
     or (select provolatile from pg_proc where oid = 'cma.data_quality()'::regprocedure) <> 'v' then
    v_bad := v_bad || 'the functions; ';
  end if;
  if to_regclass('cma_read.dq_field_device_on_non_holding_subscription') is null
     or (select string_agg(attname, ',' order by attnum) from pg_attribute
         where attrelid = 'cma_read.dq_field_device_on_non_holding_subscription'::regclass and attnum > 0 and not attisdropped)
        is distinct from 'tenant_id,connection_id,object_type,object_id,value' then
    v_bad := v_bad || 'the view; ';
  end if;
  insert into verify_0008zt values (7, 'A7 data quality: the seventh check (a device on a subscription that holds none), fixed in the register, its view; the holding check',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on three throwaway tenants (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_t2 uuid; v_t3 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_ingest1 uuid; v_sched1 uuid; v_analyst3 uuid;
  v_crm uuid; v_gb uuid; v_nl uuid; v_sgb uuid; v_snl uuid; v_reg uuid;
  v_crm2 uuid; v_gb2 uuid; v_sgb2 uuid; v_reg2 uuid;
  v_gb3 uuid; v_sgb3 uuid;
  v_txt text; v_a text; v_b text;
  j jsonb; v_r jsonb;
  o record;
  v_today3 date;
  -- the business date of the snapshot checks and the instants of its takes (Europe/Amsterdam, after 00:30)
  v_d       date := '2026-10-30';
  v_take_0  timestamptz := '2026-10-30 01:00:00 Europe/Amsterdam';   -- takes 29 October
  v_take_1  timestamptz := '2026-10-31 01:00:00 Europe/Amsterdam';   -- takes 30 October
begin
  begin
    -- tenants and people (as the owner); each tenant's Scheduler and Ingest users come with create_tenant
    v_t1 := cma.create_tenant('verify-0008zt-one', 'Verify 0008zt one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zt-two', 'Verify 0008zt two', 'Europe/Amsterdam');
    v_t3 := cma.create_tenant('verify-0008zt-three', 'Verify 0008zt three', 'Europe/Amsterdam');
    v_today3 := cma.tenant_today_of(v_t3);
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t3, 'verify-analyst3@example.invalid', 'analyst3') returning id into v_analyst3;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t3, v_analyst3, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select u.id into v_sched1 from cma.app_user u where u.tenant_id = v_t1 and u.email = 'scheduler@system.invalid';
    select x.user_id into v_ingest1 from cma.app_user_external_id x
    join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
    where x.tenant_id = v_t1 and u.kind = 'system' and u.id <> v_sched1 limit 1;

    -- tenant one's sources (as the owner): two stores with a subscriptions connection each, a register, a CRM
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
      (v_t1, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10), (v_t1, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 20);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifycrm', 'Verify CRM', 'portal-1', 'crm') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyshop', 'Verify shop GB', 'shop-gb.shop.example', 'commerce') returning id into v_gb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyshop', 'Verify shop NL', 'shop-nl.shop.example', 'commerce') returning id into v_nl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifysubs', 'Verify subscriptions GB', 'shop-gb.shop.example', 'subscriptions', 'verify-subs-gb') returning id into v_sgb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifysubs', 'Verify subscriptions NL', 'shop-nl.shop.example', 'subscriptions', 'verify-subs-nl') returning id into v_snl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyregister', 'Verify register', 'base-1', 'assets') returning id into v_reg;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values
      (v_t1, v_gb, 'shop-gb', 'Shop GB', 'GB', 'GBP', 'Europe/London'), (v_t1, v_nl, 'shop-nl', 'Shop NL', 'NL', 'EUR', 'Europe/Amsterdam');
    -- store customers: cu-1 to cu-4 linked to held contacts (B2B; b2c, another case; Retail, outside the setting; none),
    -- cu-5 linked to nothing, cu-6 linked to a contact the CMA does not hold; ncu-1 in NL, B2B
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, orders_count, crm_connection_id, crm_contact_source_id, matched_at) values
      (v_t1, v_gb, 'verifyshop', 'cu-1', 1, v_crm, 'c-1', now()), (v_t1, v_gb, 'verifyshop', 'cu-2', 1, v_crm, 'c-2', now()),
      (v_t1, v_gb, 'verifyshop', 'cu-3', 1, v_crm, 'c-3', now()), (v_t1, v_gb, 'verifyshop', 'cu-4', 1, v_crm, 'c-4', now()),
      (v_t1, v_gb, 'verifyshop', 'cu-5', 1, null, null, null), (v_t1, v_gb, 'verifyshop', 'cu-6', 0, v_crm, 'c-6', now()),
      (v_t1, v_nl, 'verifyshop', 'ncu-1', 1, v_crm, 'c-7', now());
    insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, segment) values
      (v_t1, v_crm, 'verifycrm', 'c-1', 'GB', 'B2B'), (v_t1, v_crm, 'verifycrm', 'c-2', 'GB', 'b2c'), (v_t1, v_crm, 'verifycrm', 'c-3', 'GB', 'Retail'),
      (v_t1, v_crm, 'verifycrm', 'c-4', 'GB', null), (v_t1, v_crm, 'verifycrm', 'c-7', 'NL', 'B2B');
    -- subscriptions as of 30 October 2026: s-1 created exactly 12 months before (12-24), s-2 a day later (<12 on the 30th,
    -- 12-24 the day after), s-3 without a creation time (unknown), s-4 61 months before (60+), s-5 paused, s-6 canceled,
    -- s-7 failed (a device-holding status here, not an active one); n-1 in NL, 30 months before (24-36)
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, amount_per_cycle, currency,
                                  billing_interval, billing_interval_count, paused_at, source_created_at) values
      (v_t1, v_sgb, 'verifysubs', 's-1', 'cu-1', 'active', 20.00, 'GBP', 'month', 1, null, '2025-10-30 09:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-2', 'cu-2', 'active', 20.00, 'GBP', 'month', 1, null, '2025-10-31 00:30 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-3', 'cu-3', 'active', 20.00, 'GBP', 'month', 1, null, null),
      (v_t1, v_sgb, 'verifysubs', 's-4', 'cu-1', 'active', 20.00, 'GBP', 'month', 1, null, '2021-09-30 12:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-5', 'cu-4', 'paused', 20.00, 'GBP', 'month', 1, now(), '2024-01-01 12:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-6', 'cu-5', 'canceled', 20.00, 'GBP', 'month', 1, null, '2024-01-01 12:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-7', 'cu-1', 'failed', 20.00, 'GBP', 'month', 1, null, '2025-06-15 12:00 Europe/Amsterdam'),
      (v_t1, v_snl, 'verifysubs', 'n-1', 'ncu-1', 'active', 30.00, 'EUR', 'month', 1, null, '2024-04-30 12:00 Europe/Amsterdam');
    -- the register: d-1 to d-3 on s-1 (d-3 in stock), d-4 on s-2, d-5 to d-7 on s-4, d-8 on the paused s-5, d-9 on the
    -- canceled s-6, d-10 on an id no subscription has, d-11 in the field and d-12 in stock without a reference, d-13 on the
    -- failed s-7; in NL nd-1 on
    -- n-1 and nd-2 on s-1's id, a GB subscription (matched within its market: not found)
    insert into cma.device_model (tenant_id, key, name) values (v_t1, 'm1', 'M1');
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked) values
      (v_t1, 'field', 'Field', true, false, true), (v_t1, 'stock', 'Stock', false, true, true);
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, subscription_ref)
    select v_t1, v_reg, 'verifyregister', x.rec, 'SN-' || x.rec, 'm1', x.market, x.st, x.ref
    from (values ('d-1', 'GB', 'field', 's-1'), ('d-2', 'GB', 'field', 's-1'), ('d-3', 'GB', 'stock', 's-1'), ('d-4', 'GB', 'field', 's-2'),
                 ('d-5', 'GB', 'field', 's-4'), ('d-6', 'GB', 'field', 's-4'), ('d-7', 'GB', 'field', 's-4'), ('d-8', 'GB', 'field', 's-5'),
                 ('d-9', 'GB', 'field', 's-6'), ('d-10', 'GB', 'field', 'nope'), ('d-11', 'GB', 'field', null), ('d-12', 'GB', 'stock', null),
                 ('d-13', 'GB', 'field', 's-7'), ('nd-1', 'NL', 'field', 'n-1'), ('nd-2', 'NL', 'field', 's-1')) as x(rec, market, st, ref);

    -- tenant two: the same ids, handles and a contact in a segment; never counted in tenant one's
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values (v_t2, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t2, 'verifycrm', 'CRM two', 'portal-1', 'crm') returning id into v_crm2;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t2, 'verifyshop', 'Shop two', 'shop-gb.shop.example', 'commerce') returning id into v_gb2;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t2, 'verifysubs', 'Subs two', 'shop-gb.shop.example', 'subscriptions', 'verify-subs-two') returning id into v_sgb2;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t2, 'verifyregister', 'Register two', 'base-1', 'assets') returning id into v_reg2;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values (v_t2, v_gb2, 'shop-gb', 'Shop two', 'GB', 'GBP', 'Europe/London');
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t2, 'crm.customer_segments', 'B2B,B2C');
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, orders_count, crm_connection_id, crm_contact_source_id, matched_at)
    values (v_t2, v_gb2, 'verifyshop', 'cu-1', 1, v_crm2, 'c-1', now());
    insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, segment) values (v_t2, v_crm2, 'verifycrm', 'c-1', 'GB', 'B2C');
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, amount_per_cycle, currency, source_created_at)
    values (v_t2, v_sgb2, 'verifysubs', 's-1', 'cu-1', 'active', 10.00, 'GBP', '2020-01-01 12:00 Europe/Amsterdam');
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked) values (v_t2, 'field', 'Field', true, false, true);
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, market, device_status_key, subscription_ref)
    select v_t2, v_reg2, 'verifyregister', 'd-' || g, 'SN-' || g, 'GB', 'field', 's-1' from generate_series(1, 5) g;

    -- B1. the settings, as tenant one's admin: refusals (CMA04) and accepted values; then crm.customer_segments B2B,B2C
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := '';
    foreach v_a in array array['0,1', '2,1', '1,,2', '1, 2', ' 1,2', '1,2,3,4,5,6,7', '', '1,2,3,', 'x'] loop
      v_txt := v_txt || pg_temp.v0008zt_code(format('select cma.set_tenant_setting(''flash.device_bands'', %L)', v_a)) || ' ';
    end loop;
    v_txt := v_txt || pg_temp.v0008zt_code('select cma.set_tenant_setting(''flash.device_bands'', ''1,3'')') || ' | ';
    foreach v_a in array array['0,12', '24,12', '12,,24', '12, 24', '1,2,3,4,5,6,7,8,9,10,11', ''] loop
      v_txt := v_txt || pg_temp.v0008zt_code(format('select cma.set_tenant_setting(''flash.subscription_age_months'', %L)', v_a)) || ' ';
    end loop;
    v_txt := v_txt || pg_temp.v0008zt_code('select cma.set_tenant_setting(''flash.subscription_age_months'', ''1,2,3,4,5,6,7,8,9,10'')') || ' | ';
    foreach v_a in array array['B2B, B2C', 'B2B,,B2C', 'B2B,b2b', 'a@b', 'x y', ',B2B', array_to_string(array(select 's' || g from generate_series(1, 21) g), ',')] loop
      v_txt := v_txt || pg_temp.v0008zt_code(format('select cma.set_tenant_setting(''crm.customer_segments'', %L)', v_a)) || ' ';
    end loop;
    v_txt := v_txt || pg_temp.v0008zt_code('select cma.set_tenant_setting(''crm.customer_segments'', '''')') || ' '
             || pg_temp.v0008zt_code('select cma.set_tenant_setting(''crm.customer_segments'', ''B2B,B2C'')') || ' | ';
    -- the device-holding statuses: never paused, none of the ended ones (and the ended ones none of them)
    foreach v_a in array array['paused', 'active,canceled', 'active,bogus'] loop
      v_txt := v_txt || pg_temp.v0008zt_code(format('select cma.set_tenant_setting(''flash.device_holding_statuses'', %L)', v_a)) || ' ';
    end loop;
    v_txt := v_txt || pg_temp.v0008zt_code('select cma.set_tenant_setting(''flash.device_holding_statuses'', ''active,failed'')') || ' '
             || pg_temp.v0008zt_code('select cma.set_tenant_setting(''flash.ended_subscription_statuses'', ''canceled,failed'')') || ' | ';
    -- the statuses' meanings: invalid JSON, not an object, a key no status, a language not en or nl, empty, an @, not an
    -- object, over 200 characters, no language; then a valid one
    foreach v_a in array array['not json', '[]', '{"bogus": {"en": "x"}}', '{"active": {"de": "x"}}', '{"active": {"en": " "}}',
                               '{"active": {"en": "someone@example.invalid"}}', '{"active": "x"}', '{"active": {"en": "' || repeat('x', 201) || '"}}',
                               '{"active": {}}'] loop
      v_txt := v_txt || pg_temp.v0008zt_code(format('select cma.set_tenant_setting(''subscription.status_meanings'', %L)', v_a)) || ' ';
    end loop;
    v_txt := v_txt || pg_temp.v0008zt_code('select cma.set_tenant_setting(''subscription.status_meanings'', ''{"active": {"en": "One device.", "nl": "Eén apparaat."}, "failed": {"en": "Unpaid; devices stay."}}'')');
    perform cma.set_tenant_setting('flash.device_bands', '1,2,3');
    perform cma.set_tenant_setting('flash.subscription_age_months', '12,24,36,48,60');
    v_txt := v_txt || ' | ' || cma.setting_of(v_t1, 'flash.device_bands') || ' ' || cma.setting_of(v_t1, 'flash.subscription_age_months')
             || ' ' || cma.setting_of(v_t1, 'crm.customer_segments') || ' ' || cma.setting_of(v_t1, 'flash.device_holding_statuses')
             || ' ' || cma.setting_of(v_t1, 'flash.ended_subscription_statuses')
             || ' ' || (select string_agg(k, ',' order by k collate "C") from jsonb_object_keys(cma.setting_of(v_t1, 'subscription.status_meanings')::jsonb) k);
    v_rows := v_rows || array['11', 'B1 the settings'' refusals (bands 0,1; 2,1; 1,,2; spaces; over the maximum; a segment twice, an @; paused or an ended status holding devices; meanings not JSON, an unknown key, too long, an @); the values kept',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 ok | CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 ok | '
                        || 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 ok ok | CMA04 CMA04 CMA04 ok CMA04 | '
                        || 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 ok | 1,2,3 12,24,36,48,60 B2B,B2C active,failed canceled,expired active,failed'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B2. the mapping: a contact's segment in slot 1, not in slot 2, never on a deal (as the admin, tenant.configure)
    v_txt := pg_temp.v0008zt_code(format('select cma.set_connection_field(%L, ''contact'', ''segment'', '''', ''customer_type'', 1::smallint)', v_crm))
             || ' ' || pg_temp.v0008zt_code(format('select cma.set_connection_field(%L, ''contact'', ''segment'', '''', ''other_type'', 2::smallint)', v_crm))
             || ' ' || pg_temp.v0008zt_code(format('select cma.set_connection_field(%L, ''deal'', ''segment'', '''', ''customer_type'', 1::smallint)', v_crm))
             || ' ' || pg_temp.v0008zt_code(format('select cma.set_connection_field(%L, ''contact'', ''segment'', ''x'', ''customer_type'', 1::smallint)', v_crm));
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' ' || (select string_agg(f.entity || ':' || f.field || ':' || f.slot || ':' || f.source_property, ',') from cma.connection_field f
                              where f.tenant_id = v_t1 and f.connection_id = v_crm);
    v_rows := v_rows || array['12', 'B2 the mapping: a contact''s segment in slot 1 only, never a deal''s, no reference system',
      case when v_txt = 'ok CMA04 CMA04 CMA04 contact:segment:1:customer_type' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B3. the installed base on 30 October: devices, in the field, in stock, on an active subscription; the subscription
    --     status per market; in_field the sum over subscription_status, in all and per market
    v_r := pg_temp.v0008zt_rows(v_t1, 'installed_base', v_d);
    v_txt := pg_temp.v0008zt_set(v_r, '{}', array['devices', 'in_field', 'in_stock', 'in_field_on_holding'])
             || ' ' || pg_temp.v0008zt_set(v_r, array['market'], array['devices', 'in_field', 'in_stock', 'in_field_on_holding'])
             || ' ' || pg_temp.v0008zt_set(v_r, array['market', 'subscription_status'], array['devices', 'in_field', 'in_stock', 'in_field_on_holding'])
             || ' | ' || pg_temp.v0008zt_unbalanced(v_r, 'in_field', 'subscription_status') || pg_temp.v0008zt_unbalanced(v_r, 'devices', 'subscription_status')
             || pg_temp.v0008zt_unbalanced(v_r, 'in_field_on_holding', 'subscription_status') || pg_temp.v0008zt_holding_bad(v_r, array['active', 'failed']);
    v_rows := v_rows || array['13', 'B3 the installed base: each device''s subscription status, in_field_on_holding (a failed subscription holds devices); in_field = on holding + non-holding, ended, not_found and none, per market too',
      case when v_txt = ':15,13,2,8 GB:13,11,2,7 NL:2,2,0,1 GB/active:7,6,1,6 GB/canceled:1,1,0,0 GB/failed:1,1,0,1 GB/none:2,1,1,0 GB/not_found:1,1,0,0 '
                        || 'GB/paused:1,1,0,0 NL/active:1,1,0,1 NL/not_found:1,1,0,0 | '
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B4. the subscriptions on 30 October: the device-holding ones (active and failed here) and their devices in the field,
    --     the ratio (two decimals, none without a holding subscription), the device bands (every band with its row); the
    --     bands' sums
    v_r := pg_temp.v0008zt_rows(v_t1, 'subscriptions', v_d);
    v_txt := pg_temp.v0008zt_set(v_r, '{}', array['subscriptions', 'active_subscriptions', 'holding_subscriptions', 'devices_on_holding', 'devices_per_holding_subscription'])
             || ' ' || pg_temp.v0008zt_set(v_r, array['market'], array['active_subscriptions', 'holding_subscriptions', 'devices_on_holding', 'devices_per_holding_subscription'])
             || ' ' || pg_temp.v0008zt_set(v_r, array['market', 'device_band'], array['holding_subscriptions', 'devices_on_holding', 'devices_per_holding_subscription'])
             || ' | ' || pg_temp.v0008zt_set(v_r, array['market', 'store', 'status', 'payment_state'],
                                             array['active_subscriptions', 'holding_subscriptions', 'devices_on_holding', 'devices_per_holding_subscription'])
             || ' | ' || pg_temp.v0008zt_unbalanced(v_r, 'holding_subscriptions', 'device_band') || pg_temp.v0008zt_unbalanced(v_r, 'devices_on_holding', 'device_band')
             || pg_temp.v0008zt_ratio_bad(v_r);
    v_rows := v_rows || array['14', 'B4 the subscriptions: the holding ones and their devices in the field, the ratio (none at 0), the device bands with every band''s row; their sums, per market too',
      case when v_txt = ':8,5,6,8,1.33 GB:4,5,7,1.40 NL:1,1,1,1.00 GB/0:1,0,0.00 GB/1:2,2,1.00 GB/2:1,2,2.00 GB/3+:1,3,3.00 NL/0:0,0,- NL/1:1,1,1.00 NL/2:0,0,- NL/3+:0,0,- | '
                        || 'GB/shop-gb/active/paid:4,4,6,1.50 GB/shop-gb/canceled/canceled:0,0,0,- GB/shop-gb/failed/failed:0,1,1,1.00 GB/shop-gb/paused/paused:0,0,0,- '
                        || 'NL/shop-nl/active/paid:1,1,1,1.00 | '
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B5. the ages on the snapshot's own date: exactly 12 months on the 30th is 12-24, a day short <12 (12-24 the day
    --     after), no creation time unknown; the age bands' sums; a device in stock with a reference in no new measure
    v_txt := pg_temp.v0008zt_set(v_r, array['market', 'age_band'], array['active_subscriptions'])
             || ' | ' || pg_temp.v0008zt_unbalanced(v_r, 'active_subscriptions', 'age_band')
             || ' | ' || pg_temp.v0008zt_set(pg_temp.v0008zt_rows(v_t1, 'subscriptions', v_d + 1), array['market', 'age_band'], array['active_subscriptions'])
             || ' | ' || (select string_agg(s.source_id || ':' || s.devices || '/' || s.devices_in_field || '/' || coalesce(s.device_band, '-') || '/' || coalesce(s.age_band, '-'),
                                            ' ' order by s.source_id collate "C") from cma.flash_subscriptions_of(v_t1, v_d) s)
             || ' | ' || (select string_agg(d.source_id || ':' || d.is_in_field || '/' || d.subscription_status, ' ' order by d.source_id collate "C")
                          from cma.flash_devices_of(v_t1, v_d) d where d.source_id in ('d-3', 'd-8', 'd-9', 'd-13'));
    v_rows := v_rows || array['15', 'B5 the active subscriptions'' ages on the snapshot''s own date (12 months exactly 12-24, a day short <12, none unknown); their sums; a holding one''s band; a device in stock in no device measure',
      case when v_txt = 'GB/12-24:1 GB/24-36:0 GB/36-48:0 GB/48-60:0 GB/60+:1 GB/<12:1 GB/unknown:1 NL/12-24:0 NL/24-36:1 NL/36-48:0 '
                        || 'NL/48-60:0 NL/60+:0 NL/<12:0 |  | GB/12-24:2 GB/24-36:0 GB/36-48:0 GB/48-60:0 GB/60+:1 GB/<12:0 GB/unknown:1 NL/12-24:0 NL/24-36:1 '
                        || 'NL/36-48:0 NL/48-60:0 NL/60+:0 NL/<12:0 | n-1:1/1/1/24-36 s-1:3/2/2/12-24 s-2:1/1/1/<12 s-3:0/0/0/unknown s-4:3/3/3+/60+ s-5:1/1/-/- s-6:1/1/-/- '
                        || 's-7:1/1/1/- | d-13:true/failed d-3:false/active d-8:true/paused d-9:true/canceled'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B6. the customers: the segment per market (a value in the setting, another case, outside it, empty, unlinked, a
    --     contact not held); active_customers the sum over segment; an empty setting: every customer unknown
    v_r := pg_temp.v0008zt_rows(v_t1, 'customers', v_d);
    v_txt := pg_temp.v0008zt_set(v_r, '{}', array['customers_held', 'active_customers', 'paused_customers'])
             || ' ' || pg_temp.v0008zt_set(v_r, array['market', 'segment'], array['customers_held', 'active_customers', 'paused_customers'])
             || ' | ' || pg_temp.v0008zt_unbalanced(v_r, 'active_customers', 'segment') || pg_temp.v0008zt_unbalanced(v_r, 'customers_held', 'segment')
             || ' | ' || (select string_agg(c.source_id || ':' || c.segment, ' ' order by c.source_id collate "C") from cma.flash_store_customers_of(v_t1) c);
    perform set_config('role', 'cma_app', true);
    perform cma.set_tenant_setting('crm.customer_segments', '');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || pg_temp.v0008zt_set(pg_temp.v0008zt_rows(v_t1, 'customers', v_d), array['market', 'segment'], array['customers_held', 'active_customers']);
    perform set_config('role', 'cma_app', true);
    perform cma.set_tenant_setting('crm.customer_segments', 'B2B,B2C');
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['16', 'B6 the customers'' segment (in the setting, another case, outside it, empty, unlinked, not held); active_customers their sum, per market too; an empty setting: all unknown',
      case when v_txt = ':7,4,1 GB/B2B:1,1,0 GB/B2C:1,1,0 GB/unknown:4,1,1 NL/B2B:1,1,0 |  | cu-1:B2B cu-2:B2C cu-3:unknown cu-4:unknown cu-5:unknown cu-6:unknown ncu-1:B2B '
                        || '| GB/unknown:6,3 NL/unknown:1,1'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B7. the snapshot: a take of 29 October, then nd-3 joins n-1 and the take of 30 October; each stored figure equals the
    --     computation as of 30 October (one code path) and the document as of that date; the run records the settings;
    --     devices_on_holding equals in_field_on_holding; the watch's jump never on the ratio
    insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status)
    select v_t1, c, 'reconcile', v_take_0 - interval '2 hours', v_take_0 - interval '1 hour', 'succeeded' from unnest(array[v_gb, v_nl, v_sgb, v_snl, v_reg, v_crm]) c;
    -- the watch at its most sensitive, so every count that moves is a jump (the ratio must still never be one)
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t1, 'flash.watch_jump_min', '0'), (v_t1, 'flash.watch_jump_pct', '1')
    on conflict (tenant_id, key) do update set value = excluded.value;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_sched1::text, true);
    j := cma.flash_snapshot_take_at(v_t1, v_take_0);
    v_txt := (j ->> 'taken') || ' ' || (j ->> 'date');
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, subscription_ref)
    values (v_t1, v_reg, 'verifyregister', 'nd-3', 'SN-nd-3', 'm1', 'NL', 'field', 'n-1');
    insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status)
    select v_t1, c, 'reconcile', v_take_1 - interval '2 hours', v_take_1 - interval '1 hour', 'succeeded' from unnest(array[v_gb, v_nl, v_sgb, v_snl, v_reg, v_crm]) c;
    j := cma.flash_snapshot_take_at(v_t1, v_take_1);
    v_txt := v_txt || ' ' || (j ->> 'taken') || ' ' || (j ->> 'date') || ' |';
    for o in select x.key from cma.flash_overviews() x where x.key in ('customers', 'subscriptions', 'installed_base') order by x.sort_order loop
      v_a := (select coalesce(jsonb_agg(jsonb_build_object('dims', s.dims, 'measures', s.measures) order by s.dims::text collate "C"), '[]'::jsonb)::text
              from cma.flash_snapshot s where s.tenant_id = v_t1 and s.snapshot_date = v_d and s.overview = o.key);
      v_b := pg_temp.v0008zt_rows(v_t1, o.key, v_d)::text;
      v_txt := v_txt || ' ' || o.key || ':' || (v_a = v_b)::text || ':'
               || (select string_agg(distinct s.definition_version, ',') from cma.flash_snapshot s where s.tenant_id = v_t1 and s.snapshot_date = v_d and s.overview = o.key);
    end loop;
    v_r := pg_temp.v0008zt_rows(v_t1, 'subscriptions', v_d);
    v_txt := v_txt || ' | ' || pg_temp.v0008zt_set(v_r, array['market'], array['active_subscriptions', 'holding_subscriptions', 'devices_on_holding', 'devices_per_holding_subscription'])
             || ' ' || ((select (s.measures ->> 'devices_on_holding') from cma.flash_snapshot s where s.tenant_id = v_t1 and s.snapshot_date = v_d and s.overview = 'subscriptions' and s.dims = '{}')
                        = (select (s.measures ->> 'in_field_on_holding') from cma.flash_snapshot s where s.tenant_id = v_t1 and s.snapshot_date = v_d and s.overview = 'installed_base' and s.dims = '{}'))::text
             || ' | ' || (select r.settings ->> 'flash.device_bands' || ' ' || (r.settings ->> 'flash.subscription_age_months') || ' ' || (r.settings ->> 'crm.customer_segments')
                                 || ' ' || (r.settings ->> 'flash.device_holding_statuses')
                          from cma.flash_snapshot_run r where r.tenant_id = v_t1 and r.snapshot_date = v_d and r.status = 'succeeded')
             || ' | ' || (select string_agg(f.overview || '/' || f.measure || '/' || (f.dims ->> 'market'), ' ' order by f.overview collate "C", f.measure collate "C")
                          from cma.flash_watch_finding f where f.tenant_id = v_t1 and f.state = 'open' and f.kind = 'jump');
    -- the document as of the date, as the analyst: the stored figures, the settings of the run
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.flash_overview('subscriptions', null, v_d);
    v_txt := v_txt || ' | ' || (j ->> 'mode') || ' ' || (j -> 'totals' ->> 'devices_per_holding_subscription') || ' ' || (j -> 'settings' -> 'device_bands')::text
             || ' ' || (j -> 'settings' -> 'subscription_age_months')::text || ' ' || (j -> 'settings' -> 'customer_segments')::text
             || ' ' || (select count(*) from jsonb_array_elements(j -> 'rows') x where x -> 'dims' ? 'age_band')
             || ' ' || coalesce(cma.flash_overview('subscriptions', 'FR', v_d) -> 'totals' ->> 'devices_per_holding_subscription', 'none')
             || ' ' || (cma.flash_overview('subscriptions', 'FR', v_d) -> 'totals' ->> 'active_subscriptions');
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['17', 'B7 the snapshot equals the computation as of its date (0008zt), the document as of it; devices_on_holding = in_field_on_holding; the run''s settings; no jump on the ratio',
      -- since 0008zu (138): customers and subscriptions stored under 0008zu
      case when v_txt = 'true 2026-10-29 true 2026-10-30 | customers:true:0008zu subscriptions:true:0008zu installed_base:true:0008zt | GB:4,5,7,1.40 NL:1,1,2,2.00 true '
                        || '| 1,2,3 12,24,36,48,60 B2B,B2C active,failed | installed_base/devices/NL installed_base/in_field/NL installed_base/in_field_on_holding/NL '
                        || 'subscriptions/devices_on_holding/NL | snapshot 1.50 [1, 2, 3] [12, 24, 36, 48, 60] ["B2B", "B2C"] 13 none 0'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B8. the lists, live, as the analyst: the new filters and measures; the subscriptions' devices_in_field adding up to the
    --     figure; the installed base's subscription status
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.flash_rows('subscriptions', '{"measure": "devices_on_holding"}', 'subscription_id', false, 500, 0);
    v_txt := (j ->> 'total') || ':' || (select sum((x ->> 'devices_in_field')::integer) from jsonb_array_elements(j -> 'rows') x)
             || ':' || (select string_agg((x ->> 'subscription_id') || '/' || (x ->> 'devices') || '/' || (x ->> 'devices_in_field'), ',') from jsonb_array_elements(j -> 'rows') x);
    j := cma.flash_rows('subscriptions', '{"device_band": "2", "market": "GB"}', 'subscription_id', false, 500, 0);
    v_txt := v_txt || ' ' || (select string_agg(x ->> 'subscription_id', ',') from jsonb_array_elements(j -> 'rows') x);
    j := cma.flash_rows('installed_base', '{"measure": "in_field_on_holding"}', 'serial', false, 500, 0);
    v_txt := v_txt || ' ' || (j ->> 'total');
    j := cma.flash_rows('installed_base', '{"subscription_status": "not_found"}', 'serial', false, 500, 0);
    v_txt := v_txt || ' ' || (select string_agg((x ->> 'device_id') || '/' || (x ->> 'subscription_status') || '/' || (x ->> 'link'), ',') from jsonb_array_elements(j -> 'rows') x);
    j := cma.flash_rows('customers', '{"segment": "B2B", "measure": "active_customers"}', 'customer_id', false, 500, 0);
    v_txt := v_txt || ' ' || (select string_agg(x ->> 'customer_id', ',') from jsonb_array_elements(j -> 'rows') x)
             || ' ' || pg_temp.v0008zt_code('select cma.flash_rows(''subscriptions'', ''{"measure": "devices_per_holding_subscription"}'')')
             || ' ' || pg_temp.v0008zt_code('select cma.flash_rows(''subscriptions'', ''{"segment": "B2B"}'')')
             || ' ' || (cma.flash_rows('subscriptions', '{"measure": "holding_subscriptions"}', 'subscription_id', false, 500, 0) ->> 'total');
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['18', 'B8 the lists: devices_on_holding''s records add up to it; the band, status and segment filters; holding_subscriptions; the ratio no list measure',
      case when v_txt = '5:9:n-1/2/2,s-1/3/2,s-2/1/1,s-4/3/3,s-7/1/1 s-1 9 d-10/not_found/not_found,nd-2/not_found/not_found cu-1,ncu-1 CMA04 CMA04 6'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B9. tenant isolation: tenant two's devices, subscriptions and contacts are in none of tenant one's figures, live as
    --     the application; and tenant two's own
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.flash_overview('subscriptions');
    v_txt := (j -> 'totals' ->> 'active_subscriptions') || ' ' || (j -> 'totals' ->> 'devices_on_holding');
    j := cma.flash_overview('installed_base');
    v_txt := v_txt || ' ' || (j -> 'totals' ->> 'devices') || ' ' || (j -> 'totals' ->> 'in_field_on_holding');
    j := cma.flash_overview('customers');
    v_txt := v_txt || ' ' || (select string_agg((x -> 'dims' ->> 'market') || '/' || (x -> 'dims' ->> 'segment') || ':' || (x -> 'measures' ->> 'customers_held'), ' '
                                                order by (x -> 'dims')::text collate "C")
                              from jsonb_array_elements(j -> 'rows') x where x -> 'dims' ? 'segment');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || pg_temp.v0008zt_set(pg_temp.v0008zt_rows(v_t2, 'subscriptions', null), '{}', array['active_subscriptions', 'devices_on_holding'])
             || ' ' || pg_temp.v0008zt_set(pg_temp.v0008zt_rows(v_t2, 'customers', null), array['market', 'segment'], array['customers_held']);
    v_rows := v_rows || array['19', 'B9 tenant isolation: a second tenant''s devices, subscriptions and contacts (the same ids) are never counted',
      case when v_txt = '5 9 16 9 GB/B2B:1 GB/B2C:1 GB/unknown:4 NL/B2B:1 | :1,5 GB/B2C:1' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B10. the ingest's segment (as the ingest user): trimmed, empty none, an @ none, over 100 characters none; a deletion
    --      clears it; the privacy deletion clears it; a contact marked deleted by anyone loses it; the check refuses an @
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, orders_count, crm_connection_id, crm_contact_source_id, matched_at)
    select v_t1, v_gb, 'verifyshop', 'cu-1' || g, 0, v_crm, 'c-1' || g, now() from generate_series(1, 6) g;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_ingest1::text, true);
    select string_agg(x.source_id || ':' || x.outcome, ' ' order by x.source_id collate "C") into v_txt
    from cma.ingest_upsert_contacts(v_crm, jsonb_build_array(
      jsonb_build_object('sourceId', 'c-11', 'country', 'GB', 'segment', '  B2B  '),
      jsonb_build_object('sourceId', 'c-12', 'country', 'GB', 'segment', ''),
      jsonb_build_object('sourceId', 'c-13', 'country', 'GB', 'segment', 'someone@example.invalid'),
      jsonb_build_object('sourceId', 'c-14', 'country', 'GB', 'segment', repeat('x', 101)),
      jsonb_build_object('sourceId', 'c-15', 'country', 'GB', 'segment', 'B2C'),
      jsonb_build_object('sourceId', 'c-16', 'country', 'GB', 'segment', 'B2C'))) x;
    perform cma.ingest_upsert_contacts(v_crm, jsonb_build_array(jsonb_build_object('sourceId', 'c-15', 'deletedAt', now())));
    perform cma.ingest_contact_forget(v_crm, 'c-16');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || (select string_agg(k.source_id || ':' || coalesce(k.segment, 'none'), ' ' order by k.source_id collate "C") from cma.crm_contact k
                                where k.tenant_id = v_t1 and k.source_id like 'c-1_');
    update cma.crm_contact k set source_deleted_at = now() where k.tenant_id = v_t1 and k.source_id = 'c-1';
    v_txt := v_txt || ' | ' || coalesce((select k.segment from cma.crm_contact k where k.tenant_id = v_t1 and k.source_id = 'c-1'), 'none')
             || ' ' || pg_temp.v0008zt_code(format('insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, segment) values (%L, %L, ''verifycrm'', ''c-99'', ''a@b'')', v_t1, v_crm))
             || ' ' || pg_temp.v0008zt_code(format('insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, segment) values (%L, %L, ''verifycrm'', ''c-98'', '''')', v_t1, v_crm));
    v_rows := v_rows || array['20', 'B10 the ingest''s segment: trimmed; empty, an @ or over 100 characters none; a deletion and the privacy deletion clear it; the checks',
      case when v_txt = 'c-11:inserted c-12:inserted c-13:inserted c-14:inserted c-15:inserted c-16:inserted | c-11:B2B c-12:none c-13:none c-14:none c-15:none c-16:none '
                        || '| none 23514 23514'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B11. the live ages in the tenant's zone (tenant three, relative to its today): exactly 12 months before today
    --      12-24; created at 00:30 in the tenant's zone a day later (still the day before in UTC) <12; 61 months 60+; none
    --      unknown; the list's age filter, as the application
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values (v_t3, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 10);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t3, 'verifyshop', 'Shop three', 'shop-3.shop.example', 'commerce') returning id into v_gb3;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t3, 'verifysubs', 'Subs three', 'shop-3.shop.example', 'subscriptions', 'verify-subs-three') returning id into v_sgb3;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values (v_t3, v_gb3, 'shop-3', 'Shop three', 'NL', 'EUR', 'Europe/Amsterdam');
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, amount_per_cycle, currency, source_created_at) values
      (v_t3, v_sgb3, 'verifysubs', 'x-1', 'cx-1', 'active', 10.00, 'EUR', ((v_today3 - interval '12 months')::date + time '00:15') at time zone 'Europe/Amsterdam'),
      (v_t3, v_sgb3, 'verifysubs', 'x-2', 'cx-2', 'active', 10.00, 'EUR', ((v_today3 - interval '12 months')::date + 1 + time '00:30') at time zone 'Europe/Amsterdam'),
      (v_t3, v_sgb3, 'verifysubs', 'x-3', 'cx-3', 'active', 10.00, 'EUR', ((v_today3 - interval '61 months')::date + time '12:00') at time zone 'Europe/Amsterdam'),
      (v_t3, v_sgb3, 'verifysubs', 'x-4', 'cx-4', 'active', 10.00, 'EUR', null),
      (v_t3, v_sgb3, 'verifysubs', 'x-5', 'cx-5', 'canceled', 10.00, 'EUR', ((v_today3 - interval '2 months')::date + time '12:00') at time zone 'Europe/Amsterdam');
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t3::text, true);
    perform set_config('app.user_id', v_analyst3::text, true);
    j := cma.flash_overview('subscriptions');
    v_txt := (select string_agg((x -> 'dims' ->> 'age_band') || ':' || (x -> 'measures' ->> 'active_subscriptions'), ' ' order by x -> 'dims' ->> 'age_band' collate "C")
              from jsonb_array_elements(j -> 'rows') x where x -> 'dims' ? 'age_band')
             || ' | ' || coalesce(j -> 'totals' ->> 'devices_per_holding_subscription', 'none') || ' ' || (j -> 'totals' ->> 'devices_on_holding')
             || ' | ' || (select string_agg(x ->> 'subscription_id', ',') from jsonb_array_elements(cma.flash_rows('subscriptions', '{"age_band": "<12"}') -> 'rows') x)
             || ' ' || (select string_agg(x ->> 'subscription_id', ',') from jsonb_array_elements(cma.flash_rows('subscriptions', '{"age_band": "12-24"}') -> 'rows') x);
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['21', 'B11 the live ages in the tenant''s zone: 12 months to the day 12-24, a day short <12 (00:30 local, the day before in UTC), 60+, unknown; the list''s age filter',
      case when v_txt = '12-24:1 24-36:0 36-48:0 48-60:0 60+:1 <12:1 unknown:1 | 0.00 0 | x-2 x-1' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B12. data quality (live, tenant one): a device on the paused s-5 is the new finding, the one on the canceled s-6 the
    --      ended check's alone (no device twice); a holding subscription without a device is a finding, a failed one too
    --      once its device is gone
    perform set_config('role', 'cma_owner', true);
    v_txt := (select string_agg(q.check_key || ':' || q.object_id || ':' || coalesce(q.value, '-'), ' ' order by q.check_key collate "C", q.object_id collate "C")
              from cma.data_quality_of(v_t1) q
              where q.check_key in ('field_device_on_non_holding_subscription', 'field_device_on_ended_subscription', 'active_subscription_without_device'));
    update cma.device d set source_deleted_at = now() where d.tenant_id = v_t1 and d.source_id = 'd-13';
    v_txt := v_txt || ' | ' || (select string_agg(q.object_id || ':' || q.value, ' ' order by q.object_id collate "C") from cma.data_quality_of(v_t1) q
                                where q.check_key = 'active_subscription_without_device');
    v_rows := v_rows || array['22', 'B12 data quality: a device on a paused subscription a finding, one on a canceled one the ended check''s alone; a holding subscription without a device, a failed one too',
      case when v_txt = 'active_subscription_without_device:s-3:active field_device_on_ended_subscription:d-9:canceled field_device_on_non_holding_subscription:d-8:paused '
                        || '| s-3:active s-7:failed'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B13. the hints' settings, as the application: the landing (cma.flash_page) and an overview give the active, holding
    --      and ended statuses and the tenant's meanings; a tenant without meanings gets none, never another tenant's
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.flash_page();
    v_txt := (j -> 'settings' -> 'active_subscription_statuses')::text || ' ' || (j -> 'settings' -> 'device_holding_statuses')::text
             || ' ' || (j -> 'settings' -> 'ended_subscription_statuses')::text || ' ' || (j -> 'settings' -> 'status_meanings' -> 'active' ->> 'nl')
             || ' ' || coalesce(j -> 'settings' -> 'status_meanings' -> 'failed' ->> 'nl', 'none');
    j := cma.flash_overview('installed_base');
    v_txt := v_txt || ' | ' || (j -> 'settings' -> 'device_holding_statuses')::text || ' ' || (j -> 'settings' -> 'status_meanings' -> 'failed' ->> 'en');
    perform set_config('app.tenant_id', v_t3::text, true);
    perform set_config('app.user_id', v_analyst3::text, true);
    j := cma.flash_page();
    v_txt := v_txt || ' | ' || (j -> 'settings' -> 'device_holding_statuses')::text || ' ' || (j -> 'settings' -> 'status_meanings')::text
             || ' ' || (cma.flash_overview('subscriptions') -> 'settings' -> 'status_meanings')::text;
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['23', 'B13 the hints'' settings on the landing and an overview: the tenant''s statuses and meanings; a tenant without meanings none, never another''s',
      case when v_txt = '["active"] ["active", "failed"] ["canceled", "expired"] Eén apparaat. none | ["active", "failed"] Unpaid; devices stay. | ["active"] {} {}'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['29', 'B the block ran to the end', 'FAIL', sqlstate || ' ' || sqlerrm];
  end;
  insert into verify_0008zt (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zt values (29, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- S. Seed 02's values for Pulse4all Subscriptions: its CRM connection (adapter hubspot) maps contact segment to
--    customer_type, and crm.customer_segments is B2B,B2C. Skip where the tenant has no active hubspot connection (a
--    database without Pulse4all's connections)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_subs    uuid := (select t.id from cma.tenant t where t.slug = 'pulse4all-subscriptions');
  v_txt     text;
begin
  if v_subs is null or not exists (select 1 from cma.integration_connection c where c.tenant_id = v_subs and c.adapter = 'hubspot' and c.status = 'active') then
    insert into verify_0008zt values (31, 'S1 seed 02: Pulse4all Subscriptions maps contact segment to customer_type; segments B2B,B2C; active and failed hold devices; five meanings', 'skip',
      'no active hubspot connection of pulse4all-subscriptions: not checked here');
    return;
  end if;
  v_txt := (select string_agg(c.name || ':' || coalesce(f.source_property, 'none') || ':' || coalesce(f.slot::text, '-'), ' ' order by c.name collate "C")
            from cma.integration_connection c
            left join cma.connection_field f on f.tenant_id = c.tenant_id and f.connection_id = c.id and f.entity = 'contact' and f.field = 'segment'
            where c.tenant_id = v_subs and c.adapter = 'hubspot' and c.status = 'active')
           || ' | ' || cma.setting_of(v_subs, 'crm.customer_segments') || ' ' || cma.setting_of(v_subs, 'flash.device_holding_statuses')
           || ' ' || coalesce((select string_agg(k, ',' order by k collate "C") from jsonb_object_keys(cma.setting_of(v_subs, 'subscription.status_meanings')::jsonb) k), '-');
  insert into verify_0008zt values (31, 'S1 seed 02: Pulse4all Subscriptions maps contact segment to customer_type; segments B2B,B2C; active and failed hold devices; five meanings',
    case when v_txt ~ ':customer_type:1( |$)' and v_txt !~ ':none:' and v_txt ~ '\| B2B,B2C active,failed active,canceled,expired,failed,paused$' and not v_provoke then 'ok' else 'FAIL' end, v_txt);
end
$$;

-- D. Every tenant's own figures, live, read only: the reconciliations add up, in all and per market
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  t         record;
  v_r       jsonb;
  v_bad     text;
  v_n       integer;
begin
  -- D1. the installed base: in_field and devices the sums over subscription_status, in_field_on_holding the in_field of the
  --     holding statuses
  v_bad := ''; v_n := 0;
  for t in select x.id, x.slug from cma.tenant x where coalesce((cma.flash_sources_of(x.id) -> 'assets' ->> 'set_up')::boolean, false) order by x.slug loop
    v_n := v_n + 1;
    v_r := pg_temp.v0008zt_rows(t.id, 'installed_base', null);
    v_bad := v_bad || pg_temp.v0008zt_unbalanced(v_r, 'in_field', 'subscription_status') || pg_temp.v0008zt_unbalanced(v_r, 'devices', 'subscription_status')
             || pg_temp.v0008zt_unbalanced(v_r, 'in_field_on_holding', 'subscription_status') || pg_temp.v0008zt_holding_bad(v_r, cma.flash_holding_statuses_of(t.id));
  end loop;
  insert into verify_0008zt values (41, 'D1 every tenant''s installed base: in_field, devices the sums over subscription_status; in_field_on_holding the holding statuses'' in_field; per market too',
    case when v_n = 0 then 'skip' when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end,
    case when v_n = 0 then 'no tenant with an asset register set up' else v_n || ' tenant(s) ' || v_bad end);

  -- D2. the subscriptions: holding_subscriptions and devices_on_holding the sums over device_band, active_subscriptions over
  --     age_band; the ratio
  v_bad := ''; v_n := 0;
  for t in select x.id, x.slug from cma.tenant x where coalesce((cma.flash_sources_of(x.id) -> 'subscriptions' ->> 'set_up')::boolean, false) order by x.slug loop
    v_n := v_n + 1;
    v_r := pg_temp.v0008zt_rows(t.id, 'subscriptions', null);
    v_bad := v_bad || pg_temp.v0008zt_unbalanced(v_r, 'holding_subscriptions', 'device_band') || pg_temp.v0008zt_unbalanced(v_r, 'active_subscriptions', 'age_band')
             || pg_temp.v0008zt_unbalanced(v_r, 'devices_on_holding', 'device_band') || pg_temp.v0008zt_ratio_bad(v_r);
  end loop;
  insert into verify_0008zt values (42, 'D2 every tenant''s subscriptions: holding_subscriptions and devices_on_holding the sums over device_band, active_subscriptions over age_band, the ratio to two decimals, none at 0',
    case when v_n = 0 then 'skip' when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end,
    case when v_n = 0 then 'no tenant with a subscriptions connection set up' else v_n || ' tenant(s) ' || v_bad end);

  -- D3. the customers: active_customers and customers_held the sums over segment
  v_bad := ''; v_n := 0;
  for t in select x.id, x.slug from cma.tenant x where coalesce((cma.flash_sources_of(x.id) -> 'commerce' ->> 'set_up')::boolean, false) order by x.slug loop
    v_n := v_n + 1;
    v_r := pg_temp.v0008zt_rows(t.id, 'customers', null);
    v_bad := v_bad || pg_temp.v0008zt_unbalanced(v_r, 'active_customers', 'segment') || pg_temp.v0008zt_unbalanced(v_r, 'customers_held', 'segment');
  end loop;
  insert into verify_0008zt values (43, 'D3 every tenant''s customers: active_customers and customers_held the sums over segment, per market too',
    case when v_n = 0 then 'skip' when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end,
    case when v_n = 0 then 'no tenant with a store set up' else v_n || ' tenant(s) ' || v_bad end);
end
$$;

-- C. Speed at volume (rolled back; local databases only, with verify.volume 'true' at the top): 0008zn's volume of store
--    customers, subscriptions and devices, with segments, creation times and device statuses; the three overviews live,
--    as the application, each the best of two. The volume's audit triggers are disabled inside the block (an exclusive
--    lock on those tables until the rollback, which enables them again)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_max_o   numeric := current_setting('verify.max_overview_ms')::numeric;
  v_rows    text[] := '{}';
  v_t uuid; v_analyst uuid;
  v_crm uuid; v_gb uuid; v_nl uuid; v_sgb uuid; v_snl uuid; v_reg uuid;
  v_ov text; v_ms numeric; v_best numeric; v_t0 timestamptz; v_txt text := ''; v_bad text := '';
  j jsonb;
begin
  if not current_setting('verify.volume')::boolean then
    insert into verify_0008zt values (51, 'C1 the three overviews live at volume, as the application, under verify.max_overview_ms', 'skip', 'not run: volume off');
    return;
  end if;
  begin
    perform set_config('lock_timeout', '10s', true);
    alter table cma.commerce_customer disable trigger audit;
    alter table cma.crm_contact disable trigger audit;
    alter table cma.subscription disable trigger audit;
    alter table cma.device disable trigger audit;
    perform set_config('lock_timeout', '0', true);
    v_t := cma.create_tenant('verify-0008zt-volume', 'Verify 0008zt volume', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-analyst-volume@example.invalid', 'analyst') returning id into v_analyst;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_analyst, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'analytics';
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
      (v_t, 'GB', 'GB', 'Europe/London', 'en', 'GBP', 10), (v_t, 'NL', 'NL', 'Europe/Amsterdam', 'nl', 'EUR', 20);
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'crm.customer_segments', 'B2B,B2C');
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t, 'verifycrm', 'CRM', 'portal-v', 'crm') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t, 'verifyshop', 'Shop GB', 'vol-gb.shop.example', 'commerce') returning id into v_gb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t, 'verifyshop', 'Shop NL', 'vol-nl.shop.example', 'commerce') returning id into v_nl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t, 'verifysubs', 'Subs GB', 'vol-gb.shop.example', 'subscriptions') returning id into v_sgb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t, 'verifysubs', 'Subs NL', 'vol-nl.shop.example', 'subscriptions') returning id into v_snl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t, 'verifyregister', 'Register', 'base-v', 'assets') returning id into v_reg;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values
      (v_t, v_gb, 'vol-gb', 'GB', 'GB', 'GBP', 'Europe/London'), (v_t, v_nl, 'vol-nl', 'NL', 'NL', 'EUR', 'Europe/Amsterdam');
    -- 100,000 store customers, a third linked to a contact, half of those held with a segment (B2B, b2c, Retail or none)
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, orders_count, crm_connection_id, crm_contact_source_id, matched_at)
    select v_t, case when g % 2 = 0 then v_gb else v_nl end, 'verifyshop', 'cu-' || g, g % 7,
           case when g % 3 = 0 then v_crm end, case when g % 3 = 0 then 'c-' || g end, case when g % 3 = 0 then now() end
    from generate_series(1, 100000) g;
    analyze cma.commerce_customer;
    insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, segment)
    select v_t, v_crm, 'verifycrm', 'c-' || g, case when g % 2 = 0 then 'GB' else 'NL' end, (array['B2B', 'b2c', 'Retail', null])[1 + (g / 6) % 4]
    from generate_series(6, 100000, 6) g;
    analyze cma.crm_contact;
    -- 100,000 subscriptions, one per customer, created over six years
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, amount_per_cycle, currency,
                                  billing_interval, billing_interval_count, paused_at, source_created_at)
    select v_t, case when g % 2 = 0 then v_sgb else v_snl end, 'verifysubs', 's-' || g, 'cu-' || g,
           (array['active', 'active', 'active', 'active', 'active', 'active', 'paused', 'canceled', 'expired', 'failed'])[1 + g % 10],
           10 + g % 30, case when g % 2 = 0 then 'GBP' else 'EUR' end, 'month', 1, case when g % 10 = 6 then now() end,
           case when g % 50 <> 0 then now() - make_interval(days => g % 2200) end
    from generate_series(1, 100000) g;
    analyze cma.subscription;
    -- 50,000 devices in the field (with a subscription reference, some two on one subscription) or in stock
    insert into cma.device_model (tenant_id, key, name) values (v_t, 'm1', 'M1');
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked) values
      (v_t, 'field', 'Field', true, false, true), (v_t, 'stock', 'Stock', false, true, true);
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, customer_ref, subscription_ref, first_shipped_on)
    select v_t, v_reg, 'verifyregister', 'rec-' || g, 'SN-' || g, 'm1', case when (g % 40000) % 2 = 0 then 'GB' else 'NL' end,
           case when g % 5 = 0 then 'stock' else 'field' end, 'cu-' || (g % 40000), case when g % 7 <> 0 then 's-' || (g % 40000) end, date '2023-01-01' + (g % 1000)
    from generate_series(1, 50000) g;
    analyze cma.device;

    -- C1. the three overviews live, as the application, each the best of two
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_analyst::text, true);
    foreach v_ov in array array['customers', 'subscriptions', 'installed_base'] loop
      v_best := null;
      for i in 1 .. 2 loop
        v_t0 := clock_timestamp();
        j := cma.flash_overview(v_ov);
        v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
        v_best := least(coalesce(v_best, v_ms), v_ms);
      end loop;
      v_txt := v_txt || v_ov || ' ' || v_best || ' ms; ';
      if v_best >= v_max_o then v_bad := v_bad || v_ov || '; '; end if;
    end loop;
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['51', 'C1 the three overviews live at volume, as the application, under verify.max_overview_ms',
      case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_txt || case when v_bad <> '' then ' | over: ' || v_bad else '' end];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'C the block ran to the end', 'FAIL', sqlstate || ' ' || sqlerrm];
  end;
  insert into verify_0008zt (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- Block C analysed its volume inside its transaction; after a run with the volume on, the tables are analysed again, so
-- their statistics are their own (nothing is analysed when block C did not run)
do $$
begin
  if current_setting('verify.volume')::boolean then
    analyze cma.commerce_customer, cma.crm_contact, cma.subscription, cma.device;
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0008zt_code(text);
drop function if exists pg_temp.v0008zt_rows(uuid, text, date);
drop function if exists pg_temp.v0008zt_set(jsonb, text[], text[]);
drop function if exists pg_temp.v0008zt_unbalanced(jsonb, text, text);
drop function if exists pg_temp.v0008zt_ratio_bad(jsonb);
drop function if exists pg_temp.v0008zt_holding_bad(jsonb, text[]);

-- Verdict: one row per check, then the verdict: no FAIL, and a skip only where the check says why (the volume off; no
-- Pulse4all CRM connection; no tenant with the source set up)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zt
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from verify_0008zt where result not in ('ok', 'skip')) then 'FAIL'
                  when (select count(*) from verify_0008zt where result = 'ok') >= 20 then '0008zt verified'
                  else 'FAIL' end,
             format('137_verify_flash_insights: %s ok, %s FAIL, %s skip', (select count(*) from verify_0008zt where result = 'ok'),
                    (select count(*) from verify_0008zt where result not in ('ok', 'skip')),
                    (select count(*) from verify_0008zt where result = 'skip'))) x
order by ord;
reset role;
