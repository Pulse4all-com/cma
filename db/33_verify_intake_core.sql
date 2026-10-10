-- =============================================================================================
-- 33_verify_intake_core.sql: verifies migration 0007, intake core
-- =============================================================================================
-- Block A checks structure and privileges; blocks B to F each work on two throwaway tenants inside
-- a subtransaction that is always rolled back. All universal: no seed is assumed. Cloud SQL Studio
-- shows no notices: a check that fails raises "FAIL …" and stops the block. The last result is the
-- verdict. Run as your own IAM login, dev and prod, after 32_intake_core.sql; then
-- 31_verify_ingest_crm_records.sql again.
--   A  structure and privileges: tables, RLS, audit, no deletes, column privileges, functions,
--      views without raw, hashes, keys or secret names, the 0006 columns, the settings
--   B  markets, aliases, office hours, holidays, business seconds and the next business noon,
--      the date setting
--   C  the 0006 extensions: connection settings, field mapping with slots, records with amount,
--      currency, channel and category, contacts with currency, store and two ref slots, lead
--      pipelines
--   D  CRM calls, associations, call outcomes
--   E  forms and submissions, cursors, sync runs, the privacy deletion
--   F  permissions (configuration versus ingest), people's ids in other systems, tenant isolation
--      for every new table, no deletes
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict
-- (reached only when the run does not stop on errors) says PROVOKED instead of PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every block fail

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t       text;
  v_fn      text;
  v_n       int;
  v_cols    text;
begin
  -- A1. the migration is recorded
  if not exists (select 1 from cma.schema_migration where version = '0007') or v_provoke then
    raise exception 'FAIL A1: migration 0007 not recorded';
  end if;

  -- A2. eleven tenant tables, each with row-level security, the tenant policy and the audit trigger
  foreach v_t in array array['market', 'market_alias', 'business_hours', 'business_holiday', 'crm_call',
                             'connection_call_outcome', 'crm_association', 'connection_form', 'form_submission',
                             'sync_cursor', 'sync_run'] loop
    if to_regclass('cma.' || v_t) is null then
      raise exception 'FAIL A2: table cma.% is missing', v_t;
    end if;
    if not (select relrowsecurity from pg_class where oid = to_regclass('cma.' || v_t))
       or not exists (select 1 from pg_policy where polrelid = to_regclass('cma.' || v_t) and polname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = to_regclass('cma.' || v_t) and tgname = 'audit') then
      raise exception 'FAIL A2: cma.% lacks row-level security, its tenant policy or its audit trigger', v_t;
    end if;
  end loop;

  -- A3. the app inserts but never deletes, except the mapping rows; a submission and a run change
  --     only in their outcome columns
  foreach v_t in array array['market', 'crm_call', 'connection_call_outcome', 'crm_association', 'connection_form',
                             'form_submission', 'sync_cursor', 'sync_run'] loop
    if has_table_privilege('cma_app', 'cma.' || v_t, 'delete') or not has_table_privilege('cma_app', 'cma.' || v_t, 'insert') then
      raise exception 'FAIL A3: cma_app must insert into and never delete from cma.%', v_t;
    end if;
  end loop;
  foreach v_t in array array['market_alias', 'business_hours', 'business_holiday', 'crm_contact_ref'] loop
    if not has_table_privilege('cma_app', 'cma.' || v_t, 'delete') then
      raise exception 'FAIL A3: cma_app must be able to remove rows of the mapping table cma.%', v_t;
    end if;
  end loop;
  if has_table_privilege('cma_app', 'cma.form_submission', 'update')
     or has_column_privilege('cma_app', 'cma.form_submission', 'submitted_at', 'update')
     or has_column_privilege('cma_app', 'cma.form_submission', 'utm', 'update')
     or not has_column_privilege('cma_app', 'cma.form_submission', 'contact_resolution', 'update')
     or has_table_privilege('cma_app', 'cma.sync_run', 'update')
     or has_column_privilege('cma_app', 'cma.sync_run', 'job', 'update')
     or not has_column_privilege('cma_app', 'cma.sync_run', 'status', 'update') then
    raise exception 'FAIL A3: form_submission and sync_run must be updatable in their outcome columns only';
  end if;

  -- A4. the functions: the app may execute them, readers and public may not; none runs as its owner
  foreach v_fn in array array[
    'cma.normalize_market(text)', 'cma.business_seconds(text,timestamptz,timestamptz)',
    'cma.next_business_noon(text,timestamptz)',
    'cma.upsert_market(text,text,text,text,text,text,smallint,integer)', 'cma.set_market_status(text,text)',
    'cma.set_market_alias(text,text)', 'cma.remove_market_alias(text)', 'cma.set_business_hours(text,smallint,text)',
    'cma.set_business_holiday(text,date,text)', 'cma.remove_business_holiday(text,date)',
    'cma.set_connection_settings(uuid,jsonb)', 'cma.set_connection_field(uuid,text,text,text,text)',
    'cma.set_connection_field(uuid,text,text,text,text,smallint)', 'cma.set_pipeline_lead(uuid,text,text,boolean)',
    'cma.set_form(uuid,text,boolean,text,text,text[])', 'cma.set_call_outcome(uuid,text,boolean)',
    'cma.set_user_external_id(uuid,text,text)', 'cma.remove_user_external_id(uuid,text)', 'cma.connection_config(uuid)',
    'cma.ingest_upsert_records(uuid,jsonb)', 'cma.ingest_upsert_contacts(uuid,jsonb)', 'cma.ingest_upsert_calls(uuid,jsonb)',
    'cma.ingest_upsert_associations(uuid,jsonb)', 'cma.ingest_upsert_call_outcomes(uuid,jsonb)',
    'cma.ingest_upsert_forms(uuid,jsonb)', 'cma.ingest_upsert_form_submissions(uuid,jsonb)',
    'cma.ingest_cursor_get(uuid,text)', 'cma.ingest_cursor_set(uuid,text,jsonb)',
    'cma.ingest_sync_run_start(uuid,text,text,timestamptz,timestamptz)', 'cma.ingest_sync_run_finish(uuid,text,jsonb,text)',
    'cma.ingest_contact_forget(uuid,text)'
  ] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A4: % does not exist', v_fn;
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute')
       or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      raise exception 'FAIL A4: execute on % must be granted to cma_app only', v_fn;
    end if;
    if (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      raise exception 'FAIL A4: % must run with the caller''s rights', v_fn;
    end if;
  end loop;

  -- A5. reporting views: readers see each view and never the table; no raw payload, hash, cursor,
  --     key or secret name in any view of this migration; the companion view of crm_record
  foreach v_t in array array['market', 'market_alias', 'business_hours', 'business_holiday', 'crm_call',
                             'connection_call_outcome', 'crm_association', 'connection_form', 'form_submission', 'sync_run'] loop
    if not has_table_privilege('cma_readonly', 'cma_read.' || v_t, 'select') or has_table_privilege('cma_readonly', 'cma.' || v_t, 'select') then
      raise exception 'FAIL A5: readers must see cma_read.% and not cma.%', v_t, v_t;
    end if;
  end loop;
  if has_table_privilege('cma_readonly', 'cma.sync_cursor', 'select') or to_regclass('cma_read.sync_cursor') is not null then
    raise exception 'FAIL A5: sync cursors are internal and have no reporting view';
  end if;
  select string_agg(table_name || '.' || column_name, ', ') into v_cols
  from information_schema.columns
  where table_schema = 'cma_read'
    and table_name in ('market', 'market_alias', 'business_hours', 'business_holiday', 'crm_call', 'connection_call_outcome',
                       'crm_association', 'connection_form', 'form_submission', 'sync_run', 'crm_record_detail',
                       'crm_contact', 'crm_contact_ref', 'connection_pipeline', 'integration_connection')
    and (column_name in ('raw', 'counterpart_hash', 'cursor', 'key', 'settings', 'signing_secret_name', 'token_secret_name')
         or column_name like '%secret%' or column_name like '%token%');
  if v_cols is not null then
    raise exception 'FAIL A5: reporting views expose %', v_cols;
  end if;
  select string_agg(column_name, ', ' order by ordinal_position) into v_cols
  from information_schema.columns where table_schema = 'cma_read' and table_name = 'crm_call';
  if v_cols is distinct from 'id, tenant_id, connection_id, source_system, source_id, occurred_at, direction, status, outcome_ref, duration_seconds, owner_ref, source_app, source_created_at, source_updated_at, source_deleted_at, synced_at' then
    raise exception 'FAIL A5: cma_read.crm_call exposes [%]', v_cols;
  end if;
  select count(*) into v_n from information_schema.columns
  where table_schema = 'cma_read'
    and ((table_name = 'crm_record_detail' and column_name in ('amount', 'currency', 'source_channel', 'category'))
      or (table_name = 'crm_contact' and column_name in ('currency', 'store'))
      or (table_name = 'crm_contact_ref' and column_name = 'slot')
      or (table_name = 'connection_pipeline' and column_name = 'is_lead'));
  if v_n <> 8 or not has_table_privilege('cma_readonly', 'cma_read.crm_record_detail', 'select') then
    raise exception 'FAIL A5: the new record, contact, ref and pipeline columns are not all in the reporting views (% of 8)', v_n;
  end if;

  -- A6. the 0006 tables carry the new columns and keys
  select count(*) into v_n from information_schema.columns
  where table_schema = 'cma'
    and ((table_name = 'integration_connection' and column_name = 'settings')
      or (table_name = 'connection_field' and column_name = 'slot')
      or (table_name = 'crm_contact_ref' and column_name = 'slot')
      or (table_name = 'crm_contact' and column_name in ('currency', 'store'))
      or (table_name = 'crm_record' and column_name in ('amount', 'currency', 'source_channel', 'category'))
      or (table_name = 'connection_pipeline' and column_name = 'is_lead'));
  if v_n <> 10
     or pg_get_constraintdef((select oid from pg_constraint where conrelid = 'cma.connection_field'::regclass and contype = 'p')) not like '%slot%'
     or pg_get_constraintdef((select oid from pg_constraint where conrelid = 'cma.crm_contact_ref'::regclass and contype = 'p')) not like '%slot%' then
    raise exception 'FAIL A6: % of 10 new columns, or a key without the slot', v_n;
  end if;

  -- A7. the settings with their types and defaults
  select count(*) into v_n from cma.setting s
  join (values ('intake.start_date', 'date', '2026-10-01'), ('speed_to_lead.pre_window_minutes', 'integer', '0'),
               ('speed_to_lead.target_minutes', 'integer', '60'), ('lead_to_order.max_days', 'integer', '90'),
               ('forms.deal_window_hours', 'integer', '72'), ('commerce.renewal_source_names', 'text', ''),
               ('commerce.renewal_app_ids', 'text', ''), ('alerts.max_age_minutes', 'integer', '60')) as x(key, type, def)
    on x.key = s.key and x.type = s.value_type and x.def = s.default_value;
  if v_n <> 8 then
    raise exception 'FAIL A7: % of 8 intake settings with the right type and default', v_n;
  end if;
end
$$;

-- B. Markets, aliases, office hours, holidays and business time (throwaway tenants, rolled back)
--    Tenant one (zone Europe/Amsterdam): NL and DE; default hours Mon to Fri 09:00 to 17:00; DE
--    with hours of its own (Sunday all day, so the 25-hour day of 25 October 2026 shows); a holiday.
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_agent    uuid;
  v_n        int;
  v_txt      text;
  v_at       timestamptz;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007-one', 'Verify 0007 one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0007-two', 'Verify 0007 two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id from (values (v_admin, 'admin'), (v_agent, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.skill (tenant_id, dimension, key, name) values (v_t1, 'language', 'verify-dutch', 'Verify Dutch');

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);

    -- B1. markets: NL with its language skill and level; refusals for UK, a lower-case code, an
    --     unknown zone, an unknown skill and a level off the scale
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 'verify-dutch', 3::smallint, 20);
    perform cma.upsert_market('DE', 'Germany', 'Europe/Berlin', 'de', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', null, null, 10);
    perform cma.upsert_market('NL', 'The Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 'verify-dutch', 3::smallint, 20);
    select count(*) into v_n from cma.market where tenant_id = v_t1;
    if v_n <> 3 or (select name from cma.market where code = 'NL') <> 'The Netherlands'
       or (select min_language_level from cma.market where code = 'NL') <> 3 or v_provoke then
      raise exception 'FAIL B1: % markets after four upserts', v_n;
    end if;
    begin
      perform cma.upsert_market('UK', 'United Kingdom', 'Europe/London', 'en', 'GBP');
      raise exception 'FAIL B1: UK was accepted as a market code';
    exception when sqlstate 'CMA04' then
      get stacked diagnostics v_txt = message_text;
      if v_txt not like '%use GB%' then
        raise exception 'FAIL B1: UK was refused without "use GB": %', v_txt;
      end if;
    end;
    begin
      perform cma.upsert_market('fr', 'France', 'Europe/Paris', 'fr', 'EUR');
      raise exception 'FAIL B1: a lower-case code was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.upsert_market('FR', 'France', 'Europe/Atlantis', 'fr', 'EUR');
      raise exception 'FAIL B1: an unknown time zone was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.upsert_market('FR', 'France', 'Europe/Paris', 'fr', 'EUR', 'no-such-language', 2::smallint);
      raise exception 'FAIL B1: an unknown language skill was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    begin
      perform cma.upsert_market('FR', 'France', 'Europe/Paris', 'fr', 'EUR', 'verify-dutch', 7::smallint);
      raise exception 'FAIL B1: a level off the language scale was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    perform cma.set_market_status('GB', 'inactive');
    if (select status from cma.market where code = 'GB') <> 'inactive' then
      raise exception 'FAIL B1: the market status did not change';
    end if;

    -- B2. aliases: normalisation through an alias, a known code, an unknown value, empty; an alias to
    --     an unknown market is refused; an alias can be removed
    perform cma.set_market_alias(' United Kingdom ', 'GB');
    perform cma.set_market_alias('uk', 'GB');
    perform cma.set_market_alias('nederland', 'NL');
    select string_agg(coalesce(cma.normalize_market(v), '∅'), ',' order by o) into v_txt
    from (values (1, 'united kingdom'), (2, 'UK'), (3, ' Nederland '), (4, 'nl'), (5, 'de'), (6, ' Atlantis '), (7, ''), (8, null)) as x(o, v);
    if v_txt is distinct from 'GB,GB,NL,NL,DE,Atlantis,∅,∅' then
      raise exception 'FAIL B2: normalisation gave %', v_txt;
    end if;
    begin
      perform cma.set_market_alias('atlantis', 'AX');
      raise exception 'FAIL B2: an alias to an unknown market was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    perform cma.remove_market_alias('UK');
    if cma.normalize_market('uk') <> 'uk' then
      raise exception 'FAIL B2: a removed alias still normalises';
    end if;

    -- B3. office hours: the default week, DE's own Sunday; refusals for an overlap, a bad range and a
    --     range closing before it opens; '' closes a day; holidays
    perform cma.set_business_hours('*', d::smallint, '09:00-17:00') from generate_series(1, 5) d;
    perform cma.set_business_hours('DE', 7::smallint, '00:00-24:00');
    perform cma.set_business_hours('*', 6::smallint, '10:00-12:00, 13:00-14:00');
    perform cma.set_business_hours('*', 6::smallint, '');
    if (select count(*) from cma.business_hours where tenant_id = v_t1) <> 6 then
      raise exception 'FAIL B3: % office hour rows, expected 6', (select count(*) from cma.business_hours where tenant_id = v_t1);
    end if;
    begin
      perform cma.set_business_hours('*', 1::smallint, '09:00-12:00,11:00-13:00');
      raise exception 'FAIL B3: overlapping ranges were accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.set_business_hours('*', 1::smallint, '9-17');
      raise exception 'FAIL B3: a malformed range was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.set_business_hours('*', 1::smallint, '17:00-09:00');
      raise exception 'FAIL B3: a range closing before it opens was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.set_business_hours('FR', 1::smallint, '09:00-17:00');
      raise exception 'FAIL B3: hours for a market not in the catalog were accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    if (select string_agg(opens_at::text || '-' || closes_at::text, ',') from cma.business_hours where tenant_id = v_t1 and market = '*' and weekday = 1)
       is distinct from '09:00:00-17:00:00' then
      raise exception 'FAIL B3: a refused change altered Monday';
    end if;
    perform cma.set_business_holiday('NL', date '2026-10-14', 'Verify holiday');
    perform cma.set_business_holiday('*', date '2026-12-25', 'Verify Christmas');
    perform cma.set_business_holiday('*', date '2026-12-26', 'Verify Boxing Day');
    perform cma.remove_business_holiday('*', date '2026-12-26');

    -- B4. business seconds in NL: a weekday, across a weekend, across a holiday, across the DST change
    --     of 25 October 2026, outside hours, a reversed range, an unknown market
    select string_agg(coalesce(cma.business_seconds(m, f::timestamptz, t::timestamptz)::text, 'null'), ',' order by o) into v_txt
    from (values
      (1, 'NL', '2026-10-13 10:00 Europe/Amsterdam', '2026-10-13 10:07 Europe/Amsterdam'),   -- 420
      (2, 'NL', '2026-10-16 16:55 Europe/Amsterdam', '2026-10-19 09:10 Europe/Amsterdam'),   -- 300 + 600
      (3, 'NL', '2026-10-13 16:00 Europe/Amsterdam', '2026-10-15 10:00 Europe/Amsterdam'),   -- Wednesday is a holiday
      (4, 'NL', '2026-10-23 16:00 Europe/Amsterdam', '2026-10-26 10:00 Europe/Amsterdam'),   -- CEST to CET
      (5, 'NL', '2026-10-13 18:00 Europe/Amsterdam', '2026-10-13 20:00 Europe/Amsterdam'),   -- after hours
      (6, 'NL', '2026-10-13 12:00 Europe/Amsterdam', '2026-10-13 10:00 Europe/Amsterdam'),   -- reversed
      (7, 'FR', '2026-10-13 10:00 Europe/Amsterdam', '2026-10-13 11:00 Europe/Amsterdam'),   -- unknown market
      (8, 'DE', '2026-10-25 00:00 Europe/Berlin',    '2026-10-26 00:00 Europe/Berlin'),      -- 25-hour Sunday
      (9, 'DE', '2026-10-26 09:00 Europe/Berlin',    '2026-10-26 17:00 Europe/Berlin'),      -- DE's own week: Monday closed
      (10, 'NL', '2026-12-24 16:00 Europe/Amsterdam', '2026-12-28 10:00 Europe/Amsterdam')   -- * holiday on Friday 25th
    ) as x(o, m, f, t);
    if v_txt is distinct from '420,900,7200,7200,0,0,null,90000,0,7200' then
      raise exception 'FAIL B4: business seconds gave %', v_txt;
    end if;

    -- B5. the next business noon: Friday afternoon gives Monday 12:00; the day before the holiday
    --     gives the day after it; DE (Sunday only) gives the next Sunday
    v_at := cma.next_business_noon('NL', '2026-10-16 15:00 Europe/Amsterdam');
    if v_at is distinct from '2026-10-19 12:00 Europe/Amsterdam'::timestamptz
       or cma.next_business_noon('NL', '2026-10-13 15:00 Europe/Amsterdam') is distinct from '2026-10-15 12:00 Europe/Amsterdam'::timestamptz
       or cma.next_business_noon('DE', '2026-10-21 15:00 Europe/Berlin') is distinct from '2026-10-25 12:00 Europe/Berlin'::timestamptz
       or cma.next_business_noon('FR', now()) is not null then
      raise exception 'FAIL B5: next business noon gave %', v_at;
    end if;

    -- B6. the date setting: a real date is accepted, an impossible one refused
    perform cma.set_tenant_setting('intake.start_date', '2026-10-05');
    begin
      perform cma.set_tenant_setting('intake.start_date', '2026-13-01');
      raise exception 'FAIL B6: an impossible date was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    if (select value from cma.tenant_settings() where key = 'intake.start_date') <> '2026-10-05' then
      raise exception 'FAIL B6: the start date is not 2026-10-05';
    end if;

    -- B7. an agent may not configure markets, aliases or hours
    perform set_config('app.user_id', v_agent::text, true);
    begin
      perform cma.set_market_alias('holland', 'NL');
      raise exception 'FAIL B7: an agent set an alias';
    exception when sqlstate 'CMA06' then null;
    end;
    begin
      perform cma.set_business_hours('*', 1::smallint, '');
      raise exception 'FAIL B7: an agent changed office hours';
    exception when sqlstate 'CMA06' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- C. The 0006 extensions (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_ing1     uuid;
  v_c1       uuid;
  v_key      text;
  v_cfg      jsonb;
  v_txt      text;
  v_t0       timestamptz := now() - interval '3 hours';
  v_t1time   timestamptz := now() - interval '2 hours';
  v_t2time   timestamptz := now() - interval '1 hour';
  r          record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007-one', 'Verify 0007 one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0007-two', 'Verify 0007 two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'admin';
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id, c.key into v_c1, v_key from cma.upsert_connection('verify_crm', 'Verify one', '111', null, null) c;
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_market_alias('uk', 'GB');
    perform cma.set_market_alias('nederland', 'NL');

    -- C1. connection settings: a flat object is kept; secret-looking keys, nested values and upper-case
    --     keys are refused
    perform cma.set_connection_settings(v_c1, '{"app_host": "app.example.com", "api_version": "2026-10", "client_id": "verify"}');
    if (select settings ->> 'app_host' from cma.integration_connection where id = v_c1) is distinct from 'app.example.com' or v_provoke then
      raise exception 'FAIL C1: the settings were not kept';
    end if;
    foreach v_txt in array array['{"client_secret": "x"}', '{"access_token": "x"}', '{"api_key": "x"}', '{"db_password": "x"}',
                                 '{"nested": {"a": 1}}', '{"Host": "x"}', '[1]'] loop
      begin
        perform cma.set_connection_settings(v_c1, v_txt::jsonb);
        raise exception 'FAIL C1: settings % were accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;

    -- C2. the field mapping: the new fields, two ref slots, the 0006 call shape; slot 2 of a non-ref
    --     field and a contact field on a record are refused
    perform cma.set_connection_field(v_c1, 'deal', 'market', null, 'verify_market');
    perform cma.set_connection_field(v_c1, 'deal', 'amount', null, 'amount', 1::smallint);
    perform cma.set_connection_field(v_c1, 'deal', 'currency', null, 'deal_currency_code', 1::smallint);
    perform cma.set_connection_field(v_c1, 'deal', 'source_channel', null, 'verify_channel', 1::smallint);
    perform cma.set_connection_field(v_c1, 'ticket', 'category', null, 'verify_category', 1::smallint);
    perform cma.set_connection_field(v_c1, 'contact', 'currency', null, 'verify_currency', 1::smallint);
    perform cma.set_connection_field(v_c1, 'contact', 'store', null, 'verify_store', 1::smallint);
    perform cma.set_connection_field(v_c1, 'contact', 'ref', 'verify_shop', 'verify_shop_id_1', 1::smallint);
    perform cma.set_connection_field(v_c1, 'contact', 'ref', 'verify_shop', 'verify_shop_id_2', 2::smallint);
    begin
      perform cma.set_connection_field(v_c1, 'contact', 'country', null, 'country_2', 2::smallint);
      raise exception 'FAIL C2: slot 2 of a non-ref field was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.set_connection_field(v_c1, 'deal', 'store', null, 'verify_store', 1::smallint);
      raise exception 'FAIL C2: a record took the contact field store';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.set_connection_field(v_c1, 'contact', 'ref', 'verify_shop', 'verify_shop_id_10', 10::smallint);
      raise exception 'FAIL C2: slot 10 was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    perform cma.set_connection_field(v_c1, 'contact', 'ref', 'verify_shop', '', 2::smallint);
    perform cma.set_connection_field(v_c1, 'contact', 'ref', 'verify_shop', 'verify_shop_id_2', 2::smallint);
    v_cfg := cma.connection_config(v_c1);
    if jsonb_array_length(v_cfg -> 'fields') <> 9
       or (select count(*) from jsonb_array_elements(v_cfg -> 'fields') f where f ->> 'refSystem' = 'verify_shop' and (f ->> 'slot')::int in (1, 2)) <> 2
       or v_cfg -> 'settings' ->> 'api_version' is distinct from '2026-10' then
      raise exception 'FAIL C2: connection_config is %', v_cfg;
    end if;

    -- C3. lead pipelines: added on first mention, flag kept by the source refresh, in the config
    perform cma.set_pipeline_lead(v_c1, 'deal', 'p-test', false);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'pipelineId', 'p-test', 'label', 'Test', 'stages', jsonb_build_array(
        jsonb_build_object('stageId', 's-open', 'label', 'Open', 'order', 1, 'isClosed', false))),
      jsonb_build_object('recordType', 'deal', 'pipelineId', 'p-sales', 'label', 'Sales', 'stages', jsonb_build_array(
        jsonb_build_object('stageId', 's-open', 'label', 'Open', 'order', 1, 'isClosed', false)))));
    if (select string_agg(source_pipeline_id || ':' || is_lead, ',' order by source_pipeline_id) from cma.connection_pipeline where connection_id = v_c1)
       is distinct from 'p-sales:true,p-test:false'
       or not exists (select 1 from jsonb_array_elements(cma.connection_config(v_c1) -> 'pipelines') p
                      where p ->> 'pipelineId' = 'p-test' and p ->> 'isLead' = 'false') then
      raise exception 'FAIL C3: lead flags are wrong';
    end if;

    -- C4. records: an alias market becomes its code, a known code is upper-cased, an unknown market is
    --     kept as written; amount, currency, channel and category; a bad amount or currency is null
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'pipelineId', 'p-sales', 'stageId', 's-open', 'contactId', 'c1',
                         'market', 'UK', 'amount', '1234.567', 'currency', 'gbp', 'sourceChannel', ' PAID_SEARCH ',
                         'createdAt', v_t0, 'updatedAt', v_t1time),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd2', 'pipelineId', 'p-sales', 'stageId', 's-open',
                         'market', 'nl', 'amount', 99, 'currency', 'EUR', 'createdAt', v_t0, 'updatedAt', v_t1time),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd3', 'pipelineId', 'p-sales', 'stageId', 's-open',
                         'market', ' Atlantis ', 'amount', 'a lot', 'currency', 'Euro', 'createdAt', v_t0, 'updatedAt', v_t1time),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 't1', 'market', 'nederland', 'category', 'Complaint',
                         'createdAt', v_t0, 'updatedAt', v_t1time)));
    select string_agg(source_id || ':' || coalesce(market, '∅') || ':' || coalesce(amount::text, '∅') || ':' || coalesce(currency, '∅')
                      || ':' || coalesce(source_channel, '∅') || ':' || coalesce(category, '∅'), ',' order by source_id) into v_txt
    from cma.crm_record where connection_id = v_c1;
    if v_txt is distinct from 'd1:GB:1234.57:GBP:PAID_SEARCH:∅,d2:NL:99.00:EUR:∅:∅,d3:Atlantis:∅:∅:∅:∅,t1:NL:∅:∅:∅:Complaint' then
      raise exception 'FAIL C4: records hold %', v_txt;
    end if;
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'pipelineId', 'p-sales', 'stageId', 's-open',
                         'market', 'GB', 'amount', '10', 'currency', 'GBP', 'createdAt', v_t0, 'updatedAt', v_t2time)));
    if (select amount from cma.crm_record where connection_id = v_c1 and source_id = 'd1') <> 10
       or (select source_channel from cma.crm_record where connection_id = v_c1 and source_id = 'd1') is not null
       or (select contact_source_id from cma.crm_record where connection_id = v_c1 and source_id = 'd1') <> 'c1' then
      raise exception 'FAIL C4: the newer read did not replace the amount and channel';
    end if;

    -- C5. contacts: country through the alias, currency and store normalised, two ref slots; a list
    --     with a gap empties slot 1; a single id replaces the set; a deletion clears currency and store
    perform cma.ingest_upsert_contacts(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'c1', 'country', 'Nederland', 'language', 'nl', 'currency', 'eur', 'store', ' Verify-Store-1 ',
                         'refs', jsonb_build_object('verify_shop', jsonb_build_array('111', '222')), 'updatedAt', v_t0)));
    select * into r from cma.crm_contact where connection_id = v_c1 and source_id = 'c1';
    if r.country <> 'NL' or r.currency <> 'EUR' or r.store <> 'verify-store-1'
       or (select string_agg(slot || '=' || external_id, ',' order by slot) from cma.crm_contact_ref where contact_id = r.id) is distinct from '1=111,2=222' then
      raise exception 'FAIL C5: the contact holds %, %, % and refs %', r.country, r.currency, r.store,
        (select string_agg(slot || '=' || external_id, ',' order by slot) from cma.crm_contact_ref where contact_id = r.id);
    end if;
    perform cma.ingest_upsert_contacts(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'c1', 'country', 'NL', 'currency', 'EUR', 'store', 'not a handle!',
                         'refs', jsonb_build_object('verify_shop', jsonb_build_array(null, '222')), 'updatedAt', v_t1time)));
    if (select string_agg(slot || '=' || external_id, ',' order by slot) from cma.crm_contact_ref where contact_id = r.id) is distinct from '2=222'
       or (select store from cma.crm_contact where id = r.id) is not null then
      raise exception 'FAIL C5: a gap in the list or an invalid store was not handled';
    end if;
    perform cma.ingest_upsert_contacts(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'c1', 'country', 'NL', 'refs', jsonb_build_object('verify_shop', '333'), 'updatedAt', v_t2time)));
    if (select string_agg(slot || '=' || external_id, ',' order by slot) from cma.crm_contact_ref where contact_id = r.id) is distinct from '1=333' then
      raise exception 'FAIL C5: a single id did not replace the set';
    end if;
    perform cma.ingest_upsert_contacts(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'c1', 'currency', 'EUR', 'store', 'verify-store-1', 'updatedAt', now())));
    perform cma.ingest_upsert_contacts(v_c1, jsonb_build_array(jsonb_build_object('sourceId', 'c1', 'deletedAt', now())));
    select * into r from cma.crm_contact where connection_id = v_c1 and source_id = 'c1';
    if r.currency is not null or r.store is not null or r.source_deleted_at is null or exists (select 1 from cma.crm_contact_ref) then
      raise exception 'FAIL C5: a deleted contact kept currency %, store % or refs', r.currency, r.store;
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- D. CRM calls, associations and call outcomes (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_ing1     uuid;
  v_c1       uuid;
  v_txt      text;
  v_n        int;
  v_hash     text := repeat('ab', 32);
  v_t0       timestamptz := now() - interval '3 hours';
  v_t1time   timestamptz := now() - interval '2 hours';
  v_t2time   timestamptz := now() - interval '1 hour';
  r          record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007-one', 'Verify 0007 one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0007-two', 'Verify 0007 two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'admin';
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_crm', 'Verify one', '111') returning id into v_c1;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);

    -- D1. calls: two inserted (one with a hash, direction normalised); a newer read updates, an
    --     older one is stale; a delete clears hash and raw; an unknown delete; bad input refused
    select string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_calls(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'k1', 'occurredAt', v_t0, 'direction', 'OUTBOUND', 'status', 'COMPLETED', 'outcomeRef', 'o-conn',
                         'durationSeconds', 300, 'ownerRef', 'own-1', 'sourceApp', 'Verify_Dialer', 'counterpartHash', v_hash,
                         'createdAt', v_t0, 'updatedAt', v_t0, 'raw', jsonb_build_object('hs_call_status', 'COMPLETED')),
      jsonb_build_object('sourceId', 'k2', 'occurredAt', v_t1time, 'createdAt', v_t1time, 'updatedAt', v_t1time))) u;
    if v_txt is distinct from 'inserted,inserted' or v_provoke then
      raise exception 'FAIL D1: the first calls gave %', v_txt;
    end if;
    select * into r from cma.crm_call where connection_id = v_c1 and source_id = 'k1';
    if r.direction <> 'outbound' or r.source_app <> 'verify_dialer' or r.counterpart_hash <> v_hash or r.source_system <> 'verify_crm'
       or (select direction from cma.crm_call where connection_id = v_c1 and source_id = 'k2') <> 'unknown' then
      raise exception 'FAIL D1: the first call holds %, %, %', r.direction, r.source_app, r.source_system;
    end if;
    select string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_calls(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'k1', 'occurredAt', v_t0, 'direction', 'outbound', 'durationSeconds', 360,
                         'counterpartHash', v_hash, 'updatedAt', v_t1time),
      jsonb_build_object('sourceId', 'k2', 'occurredAt', v_t1time, 'direction', 'inbound', 'updatedAt', v_t0))) u;
    if v_txt is distinct from 'updated,stale'
       or (select duration_seconds from cma.crm_call where connection_id = v_c1 and source_id = 'k1') <> 360
       or (select direction from cma.crm_call where connection_id = v_c1 and source_id = 'k2') <> 'unknown' then
      raise exception 'FAIL D1: newer and older reads gave %', v_txt;
    end if;
    select string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_calls(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'k1', 'deletedAt', v_t2time),
      jsonb_build_object('sourceId', 'k9', 'deletedAt', v_t2time))) u;
    select * into r from cma.crm_call where connection_id = v_c1 and source_id = 'k1';
    if v_txt is distinct from 'deleted,unknown' or r.source_deleted_at is null or r.counterpart_hash is not null or r.raw <> '{}'::jsonb
       or exists (select 1 from cma.crm_call where connection_id = v_c1 and source_id = 'k9') then
      raise exception 'FAIL D1: delete and unknown delete gave %', v_txt;
    end if;
    begin
      perform cma.ingest_upsert_calls(v_c1, jsonb_build_array(jsonb_build_object('sourceId', 'k3', 'direction', 'sideways', 'updatedAt', now())));
      raise exception 'FAIL D1: an unknown direction was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.ingest_upsert_calls(v_c1, jsonb_build_array(jsonb_build_object('sourceId', 'k3', 'counterpartHash', '+44000000001', 'updatedAt', now())));
      raise exception 'FAIL D1: a phone number was accepted as a hash';
    exception when sqlstate 'CMA04' then null;
    end;

    -- D2. associations: added in either direction and stored call -> contact; a removal; an older add
    --     is stale; a re-add; the same state again is unchanged; a contact -> contact pair is refused
    select string_agg(u.from_type || '>' || u.to_type || ':' || u.outcome, ',' order by u.from_type) into v_txt
    from cma.ingest_upsert_associations(v_c1, jsonb_build_array(
      jsonb_build_object('fromType', 'contact', 'fromId', 'c1', 'toType', 'crm_call', 'toId', 'k2', 'removed', false, 'changedAt', v_t0),
      jsonb_build_object('fromType', 'deal', 'fromId', 'd1', 'toType', 'contact', 'toId', 'c1', 'removed', false, 'changedAt', v_t0))) u;
    if v_txt is distinct from 'crm_call>contact:added,deal>contact:added'
       or not exists (select 1 from cma.crm_association where from_type = 'crm_call' and from_id = 'k2' and to_type = 'contact' and to_id = 'c1') then
      raise exception 'FAIL D2: the first associations gave %', v_txt;
    end if;
    select string_agg(u.outcome, ',' order by u.outcome) into v_txt
    from cma.ingest_upsert_associations(v_c1, jsonb_build_array(
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'k2', 'toType', 'contact', 'toId', 'c1', 'removed', true, 'changedAt', v_t2time))) u;
    if v_txt <> 'removed' or (select removed_at from cma.crm_association where from_id = 'k2') is null then
      raise exception 'FAIL D2: a removal gave %', v_txt;
    end if;
    select u.outcome into v_txt
    from cma.ingest_upsert_associations(v_c1, jsonb_build_array(
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'k2', 'toType', 'contact', 'toId', 'c1', 'removed', false, 'changedAt', v_t1time))) u;
    if v_txt <> 'stale' or (select removed_at from cma.crm_association where from_id = 'k2') is null then
      raise exception 'FAIL D2: an older add gave % and the removal %', v_txt,
        case when (select removed_at from cma.crm_association where from_id = 'k2') is null then 'was undone' else 'stands' end;
    end if;
    select string_agg(u.outcome, ',') into v_txt
    from cma.ingest_upsert_associations(v_c1, jsonb_build_array(
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'k2', 'toType', 'contact', 'toId', 'c1', 'removed', false, 'changedAt', now()))) u;
    select v_txt || ',' || string_agg(u.outcome, ',') into v_txt
    from cma.ingest_upsert_associations(v_c1, jsonb_build_array(
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'k2', 'toType', 'contact', 'toId', 'c1', 'removed', false, 'changedAt', now()))) u;
    if v_txt is distinct from 'readded,unchanged' or (select removed_at from cma.crm_association where from_id = 'k2') is not null then
      raise exception 'FAIL D2: re-add and repeat gave %', v_txt;
    end if;
    perform cma.ingest_upsert_associations(v_c1, jsonb_build_array(
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'k2', 'toType', 'deal', 'toId', 'd1', 'removed', false, 'changedAt', now())));
    foreach v_txt in array array['contact>contact', 'deal>ticket', 'crm_call>crm_call'] loop
      begin
        perform cma.ingest_upsert_associations(v_c1, jsonb_build_array(
          jsonb_build_object('fromType', split_part(v_txt, '>', 1), 'fromId', 'x1', 'toType', split_part(v_txt, '>', 2), 'toId', 'x2',
                             'removed', false, 'changedAt', now())));
        raise exception 'FAIL D2: the pair % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    begin
      perform cma.ingest_upsert_associations(v_c1, jsonb_build_array(
        jsonb_build_object('fromType', 'deal', 'fromId', 'd1', 'toType', 'contact', 'toId', 'c2', 'removed', false)));
      raise exception 'FAIL D2: an association without changedAt was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    if (select count(*) from cma.crm_association where connection_id = v_c1) <> 3 then
      raise exception 'FAIL D2: % associations stored, expected 3', (select count(*) from cma.crm_association where connection_id = v_c1);
    end if;

    -- D3. call outcomes: refresh, configure, refresh again keeping is_connected and archiving the
    --     missing one
    v_n := cma.ingest_upsert_call_outcomes(v_c1, '[{"outcomeRef": "o-conn", "label": "Connected"}, {"outcomeRef": "o-none", "label": "No answer"}]');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_call_outcome(v_c1, 'o-conn', true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_n := cma.ingest_upsert_call_outcomes(v_c1, '[{"outcomeRef": "o-conn", "label": "Connected (renamed)"}]');
    if v_n <> 1
       or (select string_agg(outcome_ref || ':' || label || ':' || is_connected || ':' || status, ',' order by outcome_ref)
           from cma.connection_call_outcome where connection_id = v_c1)
          is distinct from 'o-conn:Connected (renamed):true:active,o-none:No answer:false:archived' then
      raise exception 'FAIL D3: the outcome catalog is %', (select string_agg(outcome_ref || ':' || is_connected || ':' || status, ',')
                                                            from cma.connection_call_outcome where connection_id = v_c1);
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- E. Forms, submissions, cursors, sync runs and the privacy deletion (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_ing1     uuid;
  v_c1       uuid;
  v_run      uuid;
  v_n        int;
  v_txt      text;
  v_res      jsonb;
  v_hash     text := repeat('cd', 32);
  r          record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007-one', 'Verify 0007 one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0007-two', 'Verify 0007 two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'admin';
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_crm', 'Verify one', '111') returning id into v_c1;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');

    -- E1. the form catalog: refreshed from the source, configured, refreshed again: the configuration
    --     stays, the missing form is archived; an unknown market is refused
    perform set_config('app.user_id', v_ing1::text, true);
    v_n := cma.ingest_upsert_forms(v_c1, '[{"formId": "f1", "name": "Verify form one"}, {"formId": "f2", "name": "Verify form two"}]');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_form(v_c1, 'f1', true, 'Website', 'NL', array['interest', 'interest', ' product ']);
    perform cma.set_form(v_c1, 'f2', false, null, null, null);
    begin
      perform cma.set_form(v_c1, 'f1', true, 'Website', 'FR', null);
      raise exception 'FAIL E1: a form market outside the catalog was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    begin
      perform cma.set_form(v_c1, 'f1', true, 'Website', 'NL', array['bad field name']);
      raise exception 'FAIL E1: a kept field with spaces was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    perform set_config('app.user_id', v_ing1::text, true);
    v_n := cma.ingest_upsert_forms(v_c1, '[{"formId": "f1", "name": "Verify form one (renamed)"}]');
    select * into r from cma.connection_form where connection_id = v_c1 and source_form_id = 'f1';
    if v_n <> 1 or r.name <> 'Verify form one (renamed)' or not r.is_counted or r.lead_source <> 'Website' or r.market <> 'NL'
       or r.kept_fields <> array['interest', 'product']
       or (select status from cma.connection_form where connection_id = v_c1 and source_form_id = 'f2') <> 'archived' or v_provoke then
      raise exception 'FAIL E1: after the refresh f1 is %, %, %, % and f2 is %', r.name, r.lead_source, r.market, r.kept_fields,
        (select status from cma.connection_form where connection_id = v_c1 and source_form_id = 'f2');
    end if;

    -- E2. submissions: kept values filtered to the kept fields although the input carries more; the
    --     query string and fragment cut; only the five UTM keys; a resend is known; a resolution moves
    --     forward once and never away from resolved; an unknown form joins the catalog
    select string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_form_submissions(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 's1', 'formId', 'f1', 'submittedAt', now() - interval '10 minutes',
                         'pageHost', 'WWW.Example.com', 'pagePath', '/buy?email=someone@example.com#top',
                         'utm', jsonb_build_object('source', 'verify', 'campaign', 'autumn', 'gclid', 'abc', 'email', 'someone@example.com'),
                         'contactResolution', 'pending',
                         'keptValues', jsonb_build_object('interest', 'aed', 'email', 'someone@example.com', 'firstname', 'Someone',
                                                          'product', repeat('x', 300))),
      jsonb_build_object('sourceId', 's2', 'formId', 'f9', 'submittedAt', now(), 'contactId', 'c1',
                         'keptValues', jsonb_build_object('interest', 'aed')))) u;
    select * into r from cma.form_submission where connection_id = v_c1 and source_id = 's1';
    if v_txt is distinct from 'inserted,inserted'
       or r.kept_values <> jsonb_build_object('interest', 'aed', 'product', repeat('x', 200))
       or r.page_path <> '/buy' or r.page_host <> 'www.example.com'
       or r.utm <> '{"source": "verify", "campaign": "autumn"}'::jsonb or r.contact_resolution <> 'pending'
       or (select kept_values from cma.form_submission where connection_id = v_c1 and source_id = 's2') <> '{}'::jsonb
       or (select contact_resolution from cma.form_submission where connection_id = v_c1 and source_id = 's2') <> 'resolved'
       or not exists (select 1 from cma.connection_form where connection_id = v_c1 and source_form_id = 'f9' and is_counted) then
      raise exception 'FAIL E2: submissions gave %, kept %, path %, utm %', v_txt, r.kept_values, r.page_path, r.utm;
    end if;
    select string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_form_submissions(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 's1', 'formId', 'f1', 'contactResolution', 'pending',
                         'keptValues', jsonb_build_object('interest', 'changed')))) u;
    select v_txt || ',' || string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_form_submissions(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 's1', 'formId', 'f1', 'contactId', 'c1'))) u;
    select v_txt || ',' || string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_form_submissions(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 's1', 'formId', 'f1', 'contactResolution', 'not_found'))) u;
    select * into r from cma.form_submission where connection_id = v_c1 and source_id = 's1';
    if v_txt is distinct from 'known,resolved,known' or r.contact_source_id <> 'c1' or r.contact_resolution <> 'resolved'
       or r.kept_values ->> 'interest' <> 'aed' then
      raise exception 'FAIL E2: resend and resolution gave %, now % %', v_txt, r.contact_resolution, r.kept_values;
    end if;
    begin
      perform cma.ingest_upsert_form_submissions(v_c1, jsonb_build_array(
        jsonb_build_object('sourceId', 's3', 'formId', 'f1', 'contactResolution', 'guessed')));
      raise exception 'FAIL E2: an unknown resolution was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      update cma.form_submission set submitted_at = now() where connection_id = v_c1 and source_id = 's1';
      raise exception 'FAIL E2: the application changed a submission''s time';
    exception when insufficient_privilege then null;
    end;

    -- E3. cursors: none yet, set, replaced; an oversize cursor is refused
    if cma.ingest_cursor_get(v_c1, 'forms:f1') is not null then
      raise exception 'FAIL E3: a cursor exists before it was set';
    end if;
    perform cma.ingest_cursor_set(v_c1, 'forms:f1', '{"after": "s1"}');
    perform cma.ingest_cursor_set(v_c1, 'forms:f1', '{"after": "s2"}');
    if cma.ingest_cursor_get(v_c1, 'forms:f1') <> '{"after": "s2"}'::jsonb or (select count(*) from cma.sync_cursor) <> 1 then
      raise exception 'FAIL E3: the cursor is %', cma.ingest_cursor_get(v_c1, 'forms:f1');
    end if;
    begin
      perform cma.ingest_cursor_set(v_c1, 'forms:f1', jsonb_build_object('after', repeat('x', 3000)));
      raise exception 'FAIL E3: an oversize cursor was accepted';
    exception when sqlstate 'CMA04' then null;
    end;

    -- E4. sync runs: started, finished once with counts; a second finish, bad counts, an unknown job
    --     and a direct change of the job are refused
    v_run := cma.ingest_sync_run_start(v_c1, 'forms_poll', 'forms:f1', now() - interval '1 hour', now());
    begin
      perform cma.ingest_sync_run_finish(v_run, 'succeeded', '{"fetched": 2, "emails": 1}');
      raise exception 'FAIL E4: unknown counts were accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    perform cma.ingest_sync_run_finish(v_run, 'succeeded', '{"fetched": 2, "upserted": 2}');
    begin
      perform cma.ingest_sync_run_finish(v_run, 'failed', '{}', 'verify_error');
      raise exception 'FAIL E4: a run finished twice';
    exception when sqlstate 'CMA03' then null;
    end;
    select * into r from cma.sync_run where id = v_run;
    if r.status <> 'succeeded' or r.finished_at is null or r.counts <> '{"fetched": 2, "upserted": 2}'::jsonb or r.started_by <> v_ing1 then
      raise exception 'FAIL E4: the run is %, %', r.status, r.counts;
    end if;
    begin
      perform cma.ingest_sync_run_start(v_c1, 'everything', null, null, null);
      raise exception 'FAIL E4: an unknown job was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      update cma.sync_run set job = 'backfill' where id = v_run;
      raise exception 'FAIL E4: the application changed a run''s job';
    exception when insufficient_privilege then null;
    end;

    -- E5. the privacy deletion: the contact loses its attributes and refs, its call its hash, its
    --     submission its kept values; another contact's call keeps its hash; ids remain
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'contactId', 'c1', 'createdAt', now(), 'updatedAt', now()),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd2', 'contactId', 'c2', 'createdAt', now(), 'updatedAt', now())));
    perform cma.ingest_upsert_contacts(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'c1', 'country', 'NL', 'language', 'nl', 'currency', 'EUR', 'store', 'verify-store',
                         'refs', jsonb_build_object('verify_shop', jsonb_build_array('111', '222')), 'updatedAt', now())));
    perform cma.ingest_upsert_calls(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'k1', 'direction', 'outbound', 'counterpartHash', v_hash, 'updatedAt', now()),
      jsonb_build_object('sourceId', 'k2', 'direction', 'outbound', 'counterpartHash', v_hash, 'updatedAt', now())));
    perform cma.ingest_upsert_associations(v_c1, jsonb_build_array(
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'k1', 'toType', 'contact', 'toId', 'c1', 'removed', false, 'changedAt', now()),
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'k2', 'toType', 'contact', 'toId', 'c2', 'removed', false, 'changedAt', now())));
    v_res := cma.ingest_contact_forget(v_c1, 'c1');
    select * into r from cma.crm_contact where connection_id = v_c1 and source_id = 'c1';
    if v_res <> '{"contacts": 1, "refs": 2, "calls": 1, "submissions": 1}'::jsonb
       or r.country is not null or r.language is not null or r.currency is not null or r.store is not null or r.source_deleted_at is null
       or exists (select 1 from cma.crm_contact_ref)
       or (select counterpart_hash from cma.crm_call where source_id = 'k1') is not null
       or (select counterpart_hash from cma.crm_call where source_id = 'k2') is distinct from v_hash
       or (select kept_values from cma.form_submission where source_id = 's1') <> '{}'::jsonb
       or (select contact_source_id from cma.form_submission where source_id = 's1') <> 'c1'
       or (select contact_source_id from cma.crm_record where source_id = 'd1') <> 'c1' then
      raise exception 'FAIL E5: forget answered % and left %', v_res, r;
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- F. Permissions, people's ids and tenant isolation (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_agent    uuid;
  v_agent2   uuid;
  v_ing1     uuid;
  v_ing2     uuid;
  v_admin2   uuid;
  v_c1       uuid;
  v_c2       uuid;
  v_t        text;
  v_n        bigint;
  v_txt      text;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007-one', 'Verify 0007 one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0007-two', 'Verify 0007 two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent2@example.invalid', 'Verify agent two') returning id into v_agent2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin@example.invalid', 'Verify admin two') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin, 'admin'), (v_t1, v_agent, 'agent'), (v_t1, v_agent2, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    select id into v_ing2 from cma.app_user where tenant_id = v_t2 and email = 'ingest@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_crm', 'Verify one', '111') returning id into v_c1;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verify_crm', 'Verify two', '222') returning id into v_c2;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);

    -- F1. the Ingest user cannot configure; a configuring person cannot write as the ingest
    perform set_config('app.user_id', v_ing1::text, true);
    foreach v_txt in array array[
      'select cma.upsert_market(''NL'', ''Netherlands'', ''Europe/Amsterdam'', ''nl'', ''EUR'')',
      'select cma.set_business_hours(''*'', 1::smallint, ''09:00-17:00'')',
      format('select cma.set_form(%L, ''f1'', true, null, null, null)', v_c1),
      format('select cma.set_connection_settings(%L, ''{}'')', v_c1),
      format('select cma.set_call_outcome(%L, ''o1'', true)', v_c1),
      format('select cma.set_pipeline_lead(%L, ''deal'', ''p1'', true)', v_c1),
      format('select cma.set_user_external_id(%L, ''verify_owner'', ''o-1'')', v_agent)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL F1: the Ingest user ran %', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;
    if v_provoke then
      raise exception 'FAIL F1: provoked';
    end if;
    perform set_config('app.user_id', v_admin::text, true);
    foreach v_txt in array array[
      format('select cma.ingest_upsert_calls(%L, ''[]'')', v_c1),
      format('select cma.ingest_upsert_associations(%L, ''[]'')', v_c1),
      format('select cma.ingest_upsert_call_outcomes(%L, ''[]'')', v_c1),
      format('select cma.ingest_upsert_forms(%L, ''[]'')', v_c1),
      format('select cma.ingest_upsert_form_submissions(%L, ''[]'')', v_c1),
      format('select cma.ingest_cursor_get(%L, ''s'')', v_c1),
      format('select cma.ingest_cursor_set(%L, ''s'', ''{}'')', v_c1),
      format('select cma.ingest_sync_run_start(%L, ''backfill'', null, null, null)', v_c1),
      format('select cma.ingest_contact_forget(%L, ''c1'')', v_c1)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL F1: a configuring person ran %', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;

    -- F2. people's ids in other systems: set, replaced, removed; a sign-in system, a system user, an
    --     id held by another person and an agent as the actor are refused
    perform cma.set_user_external_id(v_agent, 'verify_owner', 'o-1');
    perform cma.set_user_external_id(v_agent, 'verify_owner', 'o-2');
    perform cma.set_user_external_id(v_agent, 'verify_user', 'u-1');
    if (select string_agg(system || '=' || external_id, ',' order by system) from cma.app_user_external_id where user_id = v_agent)
       is distinct from 'verify_owner=o-2,verify_user=u-1' then
      raise exception 'FAIL F2: the agent''s ids are %', (select string_agg(system || '=' || external_id, ',') from cma.app_user_external_id where user_id = v_agent);
    end if;
    foreach v_txt in array array[
      format('select cma.set_user_external_id(%L, ''mock'', ''verify-login'')', v_agent),
      format('select cma.set_user_external_id(%L, ''google'', ''123'')', v_agent),
      format('select cma.remove_user_external_id(%L, ''ingest'')', v_ing1),
      format('select cma.set_user_external_id(%L, ''verify_owner'', ''has space'')', v_agent)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL F2: % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    begin
      perform cma.set_user_external_id(v_ing1, 'verify_owner', 'o-9');
      raise exception 'FAIL F2: a system user got an id';
    exception when sqlstate 'CMA02' then null;
    end;
    begin
      perform cma.set_user_external_id(v_agent2, 'verify_owner', 'o-2');
      raise exception 'FAIL F2: an id held by another person was accepted';
    exception when sqlstate 'CMA03' then null;
    end;
    perform cma.remove_user_external_id(v_agent, 'verify_user');
    perform set_config('app.user_id', v_agent::text, true);
    begin
      perform cma.set_user_external_id(v_agent, 'verify_user', 'u-2');
      raise exception 'FAIL F2: an agent set an id';
    exception when sqlstate 'CMA06' then null;
    end;

    -- F3. tenant one fills every new table
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_market_alias('nederland', 'NL');
    perform cma.set_business_hours('*', 1::smallint, '09:00-17:00');
    perform cma.set_business_holiday('*', date '2026-12-25', 'Verify Christmas');
    perform cma.set_call_outcome(v_c1, 'o1', true);
    perform cma.set_form(v_c1, 'f1', true, null, null, null);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_calls(v_c1, '[{"sourceId": "k1", "updatedAt": "2026-10-10T10:00:00Z"}]');
    perform cma.ingest_upsert_associations(v_c1, '[{"fromType": "crm_call", "fromId": "k1", "toType": "contact", "toId": "c1", "removed": false, "changedAt": "2026-10-10T10:00:00Z"}]');
    perform cma.ingest_upsert_form_submissions(v_c1, '[{"sourceId": "s1", "formId": "f1"}]');
    perform cma.ingest_cursor_set(v_c1, 'forms:f1', '{"after": "s1"}');
    perform cma.ingest_sync_run_start(v_c1, 'backfill', null, null, null);

    -- F4. tenant two sees none of it, cannot write to tenant one's connection, and its own reads of the
    --     shared helpers know nothing of tenant one's markets
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    foreach v_t in array array['market', 'market_alias', 'business_hours', 'business_holiday', 'crm_call', 'connection_call_outcome',
                               'crm_association', 'connection_form', 'form_submission', 'sync_cursor', 'sync_run'] loop
      execute format('select count(*) from cma.%I', v_t) into v_n;
      if v_n <> 0 then
        raise exception 'FAIL F4: tenant two sees % row(s) of tenant one in cma.%', v_n, v_t;
      end if;
    end loop;
    foreach v_txt in array array[
      format('select cma.ingest_upsert_calls(%L, ''[]'')', v_c1),
      format('select cma.ingest_upsert_associations(%L, ''[]'')', v_c1),
      format('select cma.ingest_upsert_form_submissions(%L, ''[]'')', v_c1),
      format('select cma.ingest_cursor_get(%L, ''forms:f1'')', v_c1),
      format('select cma.ingest_contact_forget(%L, ''c1'')', v_c1)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL F4: tenant two ran %', v_txt;
      exception when sqlstate 'CMA02' then null;
      end;
    end loop;
    if cma.normalize_market('nederland') <> 'nederland' or cma.business_seconds('NL', now() - interval '1 day', now()) is not null then
      raise exception 'FAIL F4: tenant two''s helpers see tenant one''s markets';
    end if;
    perform set_config('app.user_id', v_admin2::text, true);
    begin
      perform cma.set_form(v_c1, 'f1', false, null, null, null);
      raise exception 'FAIL F4: tenant two configured tenant one''s form';
    exception when sqlstate 'CMA02' then null;
    end;
    begin
      perform cma.set_user_external_id(v_agent, 'verify_owner', 'o-3');
      raise exception 'FAIL F4: tenant two set an id on tenant one''s person';
    exception when sqlstate 'CMA02' then null;
    end;

    -- F5. no deletes on the new fact tables; the mapping rows can go
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    foreach v_t in array array['market', 'crm_call', 'crm_association', 'connection_form', 'form_submission', 'sync_run', 'sync_cursor', 'connection_call_outcome'] loop
      begin
        execute format('delete from cma.%I', v_t);
        raise exception 'FAIL F5: the application deleted from cma.%', v_t;
      exception when insufficient_privilege then null;
      end;
    end loop;
    perform cma.remove_market_alias('nederland');
    perform cma.remove_business_holiday('*', date '2026-12-25');

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the intake configuration and what has arrived so far
select t.slug as tenant,
       (select count(*) from cma.market m where m.tenant_id = t.id) as markets,
       (select count(*) from cma.market_alias a where a.tenant_id = t.id) as aliases,
       (select count(*) from cma.business_hours h where h.tenant_id = t.id) as hour_ranges,
       (select count(*) from cma.crm_call c where c.tenant_id = t.id) as crm_calls,
       (select count(*) from cma.form_submission s where s.tenant_id = t.id) as submissions,
       (select count(*) from cma.sync_run r where r.tenant_id = t.id) as sync_runs,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
