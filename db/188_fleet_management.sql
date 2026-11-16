-- =============================================================================================
-- 188_fleet_management.sql: addition 0009t, Assets → Fleet management: the devices in the field by postcode area, with
-- monitoring states (dummy locations and states behind a tenant setting)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. The postcode areas are geography reference data (a country's
-- postcode area, a place name and its centre; never a customer's address), the same in every database; whether a tenant
-- sees the dummy is its own setting. Runs unchanged in every database, after 184_active_device_bands.sql (0009r).
-- Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 189_verify_fleet_management.sql there (normal, then provoked), then prod the same way before the merge of its pull
-- request (prod's setting stays false: the page stays the placeholder there). The brief named this script 186 and its
-- verify 187; the open pull request #284 holds 186, 187 and addition 0009s, so they are 188, 189 and 0009t.
-- No function is re-created and no existing table, view or column changes, so no earlier verify is run again: the new
-- reads call Installed base's own cma.flash_devices_of (136) as it is, and the new setting is a boolean, which
-- cma.check_tenant_setting() (184) already checks by its type. 131_time_all.sql gains the page's two reads (part a; a
-- guard on 0009t).
-- Main's web runs unchanged on it (it never calls the new functions).
--
-- Why (Martin, 16 November 2026, brief B37; Decision log, 16 Nov 2026, D1 to D8):
--   D1 Fleet management shows the devices In the field on a map, clustered by postcode area, with monitoring-state tiles
--      and a list of the devices that need attention; it stops being a placeholder (with the setting on).
--   D2 In the field and Devices past due are Installed base's own rules, called, not copied: cma.flash_devices_of, the
--      rows Installed base's take and its lists read (is_in_field: a device the latest full snapshot holds in a status
--      flagged in the field; past_due_items: its items past due by cma.maintenance_items_of, for a tracked device).
--   D3 A postcode area per market: NL, BE, AT 4 digits; GB the outward code; IE the Eircode routing key; DE the 2-digit
--      Leitregion; FR the département; SE the first 3 digits; and (Martin, 16 November 2026, on #285) DK 4 digits, NO the
--      first 2 (a 4-digit postnummer is too fine in rural areas), FI the first 3, ES and IT the first 2. Areas are seeded only
--      for markets in a tenant's market catalog. Never a customer's address: no full postcode, no coordinates of a device, no
--      address is stored.
--   D4 The dummy location: one area of the device's own market (cma.device.market), picked by
--      hashtextextended(device.id::text || ':fleet-area-v1', 0) weighted by the area's weight: stable across reads and
--      loads. A device whose market has no area counts under No postcode area and is not on the map.
--   D5 The dummy monitoring state by hashtextextended(device.id::text || ':fleet-state-v1', 0) mod 1000: 0-369 Not
--      monitored, 370-391 Needs attention (Self-test failed or Tracker battery low), 392-423 No connection (last contact
--      2 to 11 days ago), 424-999 Ready (self-test passed today or yesterday, last contact today). Dates and reasons from
--      further bits of the same hash, relative to the tenant's today. A device past due (real) carries the reason
--      items_past_due when the dummy gives it none.
--   D6 Behind the tenant setting fleet_management.dummy_preview (boolean, default false): false, the reads answer
--      set_up false and no figure. Nothing of it reaches cma_read, BigQuery or NocoDB.
--
-- What it adds
--   table   cma.postcode_area (id, country, area_code, label, lat, lon, weight, source): geography reference data, not
--           tenant data (no tenant_id, no row-level security, no audit trigger): readable by cma_app, written by
--           migrations only; seeded below (source sample-2026-11). No view in cma_read
--   setting fleet_management.dummy_preview (boolean, false)
--   cma.fleet_settings_of(tenant)                            the tenant's dummy_preview
--   cma.fleet_devices_of(tenant, today)                      the devices the page counts: In the field, and past due in
--                                                            any tracked status; each with its dummy area and state
--   cma.fleet_areas_of(tenant, market, model)                one row per postcode area holding a device In the field
--                                                            (kind area), one for the devices In the field without an area
--                                                            (no_area) and one for the devices past due not In the field
--                                                            (not_in_field)
--   cma.fleet_areas(market, model)                           the page's read: reports.view or performance.team, the
--                                                            setting, the filters' choices, the areas
--   cma.fleet_rows_of(tenant, market, model, state, area, attention_only, page)  50 devices a page
--   cma.fleet_rows(market, model, state, area, attention_only, page)             the list's read, as fleet_areas
--
-- The rows (Martin, 16 November 2026, on #285): no_area holds only devices In the field, whose market has no area (or no
-- market); not_in_field holds, in past_due alone, the devices past due that are not In the field (in stock, internal use:
-- no location applies; the page's note "n devices past due that are not in the field (not on the map)"). The page's
-- Devices past due is every row's past_due summed and equals Installed base's (D2); the map shows the field alone.
--
-- SQLSTATEs as Installed base's: CMA04 invalid (a filter, a state, a page), CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0009r') then
    raise exception 'addition 0009r (184_active_device_bands.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The postcode areas: geography reference data
-- ---------------------------------------------------------------------------------------------
-- A country's postcode area (D3): a code of at most four letters or digits (an area, never a full postcode of a country
-- whose full postcode is longer), a place name, the area's centre (degrees; the sample to two decimals) for the map, a weight (how many
-- devices the dummy places there, relatively), the source of the row. Not tenant data: the same for every tenant
create table if not exists cma.postcode_area (
  id         uuid primary key default uuidv7(),
  country    text not null check (country ~ '^[A-Z]{2}$' and country <> 'UK'),
  area_code  text not null check (area_code ~ '^[A-Z0-9]{1,4}$'),
  label      text not null check (length(btrim(label)) between 1 and 60),
  lat        numeric(7,4) not null check (lat between 30 and 75),
  lon        numeric(7,4) not null check (lon between -30 and 50),
  weight     integer not null check (weight > 0),
  source     text not null check (source ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  unique (country, area_code)
);
comment on table cma.postcode_area is 'Postcode areas per country (geography reference data, not tenant data): a code of the country''s area (NL, BE, AT 4 digits; GB the outward code; IE the Eircode routing key; DE the 2-digit Leitregion; FR the département; SE 3 digits; DK, NO, CH 4 digits; FI 3 digits; ES, IT 2 digits), a place name and the area''s centre for Fleet management''s map. Never a customer''s address. Written by migrations only';
comment on column cma.postcode_area.area_code is 'The area''s code in the country''s own form (D3, 16 November 2026); never a full postcode';
comment on column cma.postcode_area.label is 'A place name in the area (its largest place)';
comment on column cma.postcode_area.lat is 'The area''s centre, latitude in degrees (WGS84; the sample to two decimals): a place, never a device';
comment on column cma.postcode_area.lon is 'The area''s centre, longitude in degrees (WGS84; the sample to two decimals): a place, never a device';
comment on column cma.postcode_area.weight is 'How many of a market''s devices the dummy location places in this area, relative to the market''s other areas (D4)';
comment on column cma.postcode_area.source is 'Where the row comes from: sample-2026-11, the sample areas of brief B37';

-- readable by the application (01's default privileges), written by migrations alone; nothing for the readers
revoke insert, update, delete, truncate on cma.postcode_area from cma_app;
revoke all on cma.postcode_area from public;

-- The sample areas of brief B37, then the catalog's other markets (DK, NO, FI, ES, IT), five or six of their largest
-- places. Areas are seeded only for markets in a tenant's market catalog (Martin, 16 November 2026, on #285).
-- A rerun keeps the rows' ids (the areas the devices sit in), takes the values again, and removes a row of this source
-- the script no longer holds (the table equals the script)
insert into cma.postcode_area (country, area_code, label, lat, lon, weight, source)
select x.country, x.area_code, x.label, x.lat, x.lon, x.weight, 'sample-2026-11'
from (values
  ('GB', 'EC1', 'London', 51.52, -0.1, 118), ('GB', 'SW1', 'London', 51.47, -0.17, 96), ('GB', 'M1', 'Manchester', 53.48, -2.24, 74),
  ('GB', 'B1', 'Birmingham', 52.48, -1.9, 68), ('GB', 'LS1', 'Leeds', 53.8, -1.55, 47), ('GB', 'G1', 'Glasgow', 55.86, -4.25, 43),
  ('GB', 'EH1', 'Edinburgh', 55.95, -3.19, 39), ('GB', 'BS1', 'Bristol', 51.45, -2.59, 41), ('GB', 'BN1', 'Brighton', 50.82, -0.14, 28),
  ('GB', 'CF10', 'Cardiff', 51.48, -3.18, 26), ('GB', 'NE1', 'Newcastle', 54.97, -1.61, 31), ('GB', 'L1', 'Liverpool', 53.41, -2.98, 35),
  ('GB', 'NG1', 'Nottingham', 52.95, -1.15, 24), ('GB', 'CB1', 'Cambridge', 52.2, 0.13, 22), ('GB', 'OX1', 'Oxford', 51.75, -1.26, 19),
  ('GB', 'PL1', 'Plymouth', 50.37, -4.14, 14), ('GB', 'AB10', 'Aberdeen', 57.15, -2.1, 12), ('GB', 'BT1', 'Belfast', 54.6, -5.93, 17),
  ('NL', '1012', 'Amsterdam', 52.37, 4.9, 84), ('NL', '3011', 'Rotterdam', 51.92, 4.48, 66), ('NL', '2511', 'Den Haag', 52.08, 4.31, 58),
  ('NL', '3511', 'Utrecht', 52.09, 5.12, 49), ('NL', '5611', 'Eindhoven', 51.44, 5.48, 37), ('NL', '9711', 'Groningen', 53.22, 6.57, 26),
  ('NL', '6811', 'Arnhem', 51.98, 5.91, 22), ('NL', '7511', 'Enschede', 52.22, 6.89, 18), ('NL', '4811', 'Breda', 51.59, 4.78, 21),
  ('NL', '8011', 'Zwolle', 52.51, 6.09, 17), ('NL', '6211', 'Maastricht', 50.85, 5.69, 15), ('NL', '2011', 'Haarlem', 52.38, 4.64, 19),
  ('NL', '8911', 'Leeuwarden', 53.2, 5.8, 11), ('NL', '6511', 'Nijmegen', 51.84, 5.86, 16), ('NL', '4331', 'Middelburg', 51.5, 3.61, 8),
  ('DE', '10', 'Berlin', 52.52, 13.4, 52), ('DE', '20', 'Hamburg', 53.55, 9.99, 38), ('DE', '80', 'München', 48.14, 11.58, 41),
  ('DE', '50', 'Köln', 50.94, 6.96, 33), ('DE', '60', 'Frankfurt am Main', 50.11, 8.68, 29), ('DE', '70', 'Stuttgart', 48.78, 9.18, 24),
  ('DE', '40', 'Düsseldorf', 51.23, 6.78, 22), ('DE', '01', 'Dresden', 51.05, 13.74, 12), ('DE', '04', 'Leipzig', 51.34, 12.37, 14),
  ('DE', '30', 'Hannover', 52.37, 9.73, 17), ('DE', '28', 'Bremen', 53.08, 8.8, 11), ('DE', '90', 'Nürnberg', 49.45, 11.08, 13),
  ('DE', '44', 'Dortmund', 51.51, 7.47, 15), ('DE', '24', 'Kiel', 54.32, 10.13, 7),
  ('FR', '75', 'Paris', 48.86, 2.35, 46), ('FR', '69', 'Lyon', 45.76, 4.84, 21), ('FR', '13', 'Marseille', 43.3, 5.37, 16),
  ('FR', '31', 'Toulouse', 43.6, 1.44, 13), ('FR', '33', 'Bordeaux', 44.84, -0.58, 12), ('FR', '59', 'Lille', 50.63, 3.06, 15),
  ('FR', '44', 'Nantes', 47.22, -1.55, 10), ('FR', '67', 'Strasbourg', 48.57, 7.75, 9), ('FR', '35', 'Rennes', 48.11, -1.68, 8),
  ('FR', '06', 'Nice', 43.7, 7.27, 7),
  ('AT', '1010', 'Wien', 48.21, 16.37, 34), ('AT', '8010', 'Graz', 47.07, 15.44, 12), ('AT', '4020', 'Linz', 48.31, 14.29, 11),
  ('AT', '5020', 'Salzburg', 47.81, 13.06, 9), ('AT', '6020', 'Innsbruck', 47.27, 11.39, 8), ('AT', '9020', 'Klagenfurt', 46.62, 14.31, 5),
  ('SE', '111', 'Stockholm', 59.33, 18.07, 29), ('SE', '411', 'Göteborg', 57.71, 11.97, 16), ('SE', '211', 'Malmö', 55.6, 13.0, 12),
  ('SE', '753', 'Uppsala', 59.86, 17.64, 7), ('SE', '581', 'Linköping', 58.41, 15.62, 6), ('SE', '901', 'Umeå', 63.83, 20.26, 4),
  ('IE', 'D02', 'Dublin', 53.34, -6.26, 27), ('IE', 'T12', 'Cork', 51.9, -8.47, 11), ('IE', 'H91', 'Galway', 53.27, -9.05, 8),
  ('IE', 'V94', 'Limerick', 52.66, -8.63, 6), ('IE', 'X91', 'Waterford', 52.26, -7.11, 4),
  ('BE', '1000', 'Brussel', 50.85, 4.35, 21), ('BE', '2000', 'Antwerpen', 51.22, 4.4, 18), ('BE', '9000', 'Gent', 51.05, 3.72, 13),
  ('BE', '4000', 'Liège', 50.63, 5.57, 8), ('BE', '3000', 'Leuven', 50.88, 4.7, 7), ('BE', '8000', 'Brugge', 51.21, 3.22, 5),
  -- the catalog's other markets (02's market aliases; Martin, 16 November 2026, on #285): DK 4 digits (as AT and BE), NO
  -- the first 2 digits (a 4-digit postnummer is too fine in rural areas), FI the first 3 of 5 digits (as SE), ES the
  -- province's 2 digits (as FR's département), IT the first 2 digits (as DE)
  ('DK', '1050', 'København', 55.68, 12.57, 12), ('DK', '8000', 'Aarhus', 56.16, 10.2, 6), ('DK', '5000', 'Odense', 55.4, 10.39, 4),
  ('DK', '9000', 'Aalborg', 57.05, 9.92, 3), ('DK', '6700', 'Esbjerg', 55.47, 8.45, 2),
  ('NO', '01', 'Oslo', 59.91, 10.75, 10), ('NO', '50', 'Bergen', 60.39, 5.32, 5), ('NO', '70', 'Trondheim', 63.43, 10.4, 4),
  ('NO', '40', 'Stavanger', 58.97, 5.73, 3), ('NO', '90', 'Tromsø', 69.65, 18.96, 1),
  ('FI', '001', 'Helsinki', 60.17, 24.94, 10), ('FI', '331', 'Tampere', 61.5, 23.76, 4), ('FI', '201', 'Turku', 60.45, 22.27, 3),
  ('FI', '901', 'Oulu', 65.01, 25.47, 2), ('FI', '401', 'Jyväskylä', 62.24, 25.75, 2),
  ('ES', '28', 'Madrid', 40.42, -3.7, 14), ('ES', '08', 'Barcelona', 41.39, 2.17, 12), ('ES', '46', 'Valencia', 39.47, -0.38, 6),
  ('ES', '41', 'Sevilla', 37.39, -5.98, 4), ('ES', '48', 'Bilbao', 43.26, -2.93, 3), ('ES', '29', 'Málaga', 36.72, -4.42, 3),
  ('IT', '00', 'Roma', 41.9, 12.5, 12), ('IT', '20', 'Milano', 45.46, 9.19, 12), ('IT', '80', 'Napoli', 40.85, 14.27, 6),
  ('IT', '10', 'Torino', 45.07, 7.69, 5), ('IT', '50', 'Firenze', 43.77, 11.26, 3), ('IT', '40', 'Bologna', 44.49, 11.34, 3)
) as x(country, area_code, label, lat, lon, weight)
on conflict (country, area_code) do update
  set label = excluded.label, lat = excluded.lat, lon = excluded.lon, weight = excluded.weight, source = excluded.source
  where (cma.postcode_area.label, cma.postcode_area.lat, cma.postcode_area.lon, cma.postcode_area.weight, cma.postcode_area.source)
        is distinct from (excluded.label, excluded.lat, excluded.lon, excluded.weight, excluded.source);

-- the table equals the script: a row of this source the script no longer holds goes (NO's 4-digit areas and CH's of the
-- first version of this script, where it ran)
delete from cma.postcode_area pa
where pa.source = 'sample-2026-11'
  and (pa.country, pa.area_code) not in (select x.country, x.area_code
  from (values
    ('GB', 'EC1', 'London', 51.52, -0.1, 118), ('GB', 'SW1', 'London', 51.47, -0.17, 96), ('GB', 'M1', 'Manchester', 53.48, -2.24, 74),
    ('GB', 'B1', 'Birmingham', 52.48, -1.9, 68), ('GB', 'LS1', 'Leeds', 53.8, -1.55, 47), ('GB', 'G1', 'Glasgow', 55.86, -4.25, 43),
    ('GB', 'EH1', 'Edinburgh', 55.95, -3.19, 39), ('GB', 'BS1', 'Bristol', 51.45, -2.59, 41), ('GB', 'BN1', 'Brighton', 50.82, -0.14, 28),
    ('GB', 'CF10', 'Cardiff', 51.48, -3.18, 26), ('GB', 'NE1', 'Newcastle', 54.97, -1.61, 31), ('GB', 'L1', 'Liverpool', 53.41, -2.98, 35),
    ('GB', 'NG1', 'Nottingham', 52.95, -1.15, 24), ('GB', 'CB1', 'Cambridge', 52.2, 0.13, 22), ('GB', 'OX1', 'Oxford', 51.75, -1.26, 19),
    ('GB', 'PL1', 'Plymouth', 50.37, -4.14, 14), ('GB', 'AB10', 'Aberdeen', 57.15, -2.1, 12), ('GB', 'BT1', 'Belfast', 54.6, -5.93, 17),
    ('NL', '1012', 'Amsterdam', 52.37, 4.9, 84), ('NL', '3011', 'Rotterdam', 51.92, 4.48, 66), ('NL', '2511', 'Den Haag', 52.08, 4.31, 58),
    ('NL', '3511', 'Utrecht', 52.09, 5.12, 49), ('NL', '5611', 'Eindhoven', 51.44, 5.48, 37), ('NL', '9711', 'Groningen', 53.22, 6.57, 26),
    ('NL', '6811', 'Arnhem', 51.98, 5.91, 22), ('NL', '7511', 'Enschede', 52.22, 6.89, 18), ('NL', '4811', 'Breda', 51.59, 4.78, 21),
    ('NL', '8011', 'Zwolle', 52.51, 6.09, 17), ('NL', '6211', 'Maastricht', 50.85, 5.69, 15), ('NL', '2011', 'Haarlem', 52.38, 4.64, 19),
    ('NL', '8911', 'Leeuwarden', 53.2, 5.8, 11), ('NL', '6511', 'Nijmegen', 51.84, 5.86, 16), ('NL', '4331', 'Middelburg', 51.5, 3.61, 8),
    ('DE', '10', 'Berlin', 52.52, 13.4, 52), ('DE', '20', 'Hamburg', 53.55, 9.99, 38), ('DE', '80', 'München', 48.14, 11.58, 41),
    ('DE', '50', 'Köln', 50.94, 6.96, 33), ('DE', '60', 'Frankfurt am Main', 50.11, 8.68, 29), ('DE', '70', 'Stuttgart', 48.78, 9.18, 24),
    ('DE', '40', 'Düsseldorf', 51.23, 6.78, 22), ('DE', '01', 'Dresden', 51.05, 13.74, 12), ('DE', '04', 'Leipzig', 51.34, 12.37, 14),
    ('DE', '30', 'Hannover', 52.37, 9.73, 17), ('DE', '28', 'Bremen', 53.08, 8.8, 11), ('DE', '90', 'Nürnberg', 49.45, 11.08, 13),
    ('DE', '44', 'Dortmund', 51.51, 7.47, 15), ('DE', '24', 'Kiel', 54.32, 10.13, 7),
    ('FR', '75', 'Paris', 48.86, 2.35, 46), ('FR', '69', 'Lyon', 45.76, 4.84, 21), ('FR', '13', 'Marseille', 43.3, 5.37, 16),
    ('FR', '31', 'Toulouse', 43.6, 1.44, 13), ('FR', '33', 'Bordeaux', 44.84, -0.58, 12), ('FR', '59', 'Lille', 50.63, 3.06, 15),
    ('FR', '44', 'Nantes', 47.22, -1.55, 10), ('FR', '67', 'Strasbourg', 48.57, 7.75, 9), ('FR', '35', 'Rennes', 48.11, -1.68, 8),
    ('FR', '06', 'Nice', 43.7, 7.27, 7),
    ('AT', '1010', 'Wien', 48.21, 16.37, 34), ('AT', '8010', 'Graz', 47.07, 15.44, 12), ('AT', '4020', 'Linz', 48.31, 14.29, 11),
    ('AT', '5020', 'Salzburg', 47.81, 13.06, 9), ('AT', '6020', 'Innsbruck', 47.27, 11.39, 8), ('AT', '9020', 'Klagenfurt', 46.62, 14.31, 5),
    ('SE', '111', 'Stockholm', 59.33, 18.07, 29), ('SE', '411', 'Göteborg', 57.71, 11.97, 16), ('SE', '211', 'Malmö', 55.6, 13.0, 12),
    ('SE', '753', 'Uppsala', 59.86, 17.64, 7), ('SE', '581', 'Linköping', 58.41, 15.62, 6), ('SE', '901', 'Umeå', 63.83, 20.26, 4),
    ('IE', 'D02', 'Dublin', 53.34, -6.26, 27), ('IE', 'T12', 'Cork', 51.9, -8.47, 11), ('IE', 'H91', 'Galway', 53.27, -9.05, 8),
    ('IE', 'V94', 'Limerick', 52.66, -8.63, 6), ('IE', 'X91', 'Waterford', 52.26, -7.11, 4),
    ('BE', '1000', 'Brussel', 50.85, 4.35, 21), ('BE', '2000', 'Antwerpen', 51.22, 4.4, 18), ('BE', '9000', 'Gent', 51.05, 3.72, 13),
    ('BE', '4000', 'Liège', 50.63, 5.57, 8), ('BE', '3000', 'Leuven', 50.88, 4.7, 7), ('BE', '8000', 'Brugge', 51.21, 3.22, 5),
    -- the catalog's other markets (02's market aliases; Martin, 16 November 2026, on #285): DK 4 digits (as AT and BE), NO
    -- the first 2 digits (a 4-digit postnummer is too fine in rural areas), FI the first 3 of 5 digits (as SE), ES the
    -- province's 2 digits (as FR's département), IT the first 2 digits (as DE)
    ('DK', '1050', 'København', 55.68, 12.57, 12), ('DK', '8000', 'Aarhus', 56.16, 10.2, 6), ('DK', '5000', 'Odense', 55.4, 10.39, 4),
    ('DK', '9000', 'Aalborg', 57.05, 9.92, 3), ('DK', '6700', 'Esbjerg', 55.47, 8.45, 2),
    ('NO', '01', 'Oslo', 59.91, 10.75, 10), ('NO', '50', 'Bergen', 60.39, 5.32, 5), ('NO', '70', 'Trondheim', 63.43, 10.4, 4),
    ('NO', '40', 'Stavanger', 58.97, 5.73, 3), ('NO', '90', 'Tromsø', 69.65, 18.96, 1),
    ('FI', '001', 'Helsinki', 60.17, 24.94, 10), ('FI', '331', 'Tampere', 61.5, 23.76, 4), ('FI', '201', 'Turku', 60.45, 22.27, 3),
    ('FI', '901', 'Oulu', 65.01, 25.47, 2), ('FI', '401', 'Jyväskylä', 62.24, 25.75, 2),
    ('ES', '28', 'Madrid', 40.42, -3.7, 14), ('ES', '08', 'Barcelona', 41.39, 2.17, 12), ('ES', '46', 'Valencia', 39.47, -0.38, 6),
    ('ES', '41', 'Sevilla', 37.39, -5.98, 4), ('ES', '48', 'Bilbao', 43.26, -2.93, 3), ('ES', '29', 'Málaga', 36.72, -4.42, 3),
    ('IT', '00', 'Roma', 41.9, 12.5, 12), ('IT', '20', 'Milano', 45.46, 9.19, 12), ('IT', '80', 'Napoli', 40.85, 14.27, 6),
    ('IT', '10', 'Torino', 45.07, 7.69, 5), ('IT', '50', 'Firenze', 43.77, 11.26, 3), ('IT', '40', 'Bologna', 44.49, 11.34, 3)
  ) as x(country, area_code, label, lat, lon, weight));

-- ---------------------------------------------------------------------------------------------
-- 2. The setting
-- ---------------------------------------------------------------------------------------------
-- A boolean: cma.check_tenant_setting() (184) checks it by its type, as every boolean setting
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('fleet_management.dummy_preview', 'boolean', null, 'false',
     'Assets → Fleet management shows its preview: the devices In the field on a map by postcode area with monitoring states, the locations and states dummy data (the devices and their past-due items real). Off: the page is the placeholder')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 3. The reads
-- ---------------------------------------------------------------------------------------------
-- The tenant's Fleet management settings: whether the preview with dummy data is on (D6)
create or replace function cma.fleet_settings_of(p_tenant_id uuid)
returns table (dummy_preview boolean)
language sql stable
rows 1
as $$
  select coalesce(cma.setting_of(p_tenant_id, 'fleet_management.dummy_preview'), 'false') = 'true'
$$;

-- The devices Fleet management counts as of p_today (the tenant's date): Installed base's rows (cma.flash_devices_of,
-- D2), every device In the field and every device past due in another tracked status; each with its dummy postcode area
-- (D4: a device In the field only, an area of its own market by the weighted hash, none where the market has no area) and
-- its dummy monitoring state (D5: a device In the field only). Ids, codes, dates and counts: never a customer reference,
-- name, email, phone or address
--   state             not_monitored, needs_attention, no_connection or ready; null for a device not In the field
--   reason            self_test_failed or tracker_battery_low (Needs attention), else items_past_due for a device past due
--   last_self_test_on the date of the last self-test result: today or yesterday (Ready, Needs attention), the day of the
--                     last contact (No connection), none (Not monitored)
--   last_contact_at   the nightly check-in: today between 00:00 and 01:59 in the tenant's zone, never after now (Ready,
--                     Needs attention), 2 to 11 days back (No connection), none (Not monitored)
--   location_source   dummy for a device with an area (postcode or gps once a source is decided), none else
create or replace function cma.fleet_devices_of(p_tenant_id uuid, p_today date)
returns table (device_id uuid, serial text, model text, market text, is_in_field boolean, past_due_items integer, area_id uuid,
               state text, reason text, last_self_test_on date, last_contact_at timestamptz, location_source text)
language sql stable
rows 5000
as $$
  with b as materialized (
    select f.device_id, f.serial, f.model, f.market, f.is_in_field, f.past_due_items
    from cma.flash_devices_of(p_tenant_id, p_today) f
    where f.is_in_field or f.past_due_items > 0
  ), a as materialized (
    -- each area's slice of its country's weights, in a fixed order: [lo, hi) of 0 to the country's total
    select pa.id, pa.country,
           sum(pa.weight) over (partition by pa.country order by pa.area_code collate "C") - pa.weight as lo,
           sum(pa.weight) over (partition by pa.country order by pa.area_code collate "C") as hi,
           sum(pa.weight) over (partition by pa.country) as total
    from cma.postcode_area pa
  ), z as materialized (
    select ((p_today)::timestamp at time zone t.timezone) as midnight, t.timezone as zone from cma.tenant t where t.id = p_tenant_id
  )
  select b.device_id, b.serial, b.model, b.market, b.is_in_field, b.past_due_items, ar.id,
         s.state,
         case when s.state = 'needs_attention' then case when s.r1 % 2 = 0 then 'self_test_failed' else 'tracker_battery_low' end
              when b.past_due_items > 0 then 'items_past_due' end,
         case s.state when 'ready' then p_today - (s.r2 % 2)::integer
                      when 'needs_attention' then p_today - (s.r2 % 2)::integer
                      when 'no_connection' then p_today - (2 + s.r1 % 10)::integer end,
         case s.state when 'ready' then least(now(), (select z.midnight from z) + make_interval(mins => (s.r3 % 120)::integer))
                      when 'needs_attention' then least(now(), (select z.midnight from z) + make_interval(mins => (s.r3 % 120)::integer))
                      when 'no_connection' then (((p_today - (2 + s.r1 % 10)::integer))::timestamp at time zone (select z.zone from z))
                                                + make_interval(mins => (s.r3 % 120)::integer) end,
         case when ar.id is not null then 'dummy' end
  from b
  cross join lateral (select hashtextextended(b.device_id::text || ':fleet-area-v1', 0) as ha,
                             hashtextextended(b.device_id::text || ':fleet-state-v1', 0) as hs) h
  cross join lateral (
    select case when not b.is_in_field then null
                when mod(mod(h.hs, 1000) + 1000, 1000) < 370 then 'not_monitored'
                when mod(mod(h.hs, 1000) + 1000, 1000) < 392 then 'needs_attention'
                when mod(mod(h.hs, 1000) + 1000, 1000) < 424 then 'no_connection'
                else 'ready' end as state,
           (h.hs >> 10) & 1023 as r1, (h.hs >> 20) & 1023 as r2, (h.hs >> 30) & 1023 as r3
  ) s
  -- the area: a join on the country (a hash join, about 18 areas a country), the hash's place in its weights' range
  left join a ar on b.is_in_field and ar.country = b.market
                and mod(mod(h.ha, ar.total) + ar.total, ar.total) >= ar.lo and mod(mod(h.ha, ar.total) + ar.total, ar.total) < ar.hi
$$;

-- The page's rows after the filters (a market's code or unknown, a model's key or unknown): one row per postcode area that
-- holds a device In the field (kind area), with its counts; one row for the devices In the field without an area (kind
-- no_area, area_id null: in_field, the states and past_due of those alone); one row for the devices past due that are not
-- In the field (kind not_in_field, area_id null: past_due alone, every other count 0). The states add up to in_field in
-- every row; in_field summed is Installed base's In the field, past_due summed its Devices past due, for the same
-- filters (189 proves both). The two rows without an area are always there, zeros included
create or replace function cma.fleet_areas_of(p_tenant_id uuid, p_market text, p_model text)
returns table (kind text, area_id uuid, country text, area_code text, label text, lat numeric, lon numeric, in_field bigint,
               ready bigint, needs_attention bigint, no_connection bigint, not_monitored bigint, past_due bigint)
language sql stable
rows 200
as $$
  -- the tenant's date once, a value (offset 0 keeps it apart): passed on as a call, the inlined functions would read it
  -- per device and per due item (night N06)
  with d as materialized (
    select x.* from (select cma.tenant_today_of(p_tenant_id) as day offset 0) td
    cross join lateral cma.fleet_devices_of(p_tenant_id, td.day) x
    where (p_market is null or x.market = p_market) and (p_model is null or x.model = p_model)
  )
  select 'area'::text, pa.id, pa.country, pa.area_code, pa.label, pa.lat, pa.lon,
         count(*), count(*) filter (where d.state = 'ready'), count(*) filter (where d.state = 'needs_attention'),
         count(*) filter (where d.state = 'no_connection'), count(*) filter (where d.state = 'not_monitored'),
         count(*) filter (where d.past_due_items > 0)
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
$$;

-- A page of 50 of the devices Fleet management counts, after the filters: p_state in_field, past_due, monitored, ready,
-- needs_attention, no_connection or not_monitored (null: every device counted); p_area_id an area; p_attention_only the
-- devices that need attention (Needs attention, No connection, or past due). Sorted Needs attention, No connection, past
-- due, then the serial ("C" order) and the device's id; total_rows is the count before the page
create or replace function cma.fleet_rows_of(p_tenant_id uuid, p_market text, p_model text, p_state text, p_area_id uuid,
                                             p_attention_only boolean, p_page integer)
returns table (device_id uuid, serial text, model text, market text, area_id uuid, area_code text, area_label text, state text,
               reason text, last_self_test_on date, last_contact_at timestamptz, past_due_items integer, location_source text,
               total_rows bigint)
language sql stable
rows 50
as $$
  with d as materialized (
    select x.* from (select cma.tenant_today_of(p_tenant_id) as day offset 0) td
    cross join lateral cma.fleet_devices_of(p_tenant_id, td.day) x
    where (p_market is null or x.market = p_market) and (p_model is null or x.model = p_model)
      and (p_area_id is null or x.area_id = p_area_id)
      and case p_state when 'in_field' then x.is_in_field
                       when 'past_due' then x.past_due_items > 0
                       when 'monitored' then x.state in ('ready', 'needs_attention', 'no_connection')
                       when 'ready' then x.state = 'ready'
                       when 'needs_attention' then x.state = 'needs_attention'
                       when 'no_connection' then x.state = 'no_connection'
                       when 'not_monitored' then x.state = 'not_monitored'
                       else true end
      and (not coalesce(p_attention_only, false) or x.state in ('needs_attention', 'no_connection') or x.past_due_items > 0)
  ), p as (
    select d.*, count(*) over () as total_rows,
           case when d.state = 'needs_attention' then 0 when d.state = 'no_connection' then 1 when d.past_due_items > 0 then 2 else 3 end as rank
    from d
  )
  select p.device_id, p.serial, p.model, p.market, p.area_id, pa.area_code, pa.label, p.state, p.reason, p.last_self_test_on,
         p.last_contact_at, p.past_due_items, p.location_source, p.total_rows
  from p
  left join cma.postcode_area pa on pa.id = p.area_id
  order by p.rank, p.serial collate "C" nulls last, p.device_id
  limit 50 offset (greatest(p_page, 1) - 1) * 50
$$;

-- The checks every Fleet management read makes (CMA04): the filters as Maintenance's (a market's code or unknown, a
-- model's key or unknown), a state of the list, a page from 1
create or replace function cma.assert_fleet_filters(p_market text, p_model text, p_state text, p_page integer)
returns void
language plpgsql immutable
as $$
begin
  perform cma.assert_maintenance_filters(p_market, p_model, null);
  if p_state is not null and p_state not in ('in_field', 'past_due', 'monitored', 'ready', 'needs_attention', 'no_connection', 'not_monitored') then
    raise exception 'a state is in_field, past_due, monitored, ready, needs_attention, no_connection or not_monitored' using errcode = 'CMA04';
  end if;
  if p_page is null or p_page not between 1 and 100000 then
    raise exception 'a page is a whole number from 1' using errcode = 'CMA04';
  end if;
end
$$;

-- The page's read (reports.view or performance.team; CMA06 else): set_up false and nothing more while the tenant's
-- fleet_management.dummy_preview is off (D6); else the tenant's today and zone, the filters' choices (the markets with
-- their names and the models of the register's devices in the field or tracked), the areas of cma.fleet_areas_of in a fixed
-- order (by country and area code, the row without an area last; kinds area and no_area) and past_due_not_in_field (the
-- not_in_field row's past_due). The tiles are the areas summed, with past_due_not_in_field in Devices past due (the API's)
create or replace function cma.fleet_areas(p_market text default null, p_model text default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_rows   jsonb;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_fleet_filters(p_market, p_model, null, 1);
  if not (select s.dummy_preview from cma.fleet_settings_of(v_tenant) s) then
    return jsonb_build_object('set_up', false);
  end if;
  -- the rows once (one computation of the devices), in the page's order
  select coalesce(jsonb_agg(to_jsonb(a) order by (a.area_id is null), (a.kind = 'not_in_field'), a.country collate "C", a.area_code collate "C"), '[]'::jsonb)
  into v_rows
  from cma.fleet_areas_of(v_tenant, p_market, p_model) a;
  return jsonb_build_object(
    'set_up', true, 'dummy_preview', true, 'market', p_market, 'model', p_model,
    'today', cma.tenant_today_of(v_tenant), 'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant),
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
                      left join cma.device_model md on md.tenant_id = v_tenant and md.key = f.model),
    'areas', (select coalesce(jsonb_agg(e.v - 'kind' order by e.o) filter (where e.v ->> 'kind' <> 'not_in_field'), '[]'::jsonb)
              from jsonb_array_elements(v_rows) with ordinality e(v, o)),
    'past_due_not_in_field', (select coalesce(sum((e.v ->> 'past_due')::bigint), 0)
                              from jsonb_array_elements(v_rows) e(v) where e.v ->> 'kind' = 'not_in_field'));
end
$$;

-- The list's read (as cma.fleet_areas): set_up false while the setting is off; else the page, its size, the total and
-- the page's rows
create or replace function cma.fleet_rows(p_market text default null, p_model text default null, p_state text default null,
                                          p_area_id uuid default null, p_attention_only boolean default false, p_page integer default 1)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_rows   jsonb;
  v_total  bigint;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_fleet_filters(p_market, p_model, p_state, p_page);
  if not (select s.dummy_preview from cma.fleet_settings_of(v_tenant) s) then
    return jsonb_build_object('set_up', false);
  end if;
  -- the page's rows in the list's order, and the count before the page (a page past the last holds none: its total is
  -- read again from the first)
  select coalesce(jsonb_agg(to_jsonb(r) - 'total_rows' - 'o' order by r.o), '[]'::jsonb), max(r.total_rows)
  into v_rows, v_total
  from (select x.*, row_number() over () as o
        from cma.fleet_rows_of(v_tenant, p_market, p_model, p_state, p_area_id, coalesce(p_attention_only, false), p_page) x) r;
  if v_total is null and p_page > 1 then
    select max(x.total_rows) into v_total
    from cma.fleet_rows_of(v_tenant, p_market, p_model, p_state, p_area_id, coalesce(p_attention_only, false), 1) x;
  end if;
  return jsonb_build_object('set_up', true, 'page', p_page, 'page_size', 50, 'total', coalesce(v_total, 0),
                            'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant),
                            'rows', v_rows);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Grants and settings of the functions
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.fleet_settings_of(uuid)', 'cma.fleet_devices_of(uuid,date)', 'cma.fleet_areas_of(uuid,text,text)',
    'cma.fleet_rows_of(uuid,text,text,text,uuid,boolean,integer)', 'cma.assert_fleet_filters(text,text,text,integer)',
    'cma.fleet_areas(text,text)', 'cma.fleet_rows(text,text,text,uuid,boolean,integer)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- JIT off for the reads, as 0008zn (section 14 of 122): a read of thousands of rows otherwise pays JIT's compilation on a
  -- session's first calls
  foreach f in array array['cma.fleet_areas_of(uuid,text,text)', 'cma.fleet_rows_of(uuid,text,text,text,uuid,boolean,integer)',
                           'cma.fleet_areas(text,text)', 'cma.fleet_rows(text,text,text,uuid,boolean,integer)'] loop
    execute format('alter function %s set jit = off', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009t', 'Assets → Fleet management (brief B37, D1 to D8): cma.postcode_area (geography reference data, not tenant data: country, area code, place name, centre, weight, source; no tenant_id, readable by cma_app, written by migrations only; seeded with the sample areas of GB, NL, DE, FR, AT, SE, IE, BE and areas of DK, NO, FI, ES and IT, only for markets in a tenant''s catalog); the setting fleet_management.dummy_preview (boolean, false); cma.fleet_settings_of; cma.fleet_devices_of (Installed base''s rows by cma.flash_devices_of: In the field, and past due; a dummy area of the device''s market and a dummy monitoring state by hashtextextended); cma.fleet_areas_of (rows area, no_area and not_in_field) and cma.fleet_areas (reports.view or performance.team; set_up false while the setting is off); cma.fleet_rows_of and cma.fleet_rows (50 a page); cma.assert_fleet_filters. Nothing in cma_read')
on conflict (version) do nothing;

commit;
reset role;
