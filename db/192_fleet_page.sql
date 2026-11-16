-- =============================================================================================
-- 192_fleet_page.sql: addition 0009v, Assets → Fleet management's page in one read (brief B38, E6; backlog CMA-126)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 188_fleet_management.sql
-- (0009t) and 190_follow_up_clock_at_read.sql (0009u; this script was written as 190, addition 0009u, while #287 took
-- 190, 191 and 0009u first, so it is 192, its verify 193 and the addition 0009v; it refuses to run before 0009u is
-- recorded, as 186 did before 0009r). A run of the earlier 190_fleet_page.sql (dev, 16 November 2026) created the two
-- functions and recorded nothing (its insert of 0009u met #287's row: INSERT 0 0); this script creates them again as
-- they are and records 0009v. Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM
-- login: dev first, then 193_verify_fleet_page.sql there (normal, then provoked), then prod the same way before the merge
-- of its pull request.
-- No function is re-created and no table, view or column changes: the two new functions call 0009t's
-- cma.fleet_devices_of (188) as it is, so In the field, Devices past due, the dummy area and the dummy state stay exactly
-- 0009t's, and 189_verify_fleet_management.sql keeps passing unchanged (193 runs it again on its own rows: R1, R2). No
-- earlier verify reads the new functions, so none is run again for them; run 189 once after this script all the same,
-- as the brief asks. 131_time_all.sql gains the page's read (part a; a guard on 0009v).
-- Main's web runs unchanged on it (it never calls the new functions).
--
-- Why (Martin, 16 November 2026, brief B38; Decision log, 16 Nov 2026, E6): Fleet management's page read its areas
-- (cma.fleet_areas) and its list (cma.fleet_rows) in two transactions, each computing the devices again
-- (cma.fleet_devices_of: Installed base's rows by cma.flash_devices_of, the dummy area and state); the list alone took
-- 151 ms in prod on 16 November 2026 with 6,897 devices In the field. The page now makes one read: the settings, the tiles,
-- the areas and the list's first page from one computation of the devices, in one transaction. cma.fleet_rows stays for
-- the list's further pages and the API's list; cma.fleet_areas for the API's areas.
--
-- What it adds
--   cma.fleet_page_of(tenant, market, model, state, area_id)   jsonb: dummy_preview, today, tiles (in_field, past_due and
--                          its split past_due_in_field + past_due_not_in_field, monitored, ready, needs_attention,
--                          no_connection, not_monitored), areas (cma.fleet_areas's rows and order: kinds area and no_area,
--                          without kind), past_due_not_in_field, and list (page 1 of 50 as cma.fleet_rows_of with the
--                          page's own attention rule: the devices that need attention when neither a state nor an area is
--                          chosen; total and rows). One computation of the devices (a materialized set) feeds all of it
--   cma.fleet_page(market, model, state, area_id)              the page's read: reports.view or performance.team (CMA06),
--                          the filters, the state (CMA04); set_up false and nothing more while the tenant's
--                          fleet_management.dummy_preview is off; else fleet_page_of's answer with the time zone and the
--                          filters' choices as cma.fleet_areas
--
-- SQLSTATEs as 0009t's: CMA04 invalid (a filter, a state), CMA06 not permitted.
--
-- Guard: scripts run under a personal IAM login so the audit trail names a person. postgres is
-- for emergencies only; to use it deliberately, run first:  set cma.emergency = 'on';
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

begin;
set local lock_timeout = '5s';
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0009t') then
    raise exception 'addition 0009t (188_fleet_management.sql) has not run in this database';
  end if;
  if not exists (select 1 from cma.schema_migration where version = '0009u') then
    raise exception 'addition 0009u (190_follow_up_clock_at_read.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The page's computation
-- ---------------------------------------------------------------------------------------------
-- The page's figures for a tenant after the filters (a market's code or unknown, a model's key or unknown), the list's
-- state (a tile: in_field, past_due, monitored or a state; null for none) and area (a postcode area's id; null for none),
-- from one computation of the devices (d, materialized: cma.fleet_devices_of once). The rules are 0009t's, written once
-- more over that one set, and 193 proves the answers equal cma.fleet_areas_of's and cma.fleet_rows_of's row for row:
--   areas  as cma.fleet_areas_of: one row per postcode area holding a device In the field (kind area), the devices In the
--          field without an area (no_area, always there), the devices past due not In the field (not_in_field: past_due
--          alone, outside 'areas', in past_due_not_in_field); in cma.fleet_areas's order (by country and area code, "C",
--          the row without an area last)
--   tiles  the areas summed: in_field, past_due = past_due_in_field (the areas' and no_area's) + past_due_not_in_field
--          (E3: the tile's figure stays Installed base's Devices past due, D2), monitored the three monitored states
--   list   as cma.fleet_rows_of(…, attention_only, 1): attention_only when neither a state nor an area is chosen (the page's
--          default list, lib/fleet-management fleetRowsQueryOf); sorted Needs attention, No connection, past due, then
--          the serial ("C", nulls last) and the device's id; 50 rows (a top-N sort, as fleet_rows_of's limit) and the
--          total before the page
-- The tenant's date once, a value (offset 0 keeps it apart: passed on as a call, the inlined functions would read it per
-- device and per due item; night N06), as cma.fleet_areas_of and cma.fleet_rows_of. Ids, codes, dates and counts: never a
-- customer reference, name, email, phone or address
create or replace function cma.fleet_page_of(p_tenant_id uuid, p_market text, p_model text, p_state text, p_area_id uuid)
returns jsonb
language sql stable
as $$
  with d as materialized (
    select x.* from (select cma.tenant_today_of(p_tenant_id) as day offset 0) td
    cross join lateral cma.fleet_devices_of(p_tenant_id, td.day) x
    where (p_market is null or x.market = p_market) and (p_model is null or x.model = p_model)
  ), a as materialized (
    select 'area'::text as kind, pa.id as area_id, pa.country, pa.area_code, pa.label, pa.lat, pa.lon,
           count(*) as in_field, count(*) filter (where d.state = 'ready') as ready,
           count(*) filter (where d.state = 'needs_attention') as needs_attention,
           count(*) filter (where d.state = 'no_connection') as no_connection,
           count(*) filter (where d.state = 'not_monitored') as not_monitored,
           count(*) filter (where d.past_due_items > 0) as past_due
    from d
    join cma.postcode_area pa on pa.id = d.area_id
    group by pa.id, pa.country, pa.area_code, pa.label, pa.lat, pa.lon
    union all
    select 'no_area'::text, null::uuid, null::text, null::text, null::text, null::numeric, null::numeric,
           count(*), count(*) filter (where d.state = 'ready'),
           count(*) filter (where d.state = 'needs_attention'), count(*) filter (where d.state = 'no_connection'),
           count(*) filter (where d.state = 'not_monitored'), count(*) filter (where d.past_due_items > 0)
    from d
    where d.is_in_field and d.area_id is null
    union all
    select 'not_in_field'::text, null::uuid, null::text, null::text, null::text, null::numeric, null::numeric,
           0::bigint, 0::bigint, 0::bigint, 0::bigint, 0::bigint, count(*)
    from d
    where not d.is_in_field and d.past_due_items > 0
  ), r as materialized (
    -- the list's devices: the state and the area as cma.fleet_rows_of; the attention rule the page's default list's
    select d.*
    from d
    where (p_area_id is null or d.area_id = p_area_id)
      and case p_state when 'in_field' then d.is_in_field
                       when 'past_due' then d.past_due_items > 0
                       when 'monitored' then d.state in ('ready', 'needs_attention', 'no_connection')
                       when 'ready' then d.state = 'ready'
                       when 'needs_attention' then d.state = 'needs_attention'
                       when 'no_connection' then d.state = 'no_connection'
                       when 'not_monitored' then d.state = 'not_monitored'
                       else true end
      and (p_state is not null or p_area_id is not null
           or d.state in ('needs_attention', 'no_connection') or d.past_due_items > 0)
  ), f as (
    -- the list's first page: a top-N sort of 50 (as cma.fleet_rows_of's order by … limit 50), never a sort of the whole set
    select r.*, row_number() over () as o
    from (select r.* from r
          order by case when r.state = 'needs_attention' then 0 when r.state = 'no_connection' then 1
                        when r.past_due_items > 0 then 2 else 3 end,
                   r.serial collate "C" nulls last, r.device_id
          limit 50) r
  ), t as (
    select coalesce(sum(a.in_field), 0)::bigint as in_field,
           coalesce(sum(a.past_due) filter (where a.kind <> 'not_in_field'), 0)::bigint as past_due_in_field,
           coalesce(sum(a.past_due) filter (where a.kind = 'not_in_field'), 0)::bigint as past_due_not_in_field,
           coalesce(sum(a.ready), 0)::bigint as ready, coalesce(sum(a.needs_attention), 0)::bigint as needs_attention,
           coalesce(sum(a.no_connection), 0)::bigint as no_connection, coalesce(sum(a.not_monitored), 0)::bigint as not_monitored
    from a
  )
  select jsonb_build_object(
    'dummy_preview', (select s.dummy_preview from cma.fleet_settings_of(p_tenant_id) s),
    'today', cma.tenant_today_of(p_tenant_id),
    'tiles', (select jsonb_build_object('in_field', t.in_field, 'past_due', t.past_due_in_field + t.past_due_not_in_field,
                                        'past_due_in_field', t.past_due_in_field, 'past_due_not_in_field', t.past_due_not_in_field,
                                        'monitored', t.ready + t.needs_attention + t.no_connection, 'ready', t.ready,
                                        'needs_attention', t.needs_attention, 'no_connection', t.no_connection,
                                        'not_monitored', t.not_monitored)
              from t),
    'areas', (select coalesce(jsonb_agg(to_jsonb(a) - 'kind' order by (a.area_id is null), a.country collate "C", a.area_code collate "C"), '[]'::jsonb)
              from a where a.kind <> 'not_in_field'),
    'past_due_not_in_field', (select t.past_due_not_in_field from t),
    'list', jsonb_build_object(
      'page', 1, 'page_size', 50,
      'total', (select count(*) from r),
      'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                 'device_id', f.device_id, 'serial', f.serial, 'model', f.model, 'market', f.market, 'area_id', f.area_id,
                 'area_code', pa.area_code, 'area_label', pa.label, 'state', f.state, 'reason', f.reason,
                 'last_self_test_on', f.last_self_test_on, 'last_contact_at', f.last_contact_at,
                 'past_due_items', f.past_due_items, 'location_source', f.location_source) order by f.o), '[]'::jsonb)
               from f
               left join cma.postcode_area pa on pa.id = f.area_id)))
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The page's read
-- ---------------------------------------------------------------------------------------------
-- reports.view or performance.team (CMA06 else); the filters and the state as every Fleet management read (CMA04); set_up
-- false and nothing more while the tenant's fleet_management.dummy_preview is off (D6, the computation not run); else
-- cma.fleet_page_of's answer with set_up, the filters, the time zone and the filters' choices (cma.fleet_areas's: the
-- markets with their names and the models of the register's devices in the field or tracked)
create or replace function cma.fleet_page(p_market text default null, p_model text default null, p_state text default null,
                                          p_area_id uuid default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_fleet_filters(p_market, p_model, p_state, 1);
  if not (select s.dummy_preview from cma.fleet_settings_of(v_tenant) s) then
    return jsonb_build_object('set_up', false);
  end if;
  return cma.fleet_page_of(v_tenant, p_market, p_model, p_state, p_area_id) || jsonb_build_object(
    'set_up', true, 'market', p_market, 'model', p_model, 'state', p_state, 'area_id', p_area_id,
    'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant),
    'filter_markets', (select coalesce(jsonb_agg(jsonb_build_object('code', f.market, 'name', m.name)
                                                 order by (f.market = 'unknown'), m.sort_order, f.market collate "C"), '[]'::jsonb)
                       from (select distinct coalesce(dv.market, 'unknown') as market
                             from cma.device dv
                             join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and (st.is_in_field or st.is_tracked)
                             where dv.tenant_id = v_tenant and dv.source_deleted_at is null) f
                       left join cma.market m on m.tenant_id = v_tenant and m.code = f.market),
    'filter_models', (select coalesce(jsonb_agg(jsonb_build_object('key', f.model, 'name', md.name)
                                                order by (f.model = 'unknown'), md.sort_order, f.model collate "C"), '[]'::jsonb)
                      from (select distinct coalesce(dv.model_key, 'unknown') as model
                            from cma.device dv
                            join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and (st.is_in_field or st.is_tracked)
                            where dv.tenant_id = v_tenant and dv.source_deleted_at is null) f
                      left join cma.device_model md on md.tenant_id = v_tenant and md.key = f.model));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Grants and settings of the functions
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array['cma.fleet_page_of(uuid,text,text,text,uuid)', 'cma.fleet_page(text,text,text,uuid)'] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
    -- JIT off, as 0009t's reads (section 14 of 122): a read of thousands of rows otherwise pays JIT's compilation on a
    -- session's first calls
    execute format('alter function %s set jit = off', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009v', 'Assets → Fleet management''s page in one read (brief B38, E6): cma.fleet_page_of (jsonb: dummy_preview, today, the tiles with Devices past due split in the field and not in the field, the areas as cma.fleet_areas, past_due_not_in_field, and the list''s first page of 50 as cma.fleet_rows_of with the page''s attention rule, from one computation of cma.fleet_devices_of) and cma.fleet_page (reports.view or performance.team; set_up false while fleet_management.dummy_preview is off; the time zone and the filters'' choices). No function re-created, no table, view or column changed; nothing in cma_read')
on conflict (version) do nothing;

commit;
reset role;
