-- =============================================================================================
-- 159_verify_flash_current_take.sql: verifies addition 0009e, the installed base's first paint from a stored current take
-- =============================================================================================
-- Blocks S check the addition, its table, settings and functions (universal). Block A works on three throwaway tenants
-- inside a subtransaction that is always rolled back, so nothing stays; block D takes every active tenant's current
-- takes on its own data inside a subtransaction that is rolled back too, and compares them with the live document. The
-- script runs alike in dev and in prod. The remade cma.flash_document_of is compared with its previous definition, kept
-- below as pg_temp.v0009e_document_0008zt (136_flash_insights.sql, word for word but its name), in the same transaction,
-- so the same now(): a take refreshed in that transaction has the instant the live read has. Since 0009f (#251) A3 and
-- D1 read the two documents in one statement, so in one snapshot: prod's first run read D1 FAIL on `sources` alone, the
-- ingest having committed a read between the two statements. Every check writes one row,
-- ok or FAIL, and the last row is the verdict, because Cloud SQL Studio shows no notices: "0009e verified |
-- 159_verify_flash_current_take: 12 ok, 0 FAIL, 0 skip" (D1 reads skip for a database without a tenant whose asset
-- register is set up: 11 ok, 1 skip). Run as your own IAM login after 158_flash_current_take.sql, dev first, then prod;
-- then 123, 137, 139 and 147 again (158's header).
--   S1  the addition 0009e is recorded after 0009d
--   S2  the table: its columns, key and checks; row-level security with the tenant policy, no audit trigger; read only for
--       the application, nothing for the readers; cma_read.flash_current_take's columns, readable by the readers
--   S3  the functions: the state and the setting's helpers the application's, in the caller's rights; the job's entry
--       SECURITY DEFINER, the owner's, search path pinned, the application's only; the writer and its lock key the
--       owner's alone; JIT off on the two remade functions and the refresh's two; the watch's kinds take current_stale
--   S4  the two settings with their types and defaults, their check trigger and the trigger that removes a tenant's takes
--       when one of its settings is written, changed or reset (cma.flash_current_forget: definer, the owner's, pinned)
--   A1  the setting checks: flash.current_overviews takes stock overviews but data quality, each once (spaces removed),
--       or nothing, and refuses a flow, data quality, an unknown key, a key twice or a stray comma (CMA04);
--       flash.current_refresh_minutes takes 1 to 1440 and refuses 0, 1441, a word, a sign and five digits (CMA04)
--   A2  the refresh as the job runs it (the scheduler, the application's role): every overview of the setting taken, its
--       rows cma.flash_compute_of's; a second run keeps them (fresh); a tenant without its sources set up keeps none
--       (current_not_set_up); another tenant's id, a person without flash.snapshot and an overview that keeps no take are
--       refused (CMA06, CMA06, CMA04)
--   A3  a fresh take equals the live document for the same instant, row for row, across every set and market: every
--       stock overview of the setting (the installed base, customers, subscriptions, open deals, tickets and tasks), all
--       markets, each market, unknown and a market without rows, against 0008zt's definition computed live; the take's
--       document answers refreshed_at, the live one none. Provoked, one take row differs (a deliberate difference that the
--       comparison must find)
--   A4  two tenants never see each other's take: as the application each reads its own rows only; each document is its
--       own (tenant two's take altered, tenant one's figures unchanged); the definer's take holds the tenant's own rows
--       while the other tenant holds devices with the same ids
--   A5  the application cannot write the table (insert, update, delete: 42501) nor run the writer (42501)
--   A6  the watch: a take older than three times the setting opens current_stale (its age, the threshold); a fresh take
--       resolves it; no take opens none
--   A7  the fallback: no take, a take older than three times the setting (16 minutes at 5), another definition version, a
--       setting written or reset after it (both remove the tenant's takes), a migration recorded after it, and an
--       overview taken out of the setting all read live
--       (refreshed_at null, the live figures, 0008zt's document); a take younger than three times it (6 and 14 minutes) is
--       read (its figures, its instant); the state at 4, 6, 14 and 16 minutes is fresh, usable, usable and stale; an
--       overview taken out of the setting loses its take at the next refresh
--   D1  every active tenant with a stock overview of its setting set up: a fresh take of each, refreshed as its scheduler,
--       equals the live document (0008zt's definition) for every market; rolled back
-- Block A moves cma.schema_migration.applied_at of the additions recorded in the last day (158 just before this script)
-- a day back, and A7 sets 0009e's to now and back, all inside its always-rolled-back subtransaction: nothing stays, and
-- for the block's few seconds no other session sees the change (it is uncommitted), but the rows stay locked by it.
-- Block D's refresh takes each tenant's advisory lock for its own seconds; the snapshot job's run meanwhile answers
-- running for that overview and keeps its take.
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED, NOT A PASS.
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

drop table if exists pg_temp.verify_0009e;
create temp table verify_0009e (ord int, check_name text, result text, detail text);

-- ---------------------------------------------------------------------------------------------
-- The previous definition, word for word but for its name
-- ---------------------------------------------------------------------------------------------
-- cma.flash_document_of as 0008zt (136_flash_insights.sql) defined it: now always computed live
create or replace function pg_temp.v0009e_document_0008zt(p_tenant_id uuid, p_overview text, p_market text, p_as_of date, p_from date, p_to date)
returns jsonb
language plpgsql stable
as $$
declare
  o          record;
  v_today    date := cma.tenant_today_of(p_tenant_id);
  v_from     date;
  v_to       date;
  v_mode     text;
  v_sources  jsonb;
  v_all      jsonb;
  v_dates    date[];
  v_missing  jsonb;
  v_version  text := cma.flash_definition_version(p_overview);
  v_total    jsonb;
  v_totals   jsonb;
  v_rows     jsonb;
  v_extra    jsonb := '{}'::jsonb;
  v_active   jsonb;
  -- the settings the figures followed: now's, or as of a date the snapshot run's (0008zt's three, absent from a run
  -- taken before them, read as null)
  v_run_settings jsonb;
begin
  select * into o from cma.flash_overviews() x where x.key = p_overview;
  if o.kind = 'flow' then
    v_from := coalesce(p_from, p_as_of, v_today);
    v_to := coalesce(p_to, p_as_of, v_today);
  end if;
  if p_as_of is null then
    v_mode := 'live';
    v_sources := cma.flash_sources_of(p_tenant_id);
    select coalesce(jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures) order by c.dims::text), '[]'::jsonb) into v_all
    from cma.flash_compute_of(p_tenant_id, p_overview, v_from, v_to) c;
  else
    v_mode := 'snapshot';
    select array_agg(r.snapshot_date order by r.snapshot_date) into v_dates
    from cma.flash_snapshot_run r
    where r.tenant_id = p_tenant_id and r.status = 'succeeded'
      and r.snapshot_date between coalesce(v_from, p_as_of) and coalesce(v_to, p_as_of);
    if v_dates is null then
      raise exception 'no Flash snapshot for %', case when o.kind = 'flow' then v_from || ' to ' || v_to else p_as_of::text end
        using errcode = 'CMA02';
    end if;
    select r.sources, r.settings into v_sources, v_run_settings from cma.flash_snapshot_run r
    where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date = v_dates[cardinality(v_dates)];
    select coalesce(jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures) order by c.dims::text), '[]'::jsonb) into v_all
    from cma.flash_snapshot_sum_of(p_tenant_id, p_overview, v_dates) c;
    select min(s.definition_version) into v_version from cma.flash_snapshot s
    where s.tenant_id = p_tenant_id and s.overview = p_overview and s.snapshot_date = any (v_dates);
    if o.kind = 'flow' then
      select coalesce(jsonb_agg(g::date order by g), '[]'::jsonb) into v_missing
      from generate_series(v_from, v_to, interval '1 day') g where not (g::date = any (v_dates));
      v_extra := v_extra || jsonb_build_object('days', jsonb_build_object('covered', cardinality(v_dates), 'missing', v_missing));
    end if;
  end if;

  -- the totals: the {} row, or the market's own row (zeros when the market has none); the rows of the other sets
  select r -> 'measures' into v_total from jsonb_array_elements(v_all) r where r -> 'dims' = '{}'::jsonb;
  if p_market is null then
    v_totals := v_total;
  else
    select r -> 'measures' into v_totals from jsonb_array_elements(v_all) r where r -> 'dims' = jsonb_build_object('market', p_market);
    if v_totals is null and v_total is not null then
      select jsonb_object_agg(e.key, case when jsonb_typeof(e.value) = 'object' then '{}'::jsonb else '0'::jsonb end) into v_totals
      from jsonb_each(v_total) e where e.key not in ('median_age_days', 'oldest_age_days', 'devices_per_holding_subscription');
    end if;
  end if;
  select coalesce(jsonb_agg(r order by (r -> 'dims')::text), '[]'::jsonb) into v_rows
  from jsonb_array_elements(v_all) r
  where r -> 'dims' <> '{}'::jsonb and (p_market is null or r -> 'dims' ->> 'market' = p_market);

  if p_overview = 'churn' then
    select coalesce(s.measures -> 'active_subscriptions', null) into v_active from cma.flash_snapshot s
    where s.tenant_id = p_tenant_id and s.overview = 'subscriptions' and s.snapshot_date = v_to
      and s.dims = case when p_market is null then '{}'::jsonb else jsonb_build_object('market', p_market) end;
    if v_active is null and exists (select 1 from cma.flash_snapshot_run r
                                    where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date = v_to) then
      v_active := '0'::jsonb;
    end if;
    if v_active is null and p_as_of is null and v_to >= v_today and (v_sources -> 'subscriptions' ->> 'set_up')::boolean then
      select to_jsonb(count(*)) into v_active from cma.flash_subscriptions_of(p_tenant_id) s
      where s.is_active and (p_market is null or s.market = p_market);
    end if;
    v_extra := v_extra || jsonb_build_object('active_at_end', v_active);
  elsif p_overview = 'data_quality' then
    v_extra := v_extra || jsonb_build_object('history', coalesce((
      select jsonb_agg(jsonb_build_object('date', s.snapshot_date, 'check', s.dims ->> 'check', 'findings', s.measures -> 'findings')
                       order by s.snapshot_date, s.dims ->> 'check')
      from cma.flash_snapshot s
      where s.tenant_id = p_tenant_id and s.overview = 'data_quality'
        and s.snapshot_date in (select r.snapshot_date from cma.flash_snapshot_run r
                                where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date <= coalesce(p_as_of, v_today)
                                order by r.snapshot_date desc limit 30)
        and s.dims ? 'check'
        and s.dims = case when p_market is null then jsonb_build_object('check', s.dims ->> 'check')
                          else jsonb_build_object('check', s.dims ->> 'check', 'market', p_market) end), '[]'::jsonb));
  end if;

  return jsonb_build_object(
    'overview', p_overview, 'kind', o.kind, 'mode', v_mode,
    'as_of', case when v_mode = 'live' then to_jsonb(now()) else to_jsonb(p_as_of) end,
    'from', v_from, 'to', v_to, 'market', p_market,
    'source', o.source,
    'set_up', case when o.source is null then true else coalesce((v_sources -> o.source ->> 'set_up')::boolean, false) end,
    'sources', v_sources,
    'totals', v_totals, 'rows', v_rows,
    'definition_version', v_version, 'headline', o.headline, 'dims', to_jsonb(o.dims), 'sets', o.sets, 'measures', to_jsonb(o.measures),
    'count_measures', to_jsonb(o.count_measures), 'sorts', to_jsonb(o.sorts),
    'labels', cma.flash_labels_of(p_tenant_id, p_overview),
    'settings', jsonb_build_object(
      'active_subscription_statuses', to_jsonb(cma.flash_active_statuses_of(p_tenant_id)),
      'ended_subscription_statuses', to_jsonb(cma.flash_ended_statuses_of(p_tenant_id)),
      'required_contact_refs', to_jsonb(cma.flash_list_of(cma.setting_of(p_tenant_id, 'commerce.required_contact_refs'))),
      'required_device_refs', to_jsonb(cma.flash_list_of(cma.setting_of(p_tenant_id, 'assets.required_refs'))),
      'negative_max_rating', cma.setting_of(p_tenant_id, 'reviews.negative_max_rating')::integer,
      'file_max_rows', cma.setting_of(p_tenant_id, 'flash.file_max_rows')::integer,
      'device_bands', case when p_as_of is null then to_jsonb(cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.device_bands')))
                           when v_run_settings ? 'flash.device_bands' then to_jsonb(cma.flash_bounds_of(v_run_settings ->> 'flash.device_bands')) end,
      'subscription_age_months', case when p_as_of is null then to_jsonb(cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.subscription_age_months')))
                                      when v_run_settings ? 'flash.subscription_age_months'
                                      then to_jsonb(cma.flash_bounds_of(v_run_settings ->> 'flash.subscription_age_months')) end,
      'customer_segments', case when p_as_of is null then to_jsonb(cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments')))
                                when v_run_settings ? 'crm.customer_segments' then to_jsonb(cma.flash_list_of(v_run_settings ->> 'crm.customer_segments')) end)
      -- the statuses the figures count and their meanings, for the hints (now's: cma.flash_status_settings_of)
      || (cma.flash_status_settings_of(p_tenant_id) - 'active_subscription_statuses' - 'ended_subscription_statuses'),
    'first_snapshot_date', (select min(r.snapshot_date) from cma.flash_snapshot_run r where r.tenant_id = p_tenant_id and r.status = 'succeeded'),
    'today', cma.tenant_today_of(p_tenant_id), 'time_zone', (select t.timezone from cma.tenant t where t.id = p_tenant_id))
    || v_extra;
end
$$;

-- A statement's SQLSTATE, or ok
create or replace function pg_temp.v0009e_code(p_sql text)
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

-- Two documents' first difference: the first row (by position) that differs, with its dims, else the keys that differ;
-- null when they are equal
create or replace function pg_temp.v0009e_diff(p_new jsonb, p_old jsonb)
returns text
language sql
as $$
  select case when p_new is not distinct from p_old then null
              else coalesce(
                (select 'row ' || i || ' ' || coalesce(p_new -> 'rows' -> (i - 1) ->> 'dims', p_old -> 'rows' -> (i - 1) ->> 'dims', '?')
                 from generate_series(1, greatest(jsonb_array_length(coalesce(p_new -> 'rows', '[]'::jsonb)),
                                                  jsonb_array_length(coalesce(p_old -> 'rows', '[]'::jsonb)))) i
                 where (p_new -> 'rows' -> (i - 1)) is distinct from (p_old -> 'rows' -> (i - 1))
                 order by i limit 1),
                (select 'keys ' || string_agg(x.k, ',' order by x.k)
                 from (select distinct k from jsonb_object_keys(coalesce(p_new, '{}'::jsonb) || coalesce(p_old, '{}'::jsonb)) k
                       where (p_new -> k) is distinct from (p_old -> k)) x),
                'documents differ') end
$$;

grant execute on function pg_temp.v0009e_document_0008zt(uuid,text,text,date,date,date) to cma_app;
grant execute on function pg_temp.v0009e_diff(jsonb,jsonb) to cma_app;
grant execute on function pg_temp.v0009e_code(text) to cma_app;

-- S1. The addition
do $$
begin
  insert into verify_0009e values (1, 'S1 the addition 0009e is recorded after 0009d',
    case when exists (select 1 from cma.schema_migration where version = '0009e')
              and exists (select 1 from cma.schema_migration where version = '0009d')
              and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end,
    (select string_agg(version, ', ' order by version) from cma.schema_migration where version in ('0009d', '0009e')));
end
$$;

-- S2. The table and its reader view
do $$
declare
  v_bad text := '';
begin
  if to_regclass('cma.flash_current_take') is null then
    v_bad := 'the table is missing; ';
  else
    if (select string_agg(c.column_name || ':' || c.data_type || ':' || c.is_nullable, ',' order by c.ordinal_position)
        from information_schema.columns c where c.table_schema = 'cma' and c.table_name = 'flash_current_take')
       is distinct from 'tenant_id:uuid:NO,overview:text:NO,dims:jsonb:NO,measures:jsonb:NO,definition_version:text:NO,computed_at:timestamp with time zone:NO' then
      v_bad := v_bad || 'columns; ';
    end if;
    if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.flash_current_take'::regclass and contype = 'p')
       is distinct from 'PRIMARY KEY (tenant_id, overview, dims)'
       or not exists (select 1 from pg_constraint where conrelid = 'cma.flash_current_take'::regclass and contype = 'c'
                      and pg_get_constraintdef(oid) like '%flash_row_ok(overview, dims, measures)%') then
      v_bad := v_bad || 'keys and checks; ';
    end if;
    if not (select relrowsecurity from pg_class where oid = 'cma.flash_current_take'::regclass)
       or not exists (select 1 from pg_policies where schemaname = 'cma' and tablename = 'flash_current_take' and policyname = 'tenant_app'
                      and roles = '{cma_app}' and qual like '%current_tenant_id()%' and with_check like '%current_tenant_id()%') then
      v_bad := v_bad || 'row-level security; ';
    end if;
    if exists (select 1 from pg_trigger where tgrelid = 'cma.flash_current_take'::regclass and not tgisinternal) then
      v_bad := v_bad || 'a trigger (no audit on a derived table); ';
    end if;
    if not has_table_privilege('cma_app', 'cma.flash_current_take', 'select')
       or has_table_privilege('cma_app', 'cma.flash_current_take', 'insert') or has_table_privilege('cma_app', 'cma.flash_current_take', 'update')
       or has_table_privilege('cma_app', 'cma.flash_current_take', 'delete') or has_table_privilege('cma_app', 'cma.flash_current_take', 'truncate')
       or has_table_privilege('cma_readonly', 'cma.flash_current_take', 'select') then
      v_bad := v_bad || 'table privileges; ';
    end if;
  end if;
  if (select string_agg(c.column_name, ',' order by c.ordinal_position) from information_schema.columns c
      where c.table_schema = 'cma_read' and c.table_name = 'flash_current_take')
     is distinct from 'tenant_id,overview,dims,measures,definition_version,computed_at'
     or not has_table_privilege('cma_readonly', 'cma_read.flash_current_take', 'select') then
    v_bad := v_bad || 'the reader view; ';
  end if;
  insert into verify_0009e values (2, 'S2 the table: columns, key, checks; row-level security, no audit trigger; read only for the application, nothing for the readers; the reader view',
    case when v_bad = '' and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end, nullif(v_bad, ''));
end
$$;

-- S3. The functions
do $$
declare
  v_fn text;
  v_bad text := '';
begin
  foreach v_fn in array array['cma.flash_current_keys()', 'cma.flash_current_overviews_ok(text)', 'cma.flash_current_overviews_of(uuid)',
                              'cma.flash_current_state_of(uuid,text,timestamptz,text,timestamptz)', 'cma.flash_document_of(uuid,text,text,date,date,date)',
                              'cma.flash_overview(text,text,date,date,date)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  v_fn := 'cma.flash_current_refresh(uuid)';
  if to_regprocedure(v_fn) is null then
    v_bad := v_bad || v_fn || ' missing; ';
  elsif not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
        or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
        or not (select 'search_path=pg_catalog, cma, pg_temp' = any (proconfig) from pg_proc where oid = to_regprocedure(v_fn))
        or not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
        or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
    v_bad := v_bad || v_fn || '; ';
  end if;
  -- the trigger's function: definer, the owner's, pinned, nobody's to call
  v_fn := 'cma.flash_current_forget()';
  if to_regprocedure(v_fn) is null then
    v_bad := v_bad || v_fn || ' missing; ';
  elsif not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
        or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
        or not (select 'search_path=pg_catalog, cma, pg_temp' = any (proconfig) from pg_proc where oid = to_regprocedure(v_fn))
        or has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
        or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
    v_bad := v_bad || v_fn || '; ';
  end if;
  foreach v_fn in array array['cma.flash_current_refresh_of(uuid,text,boolean)', 'cma.flash_current_lock_key(uuid,text)', 'cma.flash_watch_of(uuid,date,timestamptz)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  foreach v_fn in array array['cma.flash_document_of(uuid,text,text,date,date,date)', 'cma.flash_watch_of(uuid,date,timestamptz)',
                              'cma.flash_current_refresh_of(uuid,text,boolean)', 'cma.flash_current_refresh(uuid)'] loop
    if not coalesce((select 'jit=off' = any (proconfig) from pg_proc where oid = to_regprocedure(v_fn)), false) then
      v_bad := v_bad || v_fn || ' without jit=off; ';
    end if;
  end loop;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.flash_watch_finding'::regclass and conname = 'flash_watch_finding_kind_check')
     not like '%''dq_rise''%''current_stale''%' then
    v_bad := v_bad || 'the watch''s kinds; ';
  end if;
  if cma.flash_current_keys() is distinct from array['customers', 'subscriptions', 'installed_base', 'open_deals', 'open_tickets', 'open_tasks'] then
    v_bad := v_bad || 'the keys ' || coalesce(cma.flash_current_keys()::text, 'none') || '; ';
  end if;
  insert into verify_0009e values (3, 'S3 the functions: the application''s in the caller''s rights; the job''s entry definer, the owner''s, pinned; the writer the owner''s alone; JIT off; current_stale',
    case when v_bad = '' and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end, nullif(v_bad, ''));
end
$$;

-- S4. The settings and their trigger
do $$
declare
  v_txt text;
begin
  v_txt := (select string_agg(s.key || ':' || s.value_type || ':' || s.default_value, ' ' order by s.key collate "C") from cma.setting s
            where s.key in ('flash.current_overviews', 'flash.current_refresh_minutes'))
           || ' ' || coalesce((select string_agg(t.tgname, ',' order by t.tgname) from pg_trigger t
                               where t.tgrelid = 'cma.tenant_setting'::regclass and t.tgname in ('check_flash_current_setting', 'forget_flash_current_takes')
                                 and not t.tgisinternal), 'no trigger');
  insert into verify_0009e values (4, 'S4 the two settings with their types and defaults; the check trigger and the trigger that forgets a tenant''s takes on a setting change',
    case when v_txt = 'flash.current_overviews:text:installed_base flash.current_refresh_minutes:integer:5 check_flash_current_setting,forget_flash_current_takes'
              and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end, v_txt);
end
$$;

-- A. Behaviour on three throwaway tenants, always rolled back
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_t2 uuid; v_t3 uuid; v_reader1 uuid; v_reader2 uuid; v_role uuid; v_sched1 uuid; v_sched2 uuid; v_sched3 uuid;
  v_crm uuid; v_gb uuid; v_nl uuid; v_sgb uuid; v_snl uuid; v_reg uuid; v_reg2 uuid;
  v_all text := 'installed_base,customers,subscriptions,open_deals,open_tickets,open_tasks';
  v_bad text; v_txt text; v_n integer; v_m integer; v_today date; v_live bigint;
  r jsonb; v_new jsonb; v_old jsonb; v_diff text; k text; m text; v_docs integer;
begin
  begin
    v_t1 := cma.create_tenant('verify-0009e-one', 'Verify 0009e one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0009e-two', 'Verify 0009e two', 'Europe/Amsterdam');
    v_t3 := cma.create_tenant('verify-0009e-three', 'Verify 0009e three', 'Europe/Amsterdam');
    select u.id into v_sched1 from cma.app_user u where u.tenant_id = v_t1 and u.email = 'scheduler@system.invalid';
    select u.id into v_sched2 from cma.app_user u where u.tenant_id = v_t2 and u.email = 'scheduler@system.invalid';
    select u.id into v_sched3 from cma.app_user u where u.tenant_id = v_t3 and u.email = 'scheduler@system.invalid';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader-0009e@example.invalid', 'reader') returning id into v_reader1;
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id) values (v_t1, v_reader1, v_role);
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-reader-0009e@example.invalid', 'reader') returning id into v_reader2;
    insert into cma.app_role (tenant_id, key, name) values (v_t2, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t2, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id) values (v_t2, v_reader2, v_role);

    -- tenant one's sources (as 149's): a CRM, two stores with a subscriptions connection each, a register
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
      (v_t1, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10), (v_t1, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 20),
      (v_t1, 'FR', 'France', 'Europe/Paris', 'fr', 'EUR', 30);
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
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, orders_count) values
      (v_t1, v_gb, 'verifyshop', 'cu-1', 2), (v_t1, v_gb, 'verifyshop', 'cu-2', 1), (v_t1, v_nl, 'verifyshop', 'ncu-1', 1);
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, amount_per_cycle, currency,
                                  billing_interval, billing_interval_count, paused_at, source_created_at) values
      (v_t1, v_sgb, 'verifysubs', 's-1', 'cu-1', 'active', 20.00, 'GBP', 'month', 1, null, '2025-10-30 09:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-2', 'cu-2', 'active', 20.00, 'GBP', 'month', 1, null, '2025-10-31 00:30 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-3', 'cu-3', 'active', 20.00, 'GBP', 'month', 1, null, null),
      (v_t1, v_sgb, 'verifysubs', 's-5', 'cu-4', 'paused', 20.00, 'GBP', 'month', 1, now(), '2024-01-01 12:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-6', 'cu-5', 'canceled', 20.00, 'GBP', 'month', 1, null, '2024-01-01 12:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-7', 'cu-1', 'failed', 20.00, 'GBP', 'month', 1, null, '2025-06-15 12:00 Europe/Amsterdam'),
      (v_t1, v_snl, 'verifysubs', 'n-1', 'ncu-1', 'active', 30.00, 'EUR', 'month', 1, null, '2024-04-30 12:00 Europe/Amsterdam');
    insert into cma.device_model (tenant_id, key, name, sort_order) values (v_t1, 'm1', 'M1', 10), (v_t1, 'm2', 'M2', 20);
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked) values
      (v_t1, 'field', 'Field', true, false, true), (v_t1, 'stock', 'Stock', false, true, true);
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, subscription_ref)
    select v_t1, v_reg, 'verifyregister', x.rec, 'SN-' || x.rec, x.model, x.market, x.st, x.ref
    from (values ('d-1', 'm1', 'GB', 'field', 's-1'), ('d-2', 'm2', 'GB', 'field', 's-1'), ('d-3', 'm1', 'GB', 'stock', 's-1'),
                 ('d-4', 'm2', 'GB', 'field', 's-2'), ('d-5', 'm1', 'GB', 'field', 's-3'), ('d-8', 'm1', 'GB', 'field', 's-5'),
                 ('d-9', 'm2', 'GB', 'field', 's-6'), ('d-10', 'm1', 'GB', 'field', 'nope'), ('d-11', 'm2', 'GB', 'field', null),
                 ('d-12', 'm1', 'GB', 'stock', null), ('d-13', 'm1', 'GB', 'field', 's-7'), ('d-14', 'm2', null, 'field', null),
                 ('nd-1', 'm2', 'NL', 'field', 'n-1'), ('nd-2', 'm1', 'NL', 'field', 's-1')) as x(rec, model, market, st, ref);
    -- tenant two: a register of its own holding devices with tenant one's ids (none of them may count for tenant one)
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values (v_t2, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t2, 'verifyregister', 'Verify register two', 'base-2', 'assets') returning id into v_reg2;
    insert into cma.device_model (tenant_id, key, name, sort_order) values (v_t2, 'm1', 'M1', 10);
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked) values (v_t2, 'field', 'Field', true, false, true);
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, subscription_ref)
    select v_t2, v_reg2, 'verifyregister', 'd-' || g, 'SN-d-' || g, 'm1', 'GB', 'field', null from generate_series(1, 30) g;
    -- tenant one's setting: every stock overview but data quality keeps a take (written before any take: a setting change
    -- removes the tenant's takes)
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t1, 'flash.current_overviews', v_all);
    -- the additions recorded in the last day (158, just before this script) moved a day back inside this rolled-back block,
    -- so a take backdated by minutes below is not older than the latest migration; A4 checks that rule itself
    update cma.schema_migration set applied_at = applied_at - interval '1 day' where applied_at > now() - interval '1 day';
    v_today := cma.tenant_today_of(v_t1);

    -- A1. the setting checks (tenant three, as the owner)
    perform set_config('app.tenant_id', v_t3::text, true);
    -- one statement per write, each read after it (an expression's parts share one snapshot)
    v_txt := pg_temp.v0009e_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''flash.current_overviews'', '' installed_base , customers '')', v_t3));
    v_txt := v_txt || ' ' || coalesce((select ts.value from cma.tenant_setting ts where ts.tenant_id = v_t3 and ts.key = 'flash.current_overviews'), 'none');
    v_txt := v_txt || ' ' || pg_temp.v0009e_code(format('update cma.tenant_setting set value = '''' where tenant_id = %L and key = ''flash.current_overviews''', v_t3));
    v_txt := v_txt || ' ' || coalesce(array_to_string(cma.flash_current_overviews_of(v_t3), ','), 'null') || '.';
    v_txt := v_txt || ' ' || pg_temp.v0009e_code(format('update cma.tenant_setting set value = ''open_tasks,open_deals,open_tickets,subscriptions,customers,installed_base'' where tenant_id = %L and key = ''flash.current_overviews''', v_t3));
    foreach k in array array['orders', 'data_quality', 'nope', 'installed_base,installed_base', ',installed_base', 'installed_base,,customers', 'INSTALLED_BASE'] loop
      v_txt := v_txt || ' ' || pg_temp.v0009e_code(format('update cma.tenant_setting set value = %L where tenant_id = %L and key = ''flash.current_overviews''', k, v_t3));
    end loop;
    v_txt := v_txt || ' |';
    foreach k in array array['1', '1440', '0', '1441', 'x', '-5', '10000', ''] loop
      v_txt := v_txt || ' ' || pg_temp.v0009e_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''flash.current_refresh_minutes'', %L) on conflict (tenant_id, key) do update set value = excluded.value', v_t3, k));
    end loop;
    v_rows := v_rows || array['11', 'A1 the setting checks: stock overviews but data quality, each once, or nothing (CMA04 else); 1 to 1440 minutes (CMA04 else)',
      case when v_txt = 'ok installed_base,customers ok . ok CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 | ok ok CMA04 CMA04 CMA04 CMA04 CMA04 CMA04'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- A2. the refresh as the job runs it: the scheduler, the application's role, tenant one
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_sched1::text, true);
    r := cma.flash_current_refresh(v_t1);
    v_txt := (r ->> 'current_refreshed') || '/' || (r ->> 'current_fresh') || '/' || (r ->> 'current_running') || '/' || (r ->> 'current_failed');
    r := cma.flash_current_refresh(v_t1);
    v_txt := v_txt || ' ' || (r ->> 'current_refreshed') || '/' || (r ->> 'current_fresh') || '/' || (r ->> 'current_failed');
    v_txt := v_txt || ' ' || pg_temp.v0009e_code(format('select cma.flash_current_refresh(%L)', v_t2));
    perform set_config('app.user_id', v_reader1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0009e_code(format('select cma.flash_current_refresh(%L)', v_t1));
    -- tenant three: no source set up, so no take of the six overviews its setting names (A1 left them)
    perform set_config('app.tenant_id', v_t3::text, true);
    perform set_config('app.user_id', v_sched3::text, true);
    r := cma.flash_current_refresh(v_t3);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.user_id', v_sched1::text, true);
    v_txt := v_txt || ' | ' || (r ->> 'current_refreshed') || '/' || (r ->> 'current_not_set_up') || '/' || (select count(*) from cma.flash_current_take c where c.tenant_id = v_t3) || ' |';
    v_txt := v_txt || ' ' || pg_temp.v0009e_code(format('select cma.flash_current_refresh_of(%L, ''orders'', true)', v_t1))
             || ' ' || pg_temp.v0009e_code(format('select cma.flash_current_refresh_of(%L, ''data_quality'', true)', v_t1));
    -- every overview's take holds exactly cma.flash_compute_of's rows now, with its version and this transaction's instant
    v_bad := '';
    foreach k in array string_to_array(v_all, ',') loop
      if (select string_agg(c.dims::text || '=' || c.measures::text, ';' order by c.dims::text) from cma.flash_current_take c
          where c.tenant_id = v_t1 and c.overview = k and c.definition_version = cma.flash_definition_version(k) and c.computed_at = now())
         is distinct from (select string_agg(x.dims::text || '=' || x.measures::text, ';' order by x.dims::text) from cma.flash_compute_of(v_t1, k) x) then
        v_bad := v_bad || k || '; ';
      end if;
    end loop;
    select count(*) into v_n from cma.flash_current_take c where c.tenant_id = v_t1;
    v_rows := v_rows || array['12', 'A2 the job''s refresh: six takes, then all fresh; none where no source is set up; another tenant, a person without flash.snapshot and an overview without a take refused; each take cma.flash_compute_of''s rows',
      case when v_txt = '6/0/0/0 0/6/0 CMA06 CMA06 | 0/6/0 | CMA04 CMA04' and v_bad = '' and v_n > 6 and not v_provoke then 'ok' else 'FAIL' end,
      coalesce(nullif(v_bad, ''), v_txt || ', ' || v_n || ' rows')];

    -- A3. a fresh take equals the live document for the same instant, row for row, every set and market. Provoked: one
    -- take row differs, a deliberate difference the comparison must find
    if v_provoke then
      update cma.flash_current_take c set measures = jsonb_set(c.measures, '{devices}', to_jsonb((c.measures ->> 'devices')::integer + 1))
      where c.tenant_id = v_t1 and c.overview = 'installed_base' and c.dims = jsonb_build_object('market', 'GB', 'model', 'm1', 'subscription_status', 'active');
    end if;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_reader1::text, true);
    v_bad := ''; v_docs := 0;
    foreach k in array string_to_array(v_all, ',') loop
      foreach m in array array[null, 'GB', 'NL', 'FR', 'unknown'] loop
        -- both documents in one statement, so one snapshot: a read an ingest commits meanwhile cannot move the sources' last-read
        -- instants of one side (0009f, #251: prod's first run read D1 FAIL on sources alone)
        select cma.flash_overview(k, m), pg_temp.v0009e_document_0008zt(v_t1, k, m, null, null, null) into v_new, v_old;
        v_docs := v_docs + 1;
        v_diff := pg_temp.v0009e_diff(v_new - 'split_order' - 'refreshed_at', v_old);
        if v_diff is not null or (v_new ->> 'refreshed_at')::timestamptz is distinct from now() or v_old ? 'refreshed_at' then
          v_bad := v_bad || k || ' ' || coalesce(m, 'all') || ': ' || coalesce(v_diff, 'refreshed_at ' || coalesce(v_new ->> 'refreshed_at', 'none')) || '; ';
        end if;
      end loop;
    end loop;
    v_txt := (select string_agg((x -> 'dims')::text, ' ' order by (x -> 'dims')::text) from jsonb_array_elements(cma.flash_overview('installed_base', 'NL') -> 'rows') x);
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['13', 'A3 a fresh take equals the live document (0008zt''s definition) for the same instant, row for row: six overviews, all markets, each market, unknown, a market without rows',
      case when v_bad = '' and v_docs = 30 and not v_provoke then 'ok' else 'FAIL' end,
      case when v_bad = '' then v_docs || ' documents equal; NL rows ' || coalesce(v_txt, 'none') else left(v_bad, 600) end];

    -- A4. two tenants never see each other's take: tenant two's take altered; each reads its own rows and figures
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_sched2::text, true);
    perform cma.flash_current_refresh_of(v_t2, 'installed_base', true);
    update cma.flash_current_take c set measures = jsonb_set(c.measures, '{devices}', '7777'::jsonb) where c.tenant_id = v_t2 and c.dims = '{}'::jsonb;
    v_bad := '';
    -- the definer's take holds tenant one's rows alone, while tenant two holds devices with the same ids
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_sched1::text, true);
    perform cma.flash_current_refresh_of(v_t1, 'installed_base', true);
    if (select c.measures ->> 'devices' from cma.flash_current_take c where c.tenant_id = v_t1 and c.overview = 'installed_base' and c.dims = '{}'::jsonb) <> '14' then
      v_bad := v_bad || 'tenant one''s take counts another tenant''s devices; ';
    end if;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_reader1::text, true);
    select count(*), count(*) filter (where c.tenant_id = v_t1) into v_n, v_m from cma.flash_current_take c;
    v_txt := v_n || '=' || v_m || ' ' || (cma.flash_overview('installed_base') -> 'totals' ->> 'devices') || ' '
             || pg_temp.v0009e_code(format('select cma.flash_current_refresh(%L)', v_t2));
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_reader2::text, true);
    select count(*), count(*) filter (where c.tenant_id = v_t2) into v_n, v_m from cma.flash_current_take c;
    v_txt := v_txt || ' | ' || v_n || '=' || v_m || ' ' || (cma.flash_overview('installed_base') -> 'totals' ->> 'devices');
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['14', 'A4 two tenants never see each other''s take: each reads its own rows and figures; the definer''s take holds the tenant''s own devices; another tenant''s refresh refused',
      case when v_bad = '' and v_txt ~ '^([0-9]+)=\1 14 CMA06 \| 4=4 7777$' and not v_provoke then 'ok' else 'FAIL' end, coalesce(nullif(v_bad, ''), v_txt)];

    -- A5. the application cannot write the table nor run the writer
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_sched1::text, true);
    v_txt := pg_temp.v0009e_code(format('insert into cma.flash_current_take (tenant_id, overview, dims, measures, definition_version, computed_at) values (%L, ''installed_base'', ''{"market": "XX"}'', ''{"devices": 1}'', ''0008zt'', now())', v_t1))
             || ' ' || pg_temp.v0009e_code('update cma.flash_current_take set computed_at = now()')
             || ' ' || pg_temp.v0009e_code('delete from cma.flash_current_take')
             || ' ' || pg_temp.v0009e_code(format('select cma.flash_current_refresh_of(%L, ''installed_base'', true)', v_t1))
             || ' ' || pg_temp.v0009e_code('select cma.flash_current_lock_key(gen_random_uuid(), ''installed_base'')');
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['15', 'A5 the application cannot write the table (insert, update, delete) nor run the writer or its lock key',
      case when v_txt = '42501 42501 42501 42501 42501' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- A6. the watch: a take older than three times the setting opens current_stale; a fresh take resolves it; no take none
    perform set_config('app.user_id', v_sched1::text, true);
    update cma.flash_current_take c set computed_at = now() - interval '20 minutes' where c.tenant_id = v_t1 and c.overview = 'installed_base';
    r := cma.flash_watch_of(v_t1, v_today - 1, now());
    v_txt := (select string_agg(f.kind || ':' || f.overview || ':' || f.value || ':' || f.threshold || ':' || (f.detail ->> 'age_minutes'), ' ')
              from cma.flash_watch_finding f where f.tenant_id = v_t1 and f.state = 'open');
    perform cma.flash_current_refresh_of(v_t1, 'installed_base', true);
    r := cma.flash_watch_of(v_t1, v_today - 1, now());
    v_txt := coalesce(v_txt, 'none') || ' | ' || coalesce((select string_agg(f.kind || ':' || f.state || ':' || f.resolved_on, ' ') from cma.flash_watch_finding f where f.tenant_id = v_t1), 'none');
    delete from cma.flash_current_take c where c.tenant_id = v_t1;
    r := cma.flash_watch_of(v_t1, v_today - 1, now());
    v_txt := v_txt || ' | ' || (select count(*) from cma.flash_watch_finding f where f.tenant_id = v_t1 and f.state = 'open');
    v_rows := v_rows || array['16', 'A6 the watch: a take older than three times the setting opens current_stale (age 20, threshold 15); a fresh take resolves it; no take opens none',
      case when v_txt = 'current_stale:installed_base:20:15:20 | current_stale:resolved:' || (v_today - 1) || ' | 0' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- A7. the fallback, on tenant one's installed base: the take's figures marked (devices 9999 in its totals) so a read
    -- of the take is told from a live one (14 devices)
    perform cma.flash_current_refresh_of(v_t1, 'installed_base', true);
    update cma.flash_current_take c set measures = jsonb_set(c.measures, '{devices}', '9999'::jsonb) where c.tenant_id = v_t1 and c.overview = 'installed_base' and c.dims = '{}'::jsonb;
    v_live := (pg_temp.v0009e_document_0008zt(v_t1, 'installed_base', null, null, null, null) -> 'totals' ->> 'devices')::bigint;
    v_txt := '';
    foreach v_n in array array[4, 6, 14, 16] loop
      update cma.flash_current_take c set computed_at = now() - make_interval(mins => v_n) where c.tenant_id = v_t1 and c.overview = 'installed_base';
      v_new := cma.flash_document_of(v_t1, 'installed_base', null, null, null, null);
      v_txt := v_txt || v_n || ':' || cma.flash_current_state_of(v_t1, 'installed_base', now() - make_interval(mins => v_n), cma.flash_definition_version('installed_base'), now())
               || ':' || (v_new -> 'totals' ->> 'devices') || ':' || case when (v_new ->> 'refreshed_at')::timestamptz = now() - make_interval(mins => v_n) then 'take'
                                                                        when v_new ->> 'refreshed_at' is null and (v_new ->> 'as_of')::timestamptz = now() then 'live' else '?' end || ' ';
    end loop;
    -- the live read at 16 minutes is 0008zt's document exactly
    v_diff := pg_temp.v0009e_diff(cma.flash_document_of(v_t1, 'installed_base', 'GB', null, null, null) - 'refreshed_at',
                                  pg_temp.v0009e_document_0008zt(v_t1, 'installed_base', 'GB', null, null, null));
    v_txt := v_txt || coalesce(v_diff, 'equal') || ' |';
    -- another definition version, one minute old
    update cma.flash_current_take c set computed_at = now() - interval '1 minute', definition_version = '0000a' where c.tenant_id = v_t1 and c.overview = 'installed_base';
    v_txt := v_txt || ' version:' || cma.flash_current_state_of(v_t1, 'installed_base', now() - interval '1 minute', '0000a', now())
             || ':' || (cma.flash_document_of(v_t1, 'installed_base', null, null, null, null) -> 'totals' ->> 'devices');
    update cma.flash_current_take c set definition_version = cma.flash_definition_version('installed_base') where c.tenant_id = v_t1 and c.overview = 'installed_base';
    v_txt := v_txt || ' back:' || (cma.flash_document_of(v_t1, 'installed_base', null, null, null, null) -> 'totals' ->> 'devices');
    -- a setting written after the take removes the tenant's takes (now live), and so does a setting reset (its row deleted)
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t1, 'flash.watch_jump_pct', '25');
    v_txt := v_txt || ' setting:' || (select count(*) from cma.flash_current_take c where c.tenant_id = v_t1);
    v_txt := v_txt || ':' || (cma.flash_document_of(v_t1, 'installed_base', null, null, null, null) -> 'totals' ->> 'devices');
    perform cma.flash_current_refresh_of(v_t1, 'installed_base', true);
    delete from cma.tenant_setting ts where ts.tenant_id = v_t1 and ts.key = 'flash.watch_jump_pct';
    v_txt := v_txt || ' reset:' || (select count(*) from cma.flash_current_take c where c.tenant_id = v_t1);
    v_txt := v_txt || ':' || (cma.flash_document_of(v_t1, 'installed_base', null, null, null, null) -> 'totals' ->> 'devices');
    -- a migration recorded after the take (now), then moved back
    perform cma.flash_current_refresh_of(v_t1, 'installed_base', true);
    update cma.flash_current_take c set measures = jsonb_set(c.measures, '{devices}', '9999'::jsonb)
    where c.tenant_id = v_t1 and c.overview = 'installed_base' and c.dims = '{}'::jsonb;
    update cma.flash_current_take c set computed_at = now() - interval '1 minute' where c.tenant_id = v_t1 and c.overview = 'installed_base';
    update cma.schema_migration set applied_at = now() where version = '0009e';
    v_txt := v_txt || ' migration:' || cma.flash_current_state_of(v_t1, 'installed_base', now() - interval '1 minute', cma.flash_definition_version('installed_base'), now())
             || ':' || (cma.flash_document_of(v_t1, 'installed_base', null, null, null, null) -> 'totals' ->> 'devices');
    update cma.schema_migration set applied_at = now() - interval '1 day' where version = '0009e';
    -- no take
    delete from cma.flash_current_take c where c.tenant_id = v_t1 and c.overview = 'installed_base';
    v_new := cma.flash_document_of(v_t1, 'installed_base', null, null, null, null);
    v_txt := v_txt || ' none:' || cma.flash_current_state_of(v_t1, 'installed_base', null, null, now()) || ':' || (v_new -> 'totals' ->> 'devices')
             || ':' || coalesce(v_new ->> 'refreshed_at', 'null');
    -- the overview taken out of the setting: off and live; the next refresh removes its take
    perform cma.flash_current_refresh_of(v_t1, 'installed_base', true);
    update cma.tenant_setting ts set value = 'customers' where ts.tenant_id = v_t1 and ts.key = 'flash.current_overviews';
    v_new := cma.flash_document_of(v_t1, 'installed_base', null, null, null, null);
    v_txt := v_txt || ' off:' || cma.flash_current_state_of(v_t1, 'installed_base', now(), cma.flash_definition_version('installed_base'), now())
             || ':' || coalesce(v_new ->> 'refreshed_at', 'null');
    r := cma.flash_current_refresh(v_t1);
    v_txt := v_txt || ':' || (select count(*) from cma.flash_current_take c where c.tenant_id = v_t1 and c.overview = 'installed_base')
             || ':' || (r ->> 'current_refreshed');
    v_rows := v_rows || array['17', 'A7 the fallback: fresh, usable (the take read), stale at 16 minutes (live, 0008zt''s document); another version, a setting written or reset (the takes removed), a later migration, no take, out of the setting: live',
      case when v_txt = '4:fresh:9999:take 6:usable:9999:take 14:usable:9999:take 16:stale:' || v_live || ':live equal | version:outdated:' || v_live
                        || ' back:9999 setting:0:' || v_live || ' reset:0:' || v_live || ' migration:outdated:' || v_live || ' none:none:' || v_live || ':null off:off:null:0:1'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['29', 'A the block ran to the end', 'FAIL', sqlstate || ' ' || sqlerrm];
  end;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0009e select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if not exists (select 1 from verify_0009e where ord between 11 and 29) then
    insert into verify_0009e values (29, 'A the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- D. Every active tenant: a fresh take of each stock overview of its setting that is set up, refreshed as its scheduler
-- (with the owner's rights, as the job's entry runs it), equals the live document for every market; rolled back
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  t record; k text; m text; v_sched uuid; v_markets text[];
  v_bad text := ''; v_tenants integer := 0; v_takes integer := 0; v_before integer; v_docs integer := 0; v_diff text; v_new jsonb;
begin
  begin
    for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
      perform set_config('app.tenant_id', t.id::text, true);
      select u.id into v_sched from cma.app_user u where u.tenant_id = t.id and u.email = 'scheduler@system.invalid' and u.status = 'active';
      continue when v_sched is null;
      perform set_config('app.user_id', v_sched::text, true);
      v_before := v_takes;
      foreach k in array cma.flash_current_overviews_of(t.id) loop
        continue when not coalesce(cma.flash_source_set_up_of(t.id, (select o.source from cma.flash_overviews() o where o.key = k)), false);
        perform cma.flash_current_refresh_of(t.id, k, true);
        v_takes := v_takes + 1;
        select array_agg(distinct c.dims ->> 'market' order by c.dims ->> 'market') into v_markets
        from cma.flash_current_take c where c.tenant_id = t.id and c.overview = k and c.dims ? 'market';
        foreach m in array array[null::text, 'unknown'] || coalesce(v_markets, '{}'::text[]) loop
          -- both documents in one statement (one snapshot), as A3: a concurrent ingest cannot move one side's sources (0009f, #251)
          select x.d, pg_temp.v0009e_diff(x.d - 'refreshed_at', x.o) into v_new, v_diff
          from (select cma.flash_document_of(t.id, k, m, null, null, null) as d, pg_temp.v0009e_document_0008zt(t.id, k, m, null, null, null) as o) x;
          v_docs := v_docs + 1;
          if v_diff is not null or v_new ->> 'refreshed_at' is null then
            v_bad := v_bad || t.slug || ' ' || k || ' ' || coalesce(m, 'all') || ': ' || coalesce(v_diff, 'not read from the take') || '; ';
          end if;
        end loop;
      end loop;
      if v_takes > v_before then v_tenants := v_tenants + 1; end if;
    end loop;
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_bad := v_bad || 'ended early: ' || sqlstate || ' ' || left(sqlerrm, 200);
  end;
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  insert into verify_0009e values (31, 'D1 every active tenant: a fresh take of each stock overview of its setting that is set up equals the live document (0008zt''s definition) for every market; rolled back',
    case when v_provoke then 'FAIL' when v_bad <> '' then 'FAIL' when v_takes = 0 then 'skip' else 'ok' end,
    case when v_bad <> '' then left(v_bad, 600) when v_takes = 0 then 'no tenant with a stock overview of its setting set up'
         else v_tenants || ' tenant(s), ' || v_takes || ' take(s), ' || v_docs || ' documents equal' end);
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009e_diff(jsonb, jsonb);
drop function if exists pg_temp.v0009e_code(text);
drop function if exists pg_temp.v0009e_document_0008zt(uuid,text,text,date,date,date);

-- Verdict: one row per check, then the verdict: no FAIL, a skip only where the check says why
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009e
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from verify_0009e where result not in ('ok', 'skip')) then 'FAIL'
                  when (select count(*) from verify_0009e where result = 'ok') >= 11 then '0009e verified'
                  else 'FAIL' end,
             format('159_verify_flash_current_take: %s ok, %s FAIL, %s skip', (select count(*) from verify_0009e where result = 'ok'),
                    (select count(*) from verify_0009e where result not in ('ok', 'skip')),
                    (select count(*) from verify_0009e where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0009e;
reset role;
