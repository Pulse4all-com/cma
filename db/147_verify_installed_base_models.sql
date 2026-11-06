-- =============================================================================================
-- 147_verify_installed_base_models.sql: verifies addition 0008zy, Installed base by model (the In the field split, the
-- Model filter's set)
-- =============================================================================================
-- Blocks S check the addition and its functions (universal). Block A works on a throwaway tenant inside a subtransaction
-- that is always rolled back, so nothing stays; block D reads every active tenant's own data and writes nothing. The
-- script runs alike in dev and in prod. Every check writes one row, ok or FAIL, and the last row is the verdict, because
-- Cloud SQL Studio shows no notices: "0008zy verified | 147_verify_installed_base_models: 12 ok, 0 FAIL, 0 skip" (a D
-- check reads skip for a database without a tenant whose asset register is set up). Run as your own IAM login after
-- 146_installed_base_models.sql, dev first, then prod; then 123, 137, 139 and 143 again.
--   S1  the addition 0008zy is recorded after 0008zw
--   S2  privileges: every remade function the application's only, in the caller's rights, nothing for the readers;
--       cma.flash_compute_of keeps JIT off
--   S3  the catalog: installed_base's sets [], [market], [market, status, model, warehouse, link], [market, model,
--       subscription_status]; its split by model over [market, status, model, warehouse, link]; its definition still
--       0008zt; the other overviews' splits as 0008zw left them
--   A1  the split's order: the register's active models by sort order, then key (an inactive model left out); a tenant
--       without models: none first
--   A2  the split's helper on given rows: In the field summed over the other dims, the register's models with zeros, an
--       inactive model and unknown after them only above 0, each part with its model's name (none for unknown), one
--       market or all; other sets never counted
--   A3  the live headline (as the tenant's reader): In the field and its split per model adding up, in all and per market
--   A4  the new set: [market, model, subscription_status] rows summed over the models are the market's subscription-status
--       figures, and summed over the statuses each model's figures of [market, status, model, warehouse, link]
--   A5  as of a date: the stored rows' split (cma.flash_page); none for a date whose snapshot holds no row of the set
--   A6  the document's split_order: the register's models (installed_base), the order kinds (orders), none (customers)
--   D1  every tenant with an asset register: the split adds up to In the field, in all and per market
--   D2  every such tenant: the installed base's rows other than the new set are 0008zu's computation (kept below as
--       pg_temp.v0008zy_base_0008zu), row for row, and the new set summed over the models is 0008zu's [market,
--       subscription_status] rows
--   D3  every such tenant: each model's figures from [market, status, model, warehouse, link] add up to the totals, so a
--       Model filter's figures from that set are exact; in_field_on_holding per model the same from either set
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

drop table if exists pg_temp.verify_0008zy;
create temp table verify_0008zy (ord int, check_name text, result text, detail text);

-- A split ([{key, value, label}]) as one line: "key value (label)" parts in order; none when there is no split
create or replace function pg_temp.v0008zy_split(p_split jsonb)
returns text
language sql
as $$
  select coalesce(string_agg((x ->> 'key') || ' ' || (x ->> 'value') || coalesce(' (' || (x ->> 'label') || ')', ''), ', ' order by o),
                  case when p_split is null or jsonb_typeof(p_split) = 'null' then 'none' else '' end)
  from jsonb_array_elements(case when jsonb_typeof(p_split) = 'array' then p_split else '[]'::jsonb end) with ordinality u(x, o)
$$;

-- An overview's rows exactly as computed (live, or as of a date)
create or replace function pg_temp.v0008zy_rows(p_tenant uuid, p_on date)
returns jsonb
language sql
as $$
  select coalesce(jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures)), '[]'::jsonb)
  from cma.flash_compute_of(p_tenant, 'installed_base', null, null, p_on) c
$$;

-- 0008zu's computation of the installed base (138's branch of cma.flash_compute_of), kept for the comparison (D2)
create or replace function pg_temp.v0008zy_base_0008zu(p_tenant_id uuid, p_on date)
returns table (dims jsonb, measures jsonb)
language plpgsql
as $$
declare
  v_on      date := coalesce(p_on, cma.tenant_today_of(p_tenant_id));
  v_holding text[] := cma.flash_holding_statuses_of(p_tenant_id);
begin
  return query
    select case when grouping(b.market) = 1 then '{}'::jsonb
                when grouping(b.status) = 0
                then jsonb_build_object('market', b.market, 'status', b.status, 'model', b.model, 'warehouse', b.warehouse, 'link', b.link)
                when grouping(b.subscription_status) = 0 then jsonb_build_object('market', b.market, 'subscription_status', b.subscription_status)
                else jsonb_build_object('market', b.market) end,
           jsonb_build_object('devices', count(*), 'in_field', count(*) filter (where b.is_in_field),
                              'in_stock', count(*) filter (where b.is_in_stock), 'components_past_due', coalesce(sum(b.past_due_items), 0),
                              'items_due_3m', coalesce(sum(b.items_due_3m), 0),
                              'in_field_on_holding', count(*) filter (where b.is_in_field and b.subscription_status = any (v_holding)))
    from cma.flash_devices_of(p_tenant_id, v_on) b
    group by grouping sets ((), (b.market), (b.market, b.status, b.model, b.warehouse, b.link), (b.market, b.subscription_status));
end
$$;

-- Where the rows differ from 0008zu's: every row of a set other than the subscription-status one, row for row; the
-- subscription-status rows summed over the models against 0008zu's [market, subscription_status] rows. Empty when equal
create or replace function pg_temp.v0008zy_differs(p_tenant uuid)
returns text
language sql
as $$
  with n as (
    select c.dims, c.measures from cma.flash_compute_of(p_tenant, 'installed_base', null, null, null) c
  ), o as (
    select x.dims, x.measures from pg_temp.v0008zy_base_0008zu(p_tenant, null) x
  ), n_kept as (
    select n.dims, n.measures from n where not (n.dims ? 'subscription_status')
    union all
    select jsonb_build_object('market', s.market, 'subscription_status', s.st), jsonb_object_agg(s.k, s.v)
    from (select n.dims ->> 'market' as market, n.dims ->> 'subscription_status' as st, e.key as k, sum((e.value #>> '{}')::numeric) as v
          from n cross join lateral jsonb_each(n.measures) e
          where n.dims ? 'subscription_status' and n.dims ? 'model'
          group by 1, 2, 3) s
    group by s.market, s.st
  )
  select coalesce(string_agg(coalesce(a.dims, b.dims)::text, '; '), '')
  from n_kept a full join o b on a.dims = b.dims
  where a.dims is null or b.dims is null or a.measures <> b.measures
$$;

-- S1. The addition
do $$
begin
  insert into verify_0008zy values (1, 'S1 addition 0008zy recorded, after 0008zw',
    case when exists (select 1 from cma.schema_migration where version = '0008zy')
              and exists (select 1 from cma.schema_migration where version = '0008zw')
              and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end,
    case when current_setting('verify.provoke')::boolean then 'provoked' else '' end);
end
$$;

-- S2. Privileges: the application's only, the caller's rights, nothing for the readers; JIT off on the computation
do $$
declare
  v_bad text := '';
  v_fn  text;
begin
  foreach v_fn in array array[
    'cma.flash_overviews()', 'cma.flash_compute_of(uuid,text,date,date,date)', 'cma.flash_split_dim_of(text)', 'cma.flash_split_set_of(text)',
    'cma.flash_split_order_of(uuid,text)', 'cma.flash_headline_split_of(uuid,text,jsonb,text)', 'cma.flash_overview(text,text,date,date,date)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  if not coalesce((select 'jit=off' = any (proconfig) from pg_proc where oid = to_regprocedure('cma.flash_compute_of(uuid,text,date,date,date)')), false) then
    v_bad := v_bad || 'cma.flash_compute_of jit; ';
  end if;
  insert into verify_0008zy values (2, 'S2 privileges: the application''s only, the caller''s rights, nothing for the readers; JIT off on the computation',
    case when v_bad = '' and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end, v_bad);
end
$$;

-- S3. The catalog
do $$
declare
  v_txt text;
begin
  select o.sets::text || ' ' || cma.flash_definition_version('installed_base') || ' '
         || (select string_agg(x.key || ':' || coalesce(cma.flash_split_dim_of(x.key), '-') || ':' || coalesce(array_to_string(cma.flash_split_set_of(x.key), '/'), '-'),
                               ',' order by x.sort_order) from cma.flash_overviews() x where cma.flash_split_dim_of(x.key) is not null)
    into v_txt
  from cma.flash_overviews() o where o.key = 'installed_base';
  insert into verify_0008zy values (3, 'S3 the catalog: installed_base''s sets with [market, model, subscription_status]; its split by model; definition 0008zt; the other splits as 0008zw',
    case when v_txt = '[[], ["market"], ["market", "status", "model", "warehouse", "link"], ["market", "model", "subscription_status"]] 0008zt '
                      || 'subscriptions:status:market/status,installed_base:model:market/status/model/warehouse/link,orders:kind:market/store/kind'
              and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end, v_txt);
end
$$;

-- A. Behaviour on a throwaway tenant, always rolled back
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_t2 uuid; v_reader uuid; v_role uuid; v_reg uuid; v_run uuid;
  j jsonb; v_r jsonb;
  v_txt text; v_exp text; v_bad text;
  m text;
begin
  begin
    v_t1 := cma.create_tenant('verify-0008zy-one', 'Verify 0008zy one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zy-two', 'Verify 0008zy two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader-0008zy@example.invalid', 'reader') returning id into v_reader;
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id) values (v_t1, v_reader, v_role);
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
      (v_t1, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10), (v_t1, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 20);
    -- the register: Model B first (sort 10), Model A (sort 20), Model C inactive
    insert into cma.device_model (tenant_id, key, name, sort_order, status) values
      (v_t1, 'ma', 'Model A', 20, 'active'), (v_t1, 'mb', 'Model B', 10, 'active'), (v_t1, 'mc', 'Model C', 30, 'inactive');
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked) values
      (v_t1, 'field', 'Field', true, false, true), (v_t1, 'stock', 'Stock', false, true, true);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyregister', 'Verify register', 'base-0008zy', 'assets') returning id into v_reg;
    -- in the field: GB Model A twice, Model B once, Model C (inactive) once; NL Model A once and one without a model; in
    -- stock: GB Model B, NL Model B
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key) values
      (v_t1, v_reg, 'verifyregister', 'd-1', 'SN-1', 'ma', 'GB', 'field'), (v_t1, v_reg, 'verifyregister', 'd-2', 'SN-2', 'ma', 'GB', 'field'),
      (v_t1, v_reg, 'verifyregister', 'd-3', 'SN-3', 'mb', 'GB', 'field'), (v_t1, v_reg, 'verifyregister', 'd-4', 'SN-4', 'mb', 'GB', 'stock'),
      (v_t1, v_reg, 'verifyregister', 'd-5', 'SN-5', 'ma', 'NL', 'field'), (v_t1, v_reg, 'verifyregister', 'd-6', 'SN-6', null, 'NL', 'field'),
      (v_t1, v_reg, 'verifyregister', 'd-7', 'SN-7', 'mc', 'GB', 'field'), (v_t1, v_reg, 'verifyregister', 'd-8', 'SN-8', 'mb', 'NL', 'stock');

    -- A1. the split's order
    v_txt := coalesce(array_to_string(cma.flash_split_order_of(v_t1, 'installed_base'), ','), 'null')
             || ' | ' || coalesce(array_to_string(cma.flash_split_order_of(v_t2, 'installed_base'), ','), 'null')
             || ' | ' || coalesce(array_to_string(cma.flash_split_order_of(v_t1, 'customers'), ','), 'null');
    v_rows := v_rows || array['11', 'A1 the split''s order: the register''s active models by sort order then key, an inactive one left out; none without models; none for another overview',
      case when v_txt = 'mb,ma |  | null' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- A2. the split's helper on given rows
    v_r := '[{"dims": {}, "measures": {"in_field": 9}}, {"dims": {"market": "GB"}, "measures": {"in_field": 6}},
      {"dims": {"market": "GB", "status": "field", "model": "ma", "warehouse": "none", "link": "linked"}, "measures": {"in_field": 2}},
      {"dims": {"market": "GB", "status": "field", "model": "ma", "warehouse": "none", "link": "none"}, "measures": {"in_field": 1}},
      {"dims": {"market": "GB", "status": "stock", "model": "mb", "warehouse": "WH-A", "link": "none"}, "measures": {"in_field": 0}},
      {"dims": {"market": "GB", "status": "field", "model": "mc", "warehouse": "none", "link": "none"}, "measures": {"in_field": 3}},
      {"dims": {"market": "NL", "status": "field", "model": "unknown", "warehouse": "none", "link": "none"}, "measures": {"in_field": 2}},
      {"dims": {"market": "NL", "status": "field", "model": "zz", "warehouse": "none", "link": "none"}, "measures": {"in_field": 0}},
      {"dims": {"market": "GB", "model": "ma", "subscription_status": "none"}, "measures": {"in_field": 40}},
      {"dims": {"market": "GB", "status": "field", "model": "ma", "warehouse": "none", "link": "none", "extra": "x"}, "measures": {"in_field": 50}}]';
    v_txt := pg_temp.v0008zy_split(cma.flash_headline_split_of(v_t1, 'installed_base', v_r, null))
             || ' | ' || pg_temp.v0008zy_split(cma.flash_headline_split_of(v_t1, 'installed_base', v_r, 'GB'))
             || ' | ' || pg_temp.v0008zy_split(cma.flash_headline_split_of(v_t1, 'installed_base', v_r, 'NL'))
             || ' | ' || pg_temp.v0008zy_split(cma.flash_headline_split_of(v_t1, 'installed_base', '[]', null));
    v_exp := 'mb 0 (Model B), ma 3 (Model A), mc 3 (Model C), unknown 2 | mb 0 (Model B), ma 3 (Model A), mc 3 (Model C) | mb 0 (Model B), ma 0 (Model A), unknown 2'
             || ' | mb 0 (Model B), ma 0 (Model A)';
    v_rows := v_rows || array['12', 'A2 the split''s helper: summed over the other dims, the register''s models with zeros, an inactive model and unknown only above 0, the register''s names, one market or all, other sets never counted',
      case when v_txt = v_exp and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- A3. the live headline, as the reader
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_reader::text, true);
    v_txt := '';
    foreach m in array array['*', 'GB', 'NL'] loop
      j := cma.flash_headline('installed_base', nullif(m, '*'));
      v_txt := v_txt || m || ' ' || (j ->> 'value') || ' ' || pg_temp.v0008zy_split(j -> 'split') || ' | ';
    end loop;
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['13', 'A3 the live headline: In the field and its split per model adding up, in all and per market (an inactive model and unknown only where they have devices)',
      case when v_txt = '* 6 mb 1 (Model B), ma 3 (Model A), mc 1 (Model C), unknown 1 | GB 4 mb 1 (Model B), ma 2 (Model A), mc 1 (Model C) | NL 2 mb 0 (Model B), ma 1 (Model A), unknown 1 | '
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- A4. the new set's rows: per market, model and subscription status, adding up both ways
    v_r := pg_temp.v0008zy_rows(v_t1, null);
    v_txt := (select string_agg((r -> 'dims' ->> 'market') || '/' || (r -> 'dims' ->> 'model') || '/' || (r -> 'dims' ->> 'subscription_status') || ':'
                                || (r -> 'measures' ->> 'devices') || ',' || (r -> 'measures' ->> 'in_field'), ' '
                                order by r -> 'dims' ->> 'market', r -> 'dims' ->> 'model')
              from jsonb_array_elements(v_r) r where r -> 'dims' ? 'subscription_status');
    v_bad := (select coalesce(string_agg(coalesce(a.k, b.k) || ' ' || coalesce(a.v, 0) || '<>' || coalesce(b.v, 0), ' '), '')
              from (select (r -> 'dims' ->> 'market') || '/' || (r -> 'dims' ->> 'model') as k, sum((r -> 'measures' ->> 'in_field')::numeric) as v
                    from jsonb_array_elements(v_r) r where r -> 'dims' ? 'subscription_status' group by 1) a
              full join (select (r -> 'dims' ->> 'market') || '/' || (r -> 'dims' ->> 'model') as k, sum((r -> 'measures' ->> 'in_field')::numeric) as v
                         from jsonb_array_elements(v_r) r where r -> 'dims' ? 'warehouse' group by 1) b on b.k = a.k
              where a.v is distinct from b.v);
    v_rows := v_rows || array['14', 'A4 the new set: per market, model and subscription status; summed over the statuses each model''s figures of [market, status, model, warehouse, link]',
      case when v_txt = 'GB/ma/none:2,2 GB/mb/none:2,1 GB/mc/none:1,1 NL/ma/none:1,1 NL/mb/none:1,0 NL/unknown/none:1,1' and v_bad = '' and not v_provoke then 'ok' else 'FAIL' end,
      v_txt || case when v_bad <> '' then ' | differs: ' || v_bad else '' end];

    -- A5. as of a date: 31 October stored as computed (a take stores these rows), 30 October with the totals and the
    -- [market] rows only (a snapshot without the set's rows)
    foreach m in array array['2026-10-30', '2026-10-31'] loop
      insert into cma.flash_snapshot_run (id, tenant_id, snapshot_date, due_at, started_at, finished_at, status, sources)
      values (uuidv7(), v_t1, m::date, cma.flash_due_at_of('Europe/Amsterdam', '00:30', m::date), now(), now(), 'succeeded',
              '{"assets": {"set_up": true, "last_read_at": null, "adapters": ["verifyregister"]}}')
      returning id into v_run;
      insert into cma.flash_snapshot (tenant_id, snapshot_date, overview, dims, measures, definition_version, computed_at, run_id)
      select v_t1, m::date, 'installed_base', c.dims, c.measures, cma.flash_definition_version('installed_base'), now(), v_run
      from cma.flash_compute_of(v_t1, 'installed_base', null, null, m::date) c
      where m::date = '2026-10-31' or c.dims = '{}'::jsonb or c.dims = jsonb_build_object('market', c.dims ->> 'market');
    end loop;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_reader::text, true);
    v_txt := '';
    foreach m in array array['*', 'GB'] loop
      select c into j from jsonb_array_elements(cma.flash_page(nullif(m, '*'), '2026-10-31', null, null) -> 'overviews') c where c ->> 'key' = 'installed_base';
      v_txt := v_txt || m || ' ' || (j ->> 'value') || ' ' || pg_temp.v0008zy_split(j -> 'split') || ' | ';
    end loop;
    select c into j from jsonb_array_elements(cma.flash_page(null, '2026-10-30', null, null) -> 'overviews') c where c ->> 'key' = 'installed_base';
    v_txt := v_txt || '30 ' || (j ->> 'value') || ' ' || pg_temp.v0008zy_split(j -> 'split');
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['15', 'A5 as of a date: the stored rows'' split per model, per market too; none for a snapshot without the set''s rows',
      case when v_txt = '* 6 mb 1 (Model B), ma 3 (Model A), mc 1 (Model C), unknown 1 | GB 4 mb 1 (Model B), ma 2 (Model A), mc 1 (Model C) | 30 6 none'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- A6. the document's split_order, as the reader
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_reader::text, true);
    v_txt := (cma.flash_overview('installed_base') -> 'split_order')::text || ' ' || (cma.flash_overview('orders') -> 'split_order')::text
             || ' ' || (cma.flash_overview('customers') -> 'split_order')::text
             || ' ' || (cma.flash_overview('installed_base', null, '2026-10-31') -> 'split_order')::text;
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['16', 'A6 the document''s split_order: the register''s models, the order kinds, none for an overview without a split; as of a date too',
      case when v_txt = '["mb", "ma"] ["first", "renewal", "repeat"] null ["mb", "ma"]' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['29', 'A the block ran to the end', 'FAIL', sqlstate || ' ' || sqlerrm];
  end;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0008zy select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if not exists (select 1 from verify_0008zy where ord between 11 and 29) then
    insert into verify_0008zy values (29, 'A the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- D. Every tenant with an asset register, read only (as the owner, the tenant named on every read)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  t record; m text;
  v_r jsonb; v_split jsonb; v_fig numeric;
  v_bad1 text := ''; v_bad2 text := ''; v_bad3 text := '';
  v_tenants integer := 0;
begin
  for t in select x.id, x.slug from cma.tenant x
           where x.status = 'active' and coalesce((cma.flash_sources_of(x.id) -> 'assets' ->> 'set_up')::boolean, false)
           order by x.slug collate "C" loop
    v_tenants := v_tenants + 1;
    v_r := pg_temp.v0008zy_rows(t.id, null);
    -- D1. the split adds up to In the field, in all and per market
    foreach m in array array['*'] || coalesce((select array_agg(distinct r -> 'dims' ->> 'market') from jsonb_array_elements(v_r) r where r -> 'dims' ? 'market'), '{}') loop
      v_split := cma.flash_headline_split_of(t.id, 'installed_base', v_r, nullif(m, '*'));
      v_fig := (select (r -> 'measures' ->> 'in_field')::numeric from jsonb_array_elements(v_r) r
                where r -> 'dims' = case when m = '*' then '{}'::jsonb else jsonb_build_object('market', m) end);
      if coalesce(v_fig, 0) <> coalesce((select sum((x ->> 'value')::numeric) from jsonb_array_elements(v_split) x), -1) then
        v_bad1 := v_bad1 || t.slug || ' ' || m || ' ' || coalesce(v_fig, 0) || '<>' || pg_temp.v0008zy_split(v_split) || '; ';
      end if;
    end loop;
    -- D2. 0008zu's computation, row for row and the new set summed over the models
    if pg_temp.v0008zy_differs(t.id) <> '' then
      v_bad2 := v_bad2 || t.slug || ': ' || left(pg_temp.v0008zy_differs(t.id), 300) || '; ';
    end if;
    -- D3. each model's figures of the big set add up to the totals; in_field_on_holding per model the same from either set
    if exists (
      select 1 from jsonb_array_elements(v_r) tot cross join lateral jsonb_each(tot -> 'measures') e
      where tot -> 'dims' = '{}'::jsonb
        and (e.value #>> '{}')::numeric <> coalesce((select sum((b -> 'measures' ->> e.key)::numeric) from jsonb_array_elements(v_r) b
                                                     where b -> 'dims' ? 'warehouse'), 0))
       or exists (
      select 1 from (select b -> 'dims' ->> 'model' as model, sum((b -> 'measures' ->> 'in_field_on_holding')::numeric) as v
                     from jsonb_array_elements(v_r) b where b -> 'dims' ? 'warehouse' group by 1) x
      full join (select s -> 'dims' ->> 'model' as model, sum((s -> 'measures' ->> 'in_field_on_holding')::numeric) as v
                 from jsonb_array_elements(v_r) s where s -> 'dims' ? 'subscription_status' group by 1) y on x.model = y.model
      where x.v is distinct from y.v) then
      v_bad3 := v_bad3 || t.slug || '; ';
    end if;
  end loop;
  insert into verify_0008zy values
    (31, 'D1 every tenant with an asset register: the split adds up to In the field, in all and per market',
     case when v_tenants = 0 then 'skip' when v_bad1 = '' and not v_provoke then 'ok' else 'FAIL' end,
     case when v_tenants = 0 then 'no tenant with an asset register set up' when v_bad1 = '' then v_tenants || ' tenant(s)' else v_bad1 end),
    (32, 'D2 every such tenant: the installed base''s rows are 0008zu''s, the new set summed over the models its [market, subscription_status] rows',
     case when v_tenants = 0 then 'skip' when v_bad2 = '' and not v_provoke then 'ok' else 'FAIL' end,
     case when v_tenants = 0 then 'no tenant with an asset register set up' when v_bad2 = '' then v_tenants || ' tenant(s)' else v_bad2 end),
    (33, 'D3 every such tenant: the models'' figures of [market, status, model, warehouse, link] add up to the totals; in_field_on_holding per model the same from either set',
     case when v_tenants = 0 then 'skip' when v_bad3 = '' and not v_provoke then 'ok' else 'FAIL' end,
     case when v_tenants = 0 then 'no tenant with an asset register set up' when v_bad3 = '' then v_tenants || ' tenant(s)' else v_bad3 end);
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0008zy_split(jsonb);
drop function if exists pg_temp.v0008zy_rows(uuid, date);
drop function if exists pg_temp.v0008zy_differs(uuid);
drop function if exists pg_temp.v0008zy_base_0008zu(uuid, date);

-- Verdict: one row per check, then the verdict: no FAIL, a skip only where the check says why
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zy
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from verify_0008zy where result not in ('ok', 'skip')) then 'FAIL'
                  when (select count(*) from verify_0008zy where result = 'ok') >= 10 then '0008zy verified'
                  else 'FAIL' end,
             format('147_verify_installed_base_models: %s ok, %s FAIL, %s skip', (select count(*) from verify_0008zy where result = 'ok'),
                    (select count(*) from verify_0008zy where result not in ('ok', 'skip')),
                    (select count(*) from verify_0008zy where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0008zy;
reset role;
